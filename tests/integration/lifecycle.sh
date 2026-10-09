#!/usr/bin/env bash
# The life of the default stack on a real VM, with assertions, see tests/integration/README.md.
#
#   lifecycle.sh [--keep]
#
# Needs the VM of vm.sh (created if absent). Leaves the machine as found, whatever the outcome,
# unless --keep (the stack then stays installed, to look at it). Exit 0 when every check passes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM="$HERE/vm.sh"
WORK="${ECSAI_VM_DIR:-$HOME/.cache/easy-cs-ai-vm}"
MODEL="${ECSAI_TEST_MODEL:-llama3.2:1b}"
KEEP=0
[[ "${1:-}" != --keep ]] || KEEP=1

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

vm() { "$VM" ssh "$@"; }

# on_vm <description> <command run on the VM>: the command succeeds there
on_vm() {
    local desc="$1" cmd="$2"
    check "$desc" "$VM" ssh "$cmd"
}

# out <command run on the VM>: its output. SSH answers 255 when the connection itself fails (right
# after a reboot, for instance), which is retried: the command never ran.
out() {
    local res rc _
    for _ in 1 2 3 4; do
        res="$("$VM" ssh "$1" 2>/dev/null)"
        rc=$?
        [[ $rc -ne 255 ]] && break
        sleep 5
    done
    printf '%s
' "$res"
}

login_code() { out "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3080/api/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"lifecycle@example.test\",\"password\":\"$PW\"}'"; }
register_code() { out "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3080/api/auth/register -H 'Content-Type: application/json' -d '{\"name\":\"$1\",\"username\":\"$2\",\"email\":\"$2@example.test\",\"password\":\"$PW\",\"confirm_password\":\"$PW\"}'"; }

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

all_healthy() { out 'sudo easy-cs-ai --json status' | jq -e 'length == 4 and all(.[]; .healthy == true)' >/dev/null; }

wait_ready() { # up to 5 minutes
    local _
    for _ in $(seq 1 60); do
        [[ "$(out "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/readyz")" == 200 ]] && return 0
        sleep 5
    done
    return 1
}

# shellcheck disable=SC2016 # the command is meant to be expanded on the VM, not here
leftovers() {
    out 'echo "state $(ls /var/lib/easy-cs-ai/components 2>/dev/null | wc -l) $(ls /var/lib/easy-cs-ai/pending 2>/dev/null | wc -l)
files $(sudo find /etc/easy-cs-ai -type f 2>/dev/null | wc -l)
units $(ls /etc/systemd/system | grep -cE "ollama|librechat")
nginx $(ls /etc/nginx/conf.d | wc -l) $(ls -d /etc/nginx/easy-cs-ai 2>/dev/null | wc -l)
docker $(sudo docker ps -a -q | wc -l) $(sudo docker volume ls -q | wc -l) $(sudo docker images -q | wc -l)
ollama $(ls /usr/local/bin/ollama /usr/local/lib/ollama 2>/dev/null | wc -l) $(id ollama >/dev/null 2>&1 && echo user || echo none)
llmfit $(command -v llmfit | wc -l)
ports $(ss -ltn | awk "NR>1 {print \$4}" | grep -cE ":(443|8443|3080|27017|11434)$")"' | tr '\n' ';'
}

cleanup() {
    if ((!KEEP)); then
        printf '\n== clean-up ==\n'
        "$VM" ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true
    fi
}
trap cleanup EXIT

# --- the VM and the configuration -----------------------------------------------------------------

step "the VM"
if [[ "$("$VM" status)" == "no VM"* ]]; then "$VM" create; fi
"$VM" start

CONFIG="$WORK/lifecycle.json"
cat >"$CONFIG" <<EOF
{
  "schema_version": 1,
  "components": [
    { "type": "provisioning", "name": "llmfit" },
    { "type": "proxy", "name": "nginx", "options": { "server-name": "localhost" } },
    { "type": "engine", "name": "ollama" },
    { "type": "chat-interface", "name": "librechat" }
  ],
  "models": [ { "name": "$MODEL" } ]
}
EOF
# whatever a previous run left: the machine must start empty
"$VM" ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1; true' || true

# --- 1. install ---------------------------------------------------------------------------------

step "1. the generated script installs the stack on an empty machine"
"$VM" run "$CONFIG"
expect "the script exits 0" 0 "$?"
check "the four components are healthy" all_healthy
expect "the model is listed" "$MODEL" "$(out 'sudo easy-cs-ai engine ollama list-models' | jq -r '.[0].name')"
expect "three containers run" 3 "$(out 'sudo docker ps -q | wc -l')"

step "   the API is protected, the site is not"
CERT=/etc/easy-cs-ai/nginx/server.crt
UP="ollama-$(printf '%s' "$MODEL" | tr -c 'a-z0-9.\n' '-')"
expect "API without the key" 401 "$(out "curl -s --cacert $CERT -o /dev/null -w '%{http_code}' https://localhost/$UP/v1/models")"
expect "API with the key" 200 "$(out "curl -s --cacert $CERT -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$(sudo easy-cs-ai proxy nginx show-key)\" https://localhost/$UP/v1/models")"
expect "site without a key" 200 "$(out "curl -s --cacert $CERT -o /dev/null -w '%{http_code}' https://localhost:8443/health")"
expect "registration is open (the default)" 200 "$(register_code Lifecycle lifecycle)"
expect "the new account logs in" 200 "$(login_code)"
expect "LibreChat lists the endpoint" true "$(out "TOK=\$(curl -s -X POST http://127.0.0.1:3080/api/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"lifecycle@example.test\",\"password\":\"$PW\"}' | jq -r .token); curl -s http://127.0.0.1:3080/api/endpoints -H \"Authorization: Bearer \$TOK\" | jq 'has(\"$UP\")'")"
expect "a chat reaches the model through the API" true "$(out "curl -s --cacert $CERT -H \"Authorization: Bearer \$(sudo easy-cs-ai proxy nginx show-key)\" -H 'Content-Type: application/json' https://localhost/$UP/v1/chat/completions -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello.\"}],\"max_tokens\":16,\"stream\":false}' | jq '(.choices[0].message.content | length) > 0'")"

# --- 2. again -----------------------------------------------------------------------------------

step "2. the same script again changes nothing"
t0=$SECONDS
second="$("$VM" run "$CONFIG")"
expect "the script exits 0" 0 "$?"
check "it says the model is already added" grep -q 'already added' <<<"$second"
check "still healthy" all_healthy
printf '        (%ss)\n' "$((SECONDS - t0))"

# --- 3. reboot ----------------------------------------------------------------------------------

step "3. a reboot brings the stack back by itself"
"$VM" ssh 'sudo systemctl reboot' >/dev/null 2>&1 || true
sleep 20
for _ in $(seq 1 60); do "$VM" ssh true >/dev/null 2>&1 && break; sleep 5; done
check "LibreChat answers within 5 minutes" wait_ready
check "the four components are healthy" all_healthy
expect "the account is still there" 200 "$(login_code)"

# --- 4. registration ----------------------------------------------------------------------------

step "4. closing the registration recreates only the api"
before="$(out "sudo docker inspect -f '{{.Id}}' easy-cs-ai-librechat-postgres-1")"
"$VM" ssh 'sudo easy-cs-ai install chat-interface librechat --allow-registration false >/dev/null 2>&1'
expect "exit 0" 0 "$?"
expect "the database container is the same" "$before" "$(out "sudo docker inspect -f '{{.Id}}' easy-cs-ai-librechat-postgres-1")"
expect "a new account is refused" 403 "$(register_code Late late)"
expect "the existing account still logs in" 200 "$(login_code)"

# --- 5. uninstall and install again -------------------------------------------------------------

step "5. LibreChat uninstalled keeps its data, and finds it again"
out 'sudo cp /etc/easy-cs-ai/secrets/librechat-db.env /tmp/db.env.before' >/dev/null
"$VM" ssh 'sudo easy-cs-ai uninstall chat-interface librechat >/dev/null 2>&1'
expect "uninstall exits 0" 0 "$?"
expect "no container left" 0 "$(out 'sudo docker ps -a --format "{{.Names}}" | grep -c librechat')"
expect "the site is gone" 0 "$(out "ss -ltn | grep -c ':8443 '")"
expect "the database volume is kept" 1 "$(out 'sudo docker volume ls -q | grep -c pgdata')"
"$VM" ssh 'sudo easy-cs-ai install chat-interface librechat --allow-registration false >/dev/null 2>&1'
expect "install exits 0" 0 "$?"
expect "same database password" 0 "$(out 'sudo diff -q /tmp/db.env.before /etc/easy-cs-ai/secrets/librechat-db.env >/dev/null; echo $?')"
expect "the account survived" 200 "$(login_code)"
"$VM" ssh "sudo easy-cs-ai add '$MODEL' >/dev/null 2>&1"
expect "add links the model again" '["librechat"]' "$(out "sudo jq -c '.models[0].linked_to' /var/lib/easy-cs-ai/components/ollama.json")"

# --- 6. a failed install ------------------------------------------------------------------------

step "6. an install that fails is reported and cleaned"
"$VM" ssh 'sudo easy-cs-ai uninstall chat-interface librechat >/dev/null 2>&1'
"$VM" ssh 'sudo easy-cs-ai install chat-interface librechat --allow-registration false --health-timeout 1 >/dev/null 2>&1'
expect "the health check fails with exit 6" 6 "$?"
expect "no state is recorded" 0 "$(out 'ls /var/lib/easy-cs-ai/components | grep -c librechat')"
expect "a pending manifest is left" 1 "$(out 'ls /var/lib/easy-cs-ai/pending | grep -c librechat')"
expect "status reports it" 1 "$(out 'sudo easy-cs-ai status 2>&1 | grep -c "failed install pending"')"
"$VM" ssh 'sudo easy-cs-ai uninstall chat-interface librechat >/dev/null 2>&1'
expect "uninstall cleans it" 0 "$(out 'ls /var/lib/easy-cs-ai/pending | wc -l')"
"$VM" ssh 'sudo easy-cs-ai install chat-interface librechat --allow-registration false >/dev/null 2>&1'
expect "a normal install then resumes" 0 "$?"
check "healthy again" all_healthy

# --- 7. everything out --------------------------------------------------------------------------

step "7. uninstall --all --purge leaves the machine as found"
"$VM" ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1'
expect "exit 0" 0 "$?"
expect "nothing of the project is left (state, files, units, nginx, docker, ollama, llmfit, ports)" \
    "state 0 0;files 0;units 0;nginx 0 0;docker 0 0 0;ollama 0 none;llmfit 0;ports 0;" "$(leftovers)"


# --- 8. the default stack -----------------------------------------------------------------------

step "8. install --defaults installs the default stack and its default model"
DEFAULT_MODEL="$(awk '$1 == "ollama" {print $2}' "$HERE/../../install_scripts/default-models.conf")"
UPD="ollama-$(printf '%s' "$DEFAULT_MODEL" | tr -c 'a-z0-9.\n' '-')"
"$VM" ssh 'sudo easy-cs-ai install --defaults 2>&1' >"$WORK/defaults.log"
expect "install --defaults exits 0" 0 "$?"
check "the four components are healthy" all_healthy
check "the engines and chat interfaces without a script are skipped with a warning, not an error" grep -q 'WARN' "$WORK/defaults.log"
expect "the default model is the only model" "$DEFAULT_MODEL" "$(out 'sudo easy-cs-ai engine ollama list-models' | jq -r '[.[].name] | join(",")')"
expect "it is linked to LibreChat" '["librechat"]' "$(out "sudo jq -c '.models[0].linked_to' /var/lib/easy-cs-ai/components/ollama.json")"
expect "API without the key" 401 "$(out "curl -sk -o /dev/null -w '%{http_code}' https://\$(hostname)/$UPD/v1/models")"
expect "API with the key" 200 "$(out "curl -sk -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$(sudo easy-cs-ai proxy nginx show-key)\" https://\$(hostname)/$UPD/v1/models")"
"$VM" ssh 'sudo easy-cs-ai install --defaults >/dev/null 2>&1'
expect "the same command again exits 0" 0 "$?"
expect "and adds no model" 1 "$(out 'sudo easy-cs-ai engine ollama list-models' | jq 'length')"
check "still healthy" all_healthy
"$VM" ssh 'sudo easy-cs-ai uninstall --all --purge >/dev/null 2>&1'
expect "uninstall --all --purge exits 0" 0 "$?"
expect "nothing of the project is left" \
    "state 0 0;files 0;units 0;nginx 0 0;docker 0 0 0;ollama 0 none;llmfit 0;ports 0;" "$(leftovers)"

# --- summary ------------------------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
    printf '  - %s\n' "${FAILED[@]}"
    KEEP=1 # look at what failed
    exit 1
fi
