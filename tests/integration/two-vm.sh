#!/usr/bin/env bash
# The inference engine and the web interface on two real VMs, with assertions, see
# tests/integration/README.md and docs/spec-two-vm.md.
#
#   two-vm.sh [--keep]
#
# Two VMs of vm.sh on one network (`ecsai-engine` and `ecsai-web`), created if absent: the engine VM holds
# llmfit, nginx, Ollama and a model, the web VM nginx and LibreChat. The scripts are generated from one
# configuration that names its two VMs, run in the order of the next steps, and the link is made by hand
# as those steps say. Leaves both machines empty (`uninstall --all --purge`), unless --keep or a failure.
# Exit 0 when every check passes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
WORK="${ECSAI_VM_DIR:-$HOME/.cache/easy-cs-ai-vm}"
MODEL="${ECSAI_TEST_MODEL:-llama3.2:1b}"
ENDPOINT=engine-llm
KEEP=0
[[ "${1:-}" != --keep ]] || KEEP=1

export ECSAI_VM_NETWORK="${ECSAI_VM_NETWORK:-ecsai-net}"
ENGINE_VM="${ECSAI_ENGINE_VM:-ecsai-engine}"
WEB_VM="${ECSAI_WEB_VM:-ecsai-web}"

# E <vm.sh args>, W <vm.sh args>: vm.sh for the engine VM and for the web VM
E() { ECSAI_VM_NAME="$ENGINE_VM" ECSAI_VM_MEMORY="${ECSAI_ENGINE_MEMORY:-4096}" ECSAI_VM_DISK="${ECSAI_ENGINE_DISK:-20}" "$VM" "$@"; }
W() { ECSAI_VM_NAME="$WEB_VM" ECSAI_VM_MEMORY="${ECSAI_WEB_MEMORY:-3072}" ECSAI_VM_DISK="${ECSAI_WEB_DISK:-24}" "$VM" "$@"; }

PASS=0 FAIL=0 FAILED=()
# a password for the test account of this run, never reused, never written anywhere
PW="Ft-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

step() { printf '\n== %s ==\n' "$*"; }

# check <description> <command…>: the command succeeds
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$desc")
        printf '  FAIL  %s\n' "$desc"
    fi
}

expect() { # <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$1 (expected '$2', got '$3')")
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
    fi
}

# out <E|W> <command run on that VM>: its output. SSH answers 255 when the connection itself fails
# (right after a reboot, for instance), which is retried: the command never ran.
out() {
    local side="$1" res rc _
    for _ in 1 2 3 4; do
        res="$("$side" ssh "$2" 2>/dev/null)"
        rc=$?
        [[ $rc -ne 255 ]] && break
        sleep 5
    done
    printf '%s\n' "$res"
}

# script_out <E|W>: the output of the commands read on stdin, run on that VM. Nothing secret goes on a
# command line this way: the script travels over the SSH connection.
script_out() { "$1" ssh 2>/dev/null; }

healthy() { # <E|W> <number of components>
    out "$1" 'sudo easy-cs-ai --json status' | jq -e --argjson n "$2" 'length == $n and all(.[]; .healthy == true)' >/dev/null
}

login_code() { out W "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3080/api/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"twovm@example.test\",\"password\":\"$PW\"}'"; }
register_code() { out W "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3080/api/auth/register -H 'Content-Type: application/json' -d '{\"name\":\"Two VM\",\"username\":\"twovm\",\"email\":\"twovm@example.test\",\"password\":\"$PW\",\"confirm_password\":\"$PW\"}'"; }

# endpoints_of_librechat: the names of the endpoints LibreChat lists for the test account
endpoints_of_librechat() {
    out W "TOK=\$(curl -s -X POST http://127.0.0.1:3080/api/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"twovm@example.test\",\"password\":\"$PW\"}' | jq -r .token); curl -s http://127.0.0.1:3080/api/endpoints -H \"Authorization: Bearer \$TOK\" | jq -r 'keys | join(\",\")'"
}

wait_ready() { # LibreChat, up to 5 minutes
    local _
    for _ in $(seq 1 60); do
        [[ "$(out W "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/readyz")" == 200 ]] && return 0
        sleep 5
    done
    return 1
}

# shellcheck disable=SC2016 # the command is meant to be expanded on the VM, not here
leftovers() { # <E|W>
    out "$1" 'echo "state $(ls /var/lib/easy-cs-ai/components 2>/dev/null | wc -l) $(ls /var/lib/easy-cs-ai/pending 2>/dev/null | wc -l)
files $(sudo find /etc/easy-cs-ai -type f 2>/dev/null | wc -l)
units $(ls /etc/systemd/system | grep -cE "ollama|librechat")
nginx $(ls /etc/nginx/conf.d | wc -l) $(ls -d /etc/nginx/easy-cs-ai 2>/dev/null | wc -l)
docker $(sudo docker ps -a -q 2>/dev/null | wc -l) $(sudo docker volume ls -q 2>/dev/null | wc -l) $(sudo docker images -q 2>/dev/null | wc -l)
ollama $(ls /usr/local/bin/ollama /usr/local/lib/ollama 2>/dev/null | wc -l) $(id ollama >/dev/null 2>&1 && echo user || echo none)
llmfit $(command -v llmfit | wc -l)
ports $(ss -ltn | awk "NR>1 {print \$4}" | grep -cE ":(443|8443|3080|27017|11434)$")"' | tr '\n' ';'
}

EMPTY="state 0 0;files 0;units 0;nginx 0 0;docker 0 0 0;ollama 0 none;llmfit 0;ports 0;"

cleanup() {
    if ((!KEEP)); then
        printf '\n== clean-up ==\n'
        E ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true
        W ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; rm -f /tmp/engine.key /tmp/engine.crt; true' || true
    fi
}
trap cleanup EXIT

# --- the VMs and the configuration ----------------------------------------------------------------

step "the two VMs, on one network"
for side in E W; do
    if [[ "$("$side" status)" == "no VM"* ]]; then "$side" create; fi
    "$side" start
done

CONFIG="$WORK/two-vm.json"
cat >"$CONFIG" <<EOF
{
  "schema_version": 1,
  "components": [
    { "type": "provisioning", "name": "llmfit", "vm": "engine" },
    { "type": "proxy", "name": "nginx", "vm": "engine" },
    { "type": "engine", "name": "ollama", "vm": "engine" },
    { "type": "proxy", "name": "nginx", "vm": "web", "options": { "server-name": "localhost" } },
    { "type": "chat-interface", "name": "librechat", "vm": "web" }
  ],
  "models": [ { "name": "$MODEL", "vm": "engine", "engine": "ollama" } ]
}
EOF
# whatever a previous run left: both machines must start empty
E ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true
W ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true

step "the configuration is valid, and the validation gives the steps left to do"
validation="$(EASY_CS_AI_HOME="$HERE/../../install_scripts" bash "$HERE/../../package/bin/easy-cs-ai" config validate "$CONFIG" --target fresh --json 2>/dev/null)"
expect "the configuration is valid" true "$(jq -r '.ok' <<<"$validation")"
expect "the four steps of the administrator are given" 4 "$(jq '.next_steps | length' <<<"$validation")"
expect "the address of the engine VM is announced as unknown (self-signed, no server name)" '["engine"]' "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm]' <<<"$validation")"

# --- 1. each script on its VM, the engine VM first --------------------------------------------------

step "1. the engine VM, then the web VM"
E run "$CONFIG" --vm engine
expect "the engine script exits 0" 0 "$?"
W run "$CONFIG" --vm web
expect "the web script exits 0" 0 "$?"
check "the engine VM: llmfit, nginx and Ollama are healthy" healthy E 3
check "the web VM: nginx and LibreChat are healthy" healthy W 2
expect "the model is on the engine VM" "$MODEL" "$(out E 'sudo easy-cs-ai component engine ollama list-models' | jq -r '.[0].name')"
expect "nothing of the web VM is on the engine VM (no Docker container)" 0 "$(out E 'sudo docker ps -q 2>/dev/null | wc -l')"
expect "nothing of the engine VM is on the web VM (no Ollama)" 0 "$(out W 'command -v ollama | wc -l')"
expect "three containers run on the web VM" 3 "$(out W 'sudo docker ps -q | wc -l')"
expect "each VM has the header of its script" "VM: engine (1 of 2)|VM: web (2 of 2)" \
    "$(grep -h '^# VM:' "$WORK/vm-install-engine.sh" "$WORK/vm-install-web.sh" | sed 's/^# //' | paste -sd'|')"

step "   the web VM comes up with no model in its list"
expect "registration is open on the web VM" 200 "$(register_code)"
expect "the account logs in" 200 "$(login_code)"
case ",$(endpoints_of_librechat)," in *",$ENDPOINT,"*) listed=yes ;; *) listed=no ;; esac
expect "LibreChat does not list the model of the engine VM yet" no "$listed"

# --- 2. the link, as the next steps say -------------------------------------------------------------

step "2. read the key, the URL and the names the certificate covers, on the engine VM"
KEY="$(out E 'sudo easy-cs-ai component proxy nginx show-key')"
UPSTREAMS="$(out E 'easy-cs-ai component proxy nginx list-upstreams')"
NAMES="$(out E 'sudo easy-cs-ai component proxy nginx status | jq -c .certificate_names')"
URL="$(jq -r '.[0].url' <<<"$UPSTREAMS")"
HOST="$(sed -E 's#^https://([^/:]+).*#\1#' <<<"$URL")"
expect "list-upstreams gives one model, with the URL a client of another machine uses" 1 "$(jq 'length' <<<"$UPSTREAMS")"
check "the URL is a public one, not the loopback of the engine" test "$HOST" != 127.0.0.1 -a "$HOST" != localhost
# shellcheck disable=SC2016 # a jq program
check "the host of the URL is one of the names the certificate covers" jq -e --arg h "$HOST" 'index($h) != null' <<<"$NAMES"
check "the certificate covers an address of the engine VM too" jq -e 'any(.[]; test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") and . != "127.0.0.1")' <<<"$NAMES"
# The name of the engine VM may be unknown to the DNS of the network (it is on this one): the next steps
# say what to do, an address of the engine VM that the certificate covers goes in place of the host.
LINK_URL="$URL"
if [[ "$(out W "getent hosts $HOST | wc -l")" == 0 ]]; then
    ADDR="$(jq -r 'map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") and . != "127.0.0.1"))[0]' <<<"$NAMES")"
    LINK_URL="${URL/\/\/$HOST/\/\/$ADDR}"
    printf '  note  %s is not known to the DNS of the network: the address %s, which the certificate covers, is used instead\n' "$HOST" "$ADDR"
fi

step "3. the web VM reaches the engine VM on its HTTPS port"
CERT_E=/etc/easy-cs-ai/nginx/server.crt
script_out W <<EOF
umask 077
cat > /tmp/engine.key <<'K'
$KEY
K
cat > /tmp/engine.crt <<'C'
$(out E "cat $CERT_E")
C
EOF
expect "without the key: 401" 401 "$(out W "curl -s --cacert /tmp/engine.crt -o /dev/null -w '%{http_code}' $LINK_URL/models")"
expect "with the key: 200" 200 "$(out W "curl -s --cacert /tmp/engine.crt -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$(cat /tmp/engine.key)\" $LINK_URL/models")"
expect "without the certificate the self-signed one is refused (verification is never off)" 60 "$(out W "curl -s -o /dev/null $LINK_URL/models; echo \$?")"

step "4. link the model on the web VM"
W ssh "sudo easy-cs-ai component chat-interface librechat add-endpoint $ENDPOINT '$LINK_URL' --model '$MODEL' --api-key-file /tmp/engine.key --ca-file /tmp/engine.crt >/dev/null 2>&1"
expect "add-endpoint exits 0" 0 "$?"
W ssh 'rm -f /tmp/engine.key' >/dev/null 2>&1
check "LibreChat is ready again" wait_ready
case ",$(endpoints_of_librechat)," in *",$ENDPOINT,"*) listed=yes ;; *) listed=no ;; esac
expect "LibreChat lists the endpoint of the engine VM" yes "$listed"
SECRET_ENV="/etc/easy-cs-ai/secrets/librechat-endpoint-$ENDPOINT.env"
expect "the key is a secret of its own: mode 600" 600 "$(out W "sudo stat -c %a $SECRET_ENV")"
# shellcheck disable=SC2016 # expanded on the VM
expect "the key is nowhere else in the configuration or the state" 0 \
    "$(out W 'K=$(sudo cut -d= -f2- '"$SECRET_ENV"'); sudo grep -rqF -- "$K" /etc/easy-cs-ai/librechat /var/lib/easy-cs-ai; echo $((1 - $?))')"
expect "the api container has the key in its environment" 1 "$(out W "sudo docker exec easy-cs-ai-librechat-api-1 printenv EASY_CS_AI_KEY_ENGINE_LLM | grep -c .")"

step "   a message answered by the engine VM, from the api container of the web VM"
# the call LibreChat makes: the URL of the endpoint, the key from its environment, the certificate from
# the bundle it trusts (NODE_EXTRA_CA_CERTS), with Node as it runs in the image
chat_from_container() { # <extra docker exec options>
    script_out W <<EOF
sudo docker exec -i $1 easy-cs-ai-librechat-api-1 node - '$LINK_URL' '$MODEL' <<'JS'
const [url, model] = process.argv.slice(2);
fetch(url + '/chat/completions', {
  method: 'POST',
  headers: { 'content-type': 'application/json', authorization: 'Bearer ' + process.env.EASY_CS_AI_KEY_ENGINE_LLM },
  body: JSON.stringify({ model, messages: [{ role: 'user', content: 'Say hello.' }], max_tokens: 16, stream: false }),
}).then(async (r) => {
  const j = await r.json();
  console.log(r.status, ((j.choices || [{ message: { content: '' } }])[0].message.content || '').length > 0);
}).catch((e) => console.log('error', (e.cause && e.cause.code) || e.message));
JS
EOF
}
expect "the engine answers through HTTPS, the key and the certificate of the bundle" "200 true" "$(chat_from_container '')"
res_without_bundle="$(chat_from_container '-e NODE_EXTRA_CA_CERTS=')"
check "without the bundle the certificate is refused: the verification is on" test "${res_without_bundle%% *}" = error

# --- 5. again -----------------------------------------------------------------------------------------

step "5. the two scripts again change nothing, and the link survives"
before_web="$(out W 'sudo sh -c "cd /etc/easy-cs-ai && sha256sum librechat/* secrets/librechat-endpoint-* | sort"')"
before_engine="$(out E 'sudo sh -c "cd /etc/easy-cs-ai && find . -type f | sort | xargs sha256sum"')"
second_engine="$(E run "$CONFIG" --vm engine)"
expect "the engine script exits 0" 0 "$?"
check "it says the model is already added" grep -q 'already added' <<<"$second_engine"
W run "$CONFIG" --vm web >/dev/null
expect "the web script exits 0" 0 "$?"
check "the engine VM is still healthy" healthy E 3
check "the web VM is still healthy" healthy W 2
check "LibreChat is ready" wait_ready
expect "the files of the web VM, its key and its certificate included, are the same" "$before_web" \
    "$(out W 'sudo sh -c "cd /etc/easy-cs-ai && sha256sum librechat/* secrets/librechat-endpoint-* | sort"')"
expect "the files of the engine VM are the same" "$before_engine" \
    "$(out E 'sudo sh -c "cd /etc/easy-cs-ai && find . -type f | sort | xargs sha256sum"')"
case ",$(endpoints_of_librechat)," in *",$ENDPOINT,"*) listed=yes ;; *) listed=no ;; esac
expect "the endpoint is still listed" yes "$listed"
expect "the engine still answers through the link" "200 true" "$(chat_from_container '')"

# --- 6. everything out --------------------------------------------------------------------------------

step "6. uninstall --all --purge leaves both machines as found"
W ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1'
expect "the web VM: exit 0" 0 "$?"
E ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1'
expect "the engine VM: exit 0" 0 "$?"
expect "nothing of the project is left on the web VM" "$EMPTY" "$(leftovers W)"
expect "nothing of the project is left on the engine VM" "$EMPTY" "$(leftovers E)"

# --- summary ------------------------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
    printf '  - %s\n' "${FAILED[@]}"
    KEEP=1 # look at what failed
    exit 1
fi
