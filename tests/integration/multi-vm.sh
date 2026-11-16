#!/usr/bin/env bash
# The inference engine and two web interfaces on three real VMs, with assertions, see
# tests/integration/README.md and docs/spec-multi-vm.md.
#
#   multi-vm.sh [--keep]
#
# Three VMs of vm.sh on one network (`ecsai-engine`, `ecsai-web` and `ecsai-web2`), created if
# absent: the engine VM holds llmfit, nginx, Ollama and a model, each web VM nginx and LibreChat.
# The scripts are generated from one configuration that names its three VMs and links both web
# VMs to the engine VM, run in the order of the next steps, and each link is made by hand as
# those steps say. Leaves all three machines empty (`uninstall --all --purge`), unless --keep or
# a failure. Exit 0 when every check passes.
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
WEB2_VM="${ECSAI_WEB2_VM:-ecsai-web2}"

# E <vm.sh args>, W <vm.sh args>, W2 <vm.sh args>: vm.sh for the engine VM and for each web VM
E() { ECSAI_VM_NAME="$ENGINE_VM" ECSAI_VM_MEMORY="${ECSAI_ENGINE_MEMORY:-4096}" ECSAI_VM_DISK="${ECSAI_ENGINE_DISK:-20}" "$VM" "$@"; }
W() { ECSAI_VM_NAME="$WEB_VM" ECSAI_VM_MEMORY="${ECSAI_WEB_MEMORY:-3072}" ECSAI_VM_DISK="${ECSAI_WEB_DISK:-24}" "$VM" "$@"; }
W2() { ECSAI_VM_NAME="$WEB2_VM" ECSAI_VM_MEMORY="${ECSAI_WEB2_MEMORY:-3072}" ECSAI_VM_DISK="${ECSAI_WEB2_DISK:-24}" "$VM" "$@"; }

# the two web VMs, and the label each uses in the assertions below
WEB_SIDES=(W W2)
WEB_LABELS=(web web2)

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

# out <E|W|W2> <command run on that VM>: its output. SSH answers 255 when the connection itself
# fails (right after a reboot, for instance), which is retried: the command never ran.
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

# script_out <E|W|W2>: the output of the commands read on stdin, run on that VM. Nothing secret
# goes on a command line this way: the script travels over the SSH connection.
script_out() { "$1" ssh 2>/dev/null; }

healthy() { # <E|W|W2> <number of components>
    out "$1" 'sudo easy-cs-ai --json status' | jq -e --argjson n "$2" 'length == $n and all(.[]; .healthy == true)' >/dev/null
}

login_code() { out "$1" "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3080/api/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"multivm@example.test\",\"password\":\"$PW\"}'"; }
register_code() { out "$1" "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3080/api/auth/register -H 'Content-Type: application/json' -d '{\"name\":\"Multi VM\",\"username\":\"multivm\",\"email\":\"multivm@example.test\",\"password\":\"$PW\",\"confirm_password\":\"$PW\"}'"; }

# endpoints_of_librechat <E|W|W2>: the names of the endpoints LibreChat lists for the test account
endpoints_of_librechat() { out "$1" "TOK=\$(curl -s -X POST http://127.0.0.1:3080/api/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"multivm@example.test\",\"password\":\"$PW\"}' | jq -r .token); curl -s http://127.0.0.1:3080/api/endpoints -H \"Authorization: Bearer \$TOK\" | jq -r 'keys | join(\",\")'"; }

wait_ready() { # <E|W|W2>, LibreChat, up to 5 minutes
    local _
    for _ in $(seq 1 60); do
        [[ "$(out "$1" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/readyz")" == 200 ]] && return 0
        sleep 5
    done
    return 1
}

# shellcheck disable=SC2016 # the command is meant to be expanded on the VM, not here
leftovers() { # <E|W|W2>
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
        W2 ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; rm -f /tmp/engine.key /tmp/engine.crt; true' || true
    fi
}
trap cleanup EXIT

# chat_from_container <E|W|W2> <extra docker exec options>: the call LibreChat makes: the URL of
# the endpoint, the key from its environment, the certificate from the bundle it trusts
# (NODE_EXTRA_CA_CERTS), with Node as it runs in the image.
chat_from_container() {
    script_out "$1" <<EOF
sudo docker exec -i $2 easy-cs-ai-librechat-api-1 node - '$LINK_URL' '$MODEL' <<'JS'
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

# link_one <E|W|W2> <label>: steps 3 and 4 of the next steps for one web VM, reusing the key, the
# URL and the certificate read once from the engine VM (step 2, shared by every link).
link_one() {
    local side="$1" label="$2" secret_env res_without_bundle listed

    step "3. the $label VM reaches the engine VM on its HTTPS port"
    script_out "$side" <<EOF
umask 077
cat > /tmp/engine.key <<'K'
$KEY
K
cat > /tmp/engine.crt <<'C'
$(out E "cat $CERT_E")
C
EOF
    expect "$label: without the key: 401" 401 "$(out "$side" "curl -s --cacert /tmp/engine.crt -o /dev/null -w '%{http_code}' $LINK_URL/models")"
    expect "$label: with the key: 200" 200 "$(out "$side" "curl -s --cacert /tmp/engine.crt -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$(cat /tmp/engine.key)\" $LINK_URL/models")"
    expect "$label: without the certificate the self-signed one is refused (verification is never off)" 60 "$(out "$side" "curl -s -o /dev/null $LINK_URL/models; echo \$?")"

    step "4. link the model on the $label VM"
    "$side" ssh "sudo easy-cs-ai component chat-interface librechat add-endpoint $ENDPOINT '$LINK_URL' --model '$MODEL' --api-key-file /tmp/engine.key --ca-file /tmp/engine.crt >/dev/null 2>&1"
    expect "$label: add-endpoint exits 0" 0 "$?"
    "$side" ssh 'rm -f /tmp/engine.key' >/dev/null 2>&1
    check "$label: LibreChat is ready again" wait_ready "$side"
    case ",$(endpoints_of_librechat "$side")," in *",$ENDPOINT,"*) listed=yes ;; *) listed=no ;; esac
    expect "$label: LibreChat lists the endpoint of the engine VM" yes "$listed"
    secret_env="/etc/easy-cs-ai/secrets/librechat-endpoint-$ENDPOINT.env"
    expect "$label: the key is a secret of its own: mode 600" 600 "$(out "$side" "sudo stat -c %a $secret_env")"
    # shellcheck disable=SC2016 # expanded on the VM
    expect "$label: the key is nowhere else in the configuration or the state" 0 \
        "$(out "$side" 'K=$(sudo cut -d= -f2- '"$secret_env"'); sudo grep -rqF -- "$K" /etc/easy-cs-ai/librechat /var/lib/easy-cs-ai; echo $((1 - $?))')"
    expect "$label: the api container has the key in its environment" 1 "$(out "$side" "sudo docker exec easy-cs-ai-librechat-api-1 printenv EASY_CS_AI_KEY_ENGINE_LLM | grep -c .")"

    step "   a message answered by the engine VM, from the api container of the $label VM"
    expect "$label: the engine answers through HTTPS, the key and the certificate of the bundle" "200 true" "$(chat_from_container "$side" '')"
    res_without_bundle="$(chat_from_container "$side" '-e NODE_EXTRA_CA_CERTS=')"
    check "$label: without the bundle the certificate is refused: the verification is on" test "${res_without_bundle%% *}" = error
}

# --- the VMs and the configuration ----------------------------------------------------------------

step "the three VMs, on one network"
for side in E W W2; do
    if [[ "$("$side" status)" == "no VM"* ]]; then "$side" create; fi
    "$side" start
done

CONFIG="$WORK/multi-vm.json"
cat >"$CONFIG" <<EOF
{
  "schema_version": 2,
  "vms": [
    { "name": "engine", "components": [
        { "component": "provisioning/llmfit" },
        { "component": "proxy/nginx" },
        { "component": "engine/ollama", "name": "ollama", "models": [ { "model": "$MODEL", "name": "$MODEL" } ] } ] },
    { "name": "web", "components": [
        { "component": "proxy/nginx", "options": { "server-name": "localhost" } },
        { "component": "chat-interface/librechat", "name": "librechat" } ] },
    { "name": "web2", "components": [
        { "component": "proxy/nginx", "options": { "server-name": "localhost2" } },
        { "component": "chat-interface/librechat", "name": "librechat" } ] }
  ],
  "links": [
    { "model": { "vm_ref": "engine", "component_ref": "ollama", "model_ref": "$MODEL" },
      "chat_interface": { "vm_ref": "web", "component_ref": "librechat" } }
  ]
}
EOF
# whatever a previous run left: all three machines must start empty
E ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true
W ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true
W2 ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true

step "the configuration is valid, and the validation gives the steps left to do"
validation="$(EASY_CS_AI_HOME="$HERE/../../install_scripts" bash "$HERE/../../package/bin/easy-cs-ai" config validate "$CONFIG" --target fresh --json 2>/dev/null)"
expect "the configuration is valid" true "$(jq -r '.ok' <<<"$validation")"
expect "four steps are given (one engine VM, one link: the second chat VM is linked by hand)" 4 "$(jq '.next_steps | length' <<<"$validation")"
expect "the address of the engine VM is announced as unknown (self-signed, no server name)" '["engine"]' "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm_ref]' <<<"$validation")"

# --- 1. each script on its VM, the engine VM first --------------------------------------------------

step "1. the engine VM, then both web VMs"
E run "$CONFIG" --vm engine
expect "the engine script exits 0" 0 "$?"
W run "$CONFIG" --vm web
expect "the web script exits 0" 0 "$?"
W2 run "$CONFIG" --vm web2
expect "the web2 script exits 0" 0 "$?"
check "the engine VM: llmfit, nginx and Ollama are healthy" healthy E 3
check "the web VM: nginx and LibreChat are healthy" healthy W 2
check "the web2 VM: nginx and LibreChat are healthy" healthy W2 2
expect "the model is on the engine VM" "$MODEL" "$(out E 'sudo easy-cs-ai component engine ollama list-models' | jq -r '.[0].name')"
expect "nothing of a web VM is on the engine VM (no Docker container)" 0 "$(out E 'sudo docker ps -q 2>/dev/null | wc -l')"
expect "each VM has the header of its script" "VM: engine (1 of 3)|VM: web (2 of 3)|VM: web2 (3 of 3)" \
    "$(grep -h '^# VM:' "$WORK/vm-install-engine.sh" "$WORK/vm-install-web.sh" "$WORK/vm-install-web2.sh" | sed 's/^# //' | paste -sd'|')"
for i in 0 1; do
    side="${WEB_SIDES[$i]}" label="${WEB_LABELS[$i]}"
    expect "nothing of the engine VM is on the $label VM (no Ollama)" 0 "$(out "$side" 'command -v ollama | wc -l')"
    expect "three containers run on the $label VM" 3 "$(out "$side" 'sudo docker ps -q | wc -l')"
done

step "   each web VM comes up with no model in its list"
for i in 0 1; do
    side="${WEB_SIDES[$i]}" label="${WEB_LABELS[$i]}"
    expect "registration is open on the $label VM" 200 "$(register_code "$side")"
    expect "the account logs in on the $label VM" 200 "$(login_code "$side")"
    case ",$(endpoints_of_librechat "$side")," in *",$ENDPOINT,"*) listed=yes ;; *) listed=no ;; esac
    expect "LibreChat does not list the model of the engine VM yet on the $label VM" no "$listed"
done

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
# Both web VMs are on the same network, so one lookup (on the web VM) settles it for both.
LINK_URL="$URL"
if [[ "$(out W "getent hosts $HOST | wc -l")" == 0 ]]; then
    ADDR="$(jq -r 'map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") and . != "127.0.0.1"))[0]' <<<"$NAMES")"
    LINK_URL="${URL/\/\/$HOST/\/\/$ADDR}"
    printf '  note  %s is not known to the DNS of the network: the address %s, which the certificate covers, is used instead\n' "$HOST" "$ADDR"
fi

CERT_E=/etc/easy-cs-ai/nginx/server.crt
link_one W web
link_one W2 web2

# --- 5. again -----------------------------------------------------------------------------------------

step "5. the three scripts again change nothing, and both links survive"
before_web="$(out W 'sudo sh -c "cd /etc/easy-cs-ai && sha256sum librechat/* secrets/librechat-endpoint-* | sort"')"
before_web2="$(out W2 'sudo sh -c "cd /etc/easy-cs-ai && sha256sum librechat/* secrets/librechat-endpoint-* | sort"')"
before_engine="$(out E 'sudo sh -c "cd /etc/easy-cs-ai && find . -type f | sort | xargs sha256sum"')"
second_engine="$(E run "$CONFIG" --vm engine)"
expect "the engine script exits 0" 0 "$?"
check "it says the model is already added" grep -q 'already added' <<<"$second_engine"
W run "$CONFIG" --vm web >/dev/null
expect "the web script exits 0" 0 "$?"
W2 run "$CONFIG" --vm web2 >/dev/null
expect "the web2 script exits 0" 0 "$?"
check "the engine VM is still healthy" healthy E 3
expect "the files of the engine VM are the same" "$before_engine" \
    "$(out E 'sudo sh -c "cd /etc/easy-cs-ai && find . -type f | sort | xargs sha256sum"')"
BEFORE_WEB_FILES=("$before_web" "$before_web2")
for i in 0 1; do
    side="${WEB_SIDES[$i]}" label="${WEB_LABELS[$i]}"
    check "the $label VM is still healthy" healthy "$side" 2
    check "LibreChat is ready on the $label VM" wait_ready "$side"
    expect "the files of the $label VM, its key and its certificate included, are the same" "${BEFORE_WEB_FILES[$i]}" \
        "$(out "$side" 'sudo sh -c "cd /etc/easy-cs-ai && sha256sum librechat/* secrets/librechat-endpoint-* | sort"')"
    case ",$(endpoints_of_librechat "$side")," in *",$ENDPOINT,"*) listed=yes ;; *) listed=no ;; esac
    expect "the endpoint is still listed on the $label VM" yes "$listed"
    expect "the engine still answers through the link from the $label VM" "200 true" "$(chat_from_container "$side" '')"
done

# --- 6. everything out --------------------------------------------------------------------------------

step "6. uninstall --all --purge leaves all three machines as found"
W ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1'
expect "the web VM: exit 0" 0 "$?"
W2 ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1'
expect "the web2 VM: exit 0" 0 "$?"
E ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1'
expect "the engine VM: exit 0" 0 "$?"
expect "nothing of the project is left on the web VM" "$EMPTY" "$(leftovers W)"
expect "nothing of the project is left on the web2 VM" "$EMPTY" "$(leftovers W2)"
expect "nothing of the project is left on the engine VM" "$EMPTY" "$(leftovers E)"

# --- summary ------------------------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
    printf '  - %s\n' "${FAILED[@]}"
    KEEP=1 # look at what failed
    exit 1
fi
