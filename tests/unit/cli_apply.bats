#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Fake components shipped: engine eng, eng2; proxy prox; chat-interface chat
# (requires the type proxy); provisioning fit. eng has the options port and
# api-key (secret). Calls are logged in $CALLS, FAKE_FAIL lists failing
# "<name>-<action>" entries (exit 5).

setup() {
    CLI="${BATS_TEST_DIRNAME}/../../package/bin/easy-cs-ai"
    REAL="${BATS_TEST_DIRNAME}/../../install_scripts"
    export EASY_CS_AI_HOME="$BATS_TEST_TMPDIR/home"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    STATE="$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/components"
    unset EASY_CS_AI_LOCK_HELD FAKE_FAIL FAKE_FITS
    mkdir -p "$EASY_CS_AI_HOME"/{engine,proxy,chat-interface,provisioning}
    ln -s "$REAL/lib" "$EASY_CS_AI_HOME/lib"
    printf 'engine eng\nproxy prox\nchat-interface chat\nprovisioning fit\n' >"$EASY_CS_AI_HOME/ranks.conf"
    make_fake engine eng '[]'
    make_fake engine eng2 '[]'
    make_fake proxy prox '[]'
    make_fake chat-interface chat '["proxy"]'
    make_fake provisioning fit '[]'
    : >"$CALLS"
    CFG="$BATS_TEST_TMPDIR/cfg.json"
}

# make_fake <type> <name> <requires-json>
make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
source "\$EASY_CS_AI_LIB/common.sh"
action="\$1"; shift
echo "$2 \$action \$* env=\${EASY_CS_AI_ENG_API_KEY:-}" >>"\$CALLS"
[[ " \${FAKE_FAIL:-} " == *" $2-\$action "* ]] && exit 5
case "\$action" in
describe) jq -n '{name: "$2", type: "$1", requires: $3, options: [
    {name: "port", secret: false}, {name: "api-key", secret: true}]}' ;;
install)
    state_read $2 >/dev/null 2>&1 && m= || m=',"models":[]'
    state_write $2 '{"name":"$2","type":"$1","version":"1","requires":$3,"endpoint":{"url":"http://127.0.0.1:1","openai_base_url":"http://127.0.0.1:1/v1","protected":false}'"\$m"'}' ;;
uninstall) state_remove $2 ;;
check) echo '{"fits": true, "reason": ""}' ;;
add-model)
    state_write $2 "\$(state_read $2 | jq --arg m "\$1" '{name, type, models: ((.models // []) + [{name: \$m, exposed_via: null, linked_to: []}])}')" ;;
remove-model)
    state_write $2 "\$(state_read $2 | jq --arg m "\$1" '{name, type, models: ((.models // []) | map(select(.name != \$m)))}')" ;;
add-upstream) jq -n --arg u "https://host/\$1" '{url: \$u}' ;;
add-endpoint) jq -n --arg u "\$2" '{url: \$u}' ;;
esac
exit 0
FAKE
}

cli() { run --separate-stderr bash "$CLI" "$@"; }
installed() { [ -f "$STATE/$1.json" ]; }

# A file of one named VM: vm_file <components-json> [<links-json>]
vm_file() {
    printf '{"schema_version":2,"vms":[{"name":"vm-1","components":%s}]%s}' "$1" "${2:+,\"links\":$2}" >"$CFG"
}

full_config() {
    cat >"$CFG" <<'JSON'
{
  "schema_version": 2,
  "vms": [ { "name": "vm-1", "components": [
    { "component": "chat-interface/chat", "name": "chat", "default": true },
    { "component": "engine/eng", "name": "eng", "default": true, "options": { "port": 11500 },
      "models": [ { "model": "m1", "name": "m1" } ] },
    { "component": "proxy/prox" },
    { "component": "provisioning/fit" }
  ] } ],
  "links": [ { "model": { "vm_ref": "vm-1", "component_ref": "eng", "model_ref": "m1" },
               "chat_interface": { "vm_ref": "vm-1", "component_ref": "chat" } } ]
}
JSON
}

two_vms() {
    cat >"$CFG" <<'JSON'
{ "schema_version": 2, "vms": [
  { "name": "gpu", "components": [ { "component": "proxy/prox" }, { "component": "provisioning/fit" },
      { "component": "engine/eng", "name": "eng", "models": [ { "model": "m1", "name": "m1" } ] } ] },
  { "name": "web", "components": [ { "component": "proxy/prox" }, { "component": "chat-interface/chat", "name": "chat" } ] } ],
  "links": [ { "model": { "vm_ref": "gpu", "component_ref": "eng", "model_ref": "m1" },
               "chat_interface": { "vm_ref": "web", "component_ref": "chat" } } ] }
JSON
}

# --- validation ---------------------------------------------------------------------------

@test "apply needs a file and rejects unreadable or non-JSON input with exit 2" {
    cli apply
    [ "$status" -eq 2 ]
    cli apply "$BATS_TEST_TMPDIR/missing.json"
    [ "$status" -eq 2 ]
    echo '{nope' >"$CFG"
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"not valid JSON"* ]]
}

validation_error() { # <json> <expected message fragment>
    printf '%s' "$1" >"$CFG"
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"$2"* ]]
    [ ! -s "$CALLS" ] || ! grep -q ' install ' "$CALLS"
}

@test "validation reports each problem with its JSON path, before any side effect" {
    validation_error '{"schema_version":2,"vms":[],"bogus":1}' '$.bogus: unknown key'
    validation_error '{"vms":[]}' '$.schema_version: required'
    validation_error '{"schema_version":3,"vms":[]}' 'newer than the supported version'
    validation_error '{"schema_version":2}' '$.vms: required'
    validation_error '{"schema_version":2,"vms":{}}' '$.vms: an array is expected'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"plugin/x"}]}]}' '$.vms[0].components[0].component'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine"}]}]}' '$.vms[0].components[0].component: <type>/<implementation>'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/nope"}]}]}' '$.vms[0].components[0].component: unknown engine "nope"'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","options":{"colour":"red"}}]}]}' '$.vms[0].components[0].options.colour: unknown option'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","options":{"port":[1]}}]}]}' '$.vms[0].components[0].options.port: a string, number or boolean'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","options":{"api-key":"hunter2"}}]}]}' 'never as a plain value'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","options":{"api-key":{"file":"/x","env":"Y"}}}]}]}' 'exactly one of file, env or generate'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng"},{"component":"engine/eng"}]}]}' 'engine/eng is listed more than once'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","default":true},{"component":"engine/eng2","default":true}]}]}' 'several defaults of type engine'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","models":[{"model":"m"},{"model":"m"}]}]}]}' '$.vms[0].components[0].models[1].model: m is listed more than once'
    validation_error '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox","models":[]}]}]}' 'only an engine component holds models'
}

@test "a flat file of version 1 is refused with the message that the format changed" {
    printf '{"schema_version":1,"components":[{"type":"engine","name":"eng"}]}' >"$CFG"
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"the format changed"* ]]
    [[ "$stderr" == *'$.components: unknown key'* ]]
}

@test "a link that designates nothing is refused with its path" {
    vm_file '[{"component":"engine/eng","name":"eng","models":[{"model":"m","name":"m"}]},{"component":"chat-interface/chat","name":"chat"},{"component":"proxy/prox"},{"component":"provisioning/fit"}]' \
        '[{"model":{"vm_ref":"vm-1","component_ref":"eng","model_ref":"zzz"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}]'
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *'$.links[0].model.model_ref: engine "eng" of VM "vm-1" holds no model instance named "zzz"'* ]]
}

@test "a model with no proxy in its VM is refused by the model step with exit 4" {
    vm_file '[{"component":"engine/eng","models":[{"model":"m","force":true}]}]'
    cli apply "$CFG"
    [ "$status" -ne 0 ]
}

@test "a file with several VMs needs --vm, and applies one slice" {
    two_vms
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"several VMs (gpu, web): select one with --vm"* ]]
    cli apply "$CFG" --vm zzz
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no VM has that name (the file names: gpu, web)"* ]]
    cli apply "$CFG" --vm web
    [ "$status" -eq 0 ]
    installed chat
    ! installed eng
    cli apply "$CFG" --vm gpu
    [ "$status" -eq 0 ]
    installed eng
}

@test "a link to another VM is left out of the slice, so the model has no chat interface there" {
    two_vms
    cli --dry-run apply "$CFG" --vm gpu
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: add m1 to eng (chat interface: null)"* ]]
}

@test "a valid file with no side effect under --dry-run prints the plan" {
    full_config
    cli --dry-run apply "$CFG"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: install engine eng --default --port 11500"* ]]
    [[ "$stderr" == *"plan: add m1 to eng (chat interface: chat)"* ]]
    [ ! -s "$CALLS" ] || ! grep -q ' install ' "$CALLS"
}

# --- apply --------------------------------------------------------------------------------

@test "apply installs in requires order, then adds the models" {
    full_config
    cli apply "$CFG"
    [ "$status" -eq 0 ]
    installed eng
    installed prox
    installed chat
    installed fit
    prox_line="$(grep -n '^prox install' "$CALLS" | cut -d: -f1)"
    chat_line="$(grep -n '^chat install' "$CALLS" | cut -d: -f1)"
    [ "$prox_line" -lt "$chat_line" ]
    grep -q 'eng install --default --port 11500' "$CALLS"
    [ "$(jq -r '.models[0].name' "$STATE/eng.json")" = "m1" ]
    [ "$(jq -r '.models[0].exposed_via' "$STATE/eng.json")" = "prox" ]
}

@test "apply reads the configuration from stdin" {
    full_config
    run --separate-stderr bash "$CLI" apply - <"$CFG"
    [ "$status" -eq 0 ]
    installed chat
}

@test "apply is safe to run again and converges" {
    full_config
    cli apply "$CFG"
    : >"$CALLS"
    cli apply "$CFG"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"already added"* ]]
    ! grep -q 'add-model' "$CALLS"
}

@test "apply with a missing requirement exits 4 with the command to run" {
    vm_file '[{"component":"chat-interface/chat"}]'
    cli apply "$CFG"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"proxy is required by chat"* ]]
    [[ "$stderr" == *"easy-cs-ai install proxy prox"* ]]
    ! installed chat
}

@test "a requirement already installed is enough" {
    cli install proxy prox
    vm_file '[{"component":"chat-interface/chat"}]'
    cli apply "$CFG"
    [ "$status" -eq 0 ]
    installed chat
}

@test "a requirement on another VM does not count" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 2, "vms": [
  { "name": "a", "components": [ { "component": "proxy/prox" } ] },
  { "name": "b", "components": [ { "component": "chat-interface/chat" } ] } ] }
JSON
    cli apply "$CFG" --vm b
    [ "$status" -eq 4 ]
    ! installed chat
}

@test "secrets: a file is passed with --<name>-file, an environment variable through the script's own variable" {
    vm_file '[{"component":"engine/eng","options":{"api-key":{"file":"/etc/key"}}}]'
    cli apply "$CFG"
    grep -q 'eng install --api-key-file /etc/key' "$CALLS"
    cli uninstall engine eng
    : >"$CALLS"
    vm_file '[{"component":"engine/eng","options":{"api-key":{"env":"MY_KEY"}}}]'
    MY_KEY=s3cret cli apply "$CFG"
    [ "$status" -eq 0 ]
    grep -q 'env=s3cret' "$CALLS"
    ! grep -q 'install .*s3cret' "$CALLS"
    cli uninstall engine eng
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"MY_KEY"*"not set"* ]]
}

@test "a generated secret passes nothing" {
    vm_file '[{"component":"engine/eng","options":{"api-key":{"generate":true}}}]'
    cli apply "$CFG"
    [ "$status" -eq 0 ]
    grep -q '^eng install  *env=$' "$CALLS" || grep -q '^eng install env=$' "$CALLS"
}

@test "changed options are forwarded again on a re-run" {
    vm_file '[{"component":"engine/eng","options":{"port":1}}]'
    cli apply "$CFG"
    vm_file '[{"component":"engine/eng","options":{"port":2}}]'
    cli apply "$CFG"
    grep -q 'eng install --port 2' "$CALLS"
}

@test "models: each one goes to the engine that holds it, force skips the fit check, no link means no chat interface" {
    vm_file '[{"component":"engine/eng","models":[{"model":"b","force":true}]},{"component":"engine/eng2","default":true,"models":[{"model":"a"}]},{"component":"proxy/prox"},{"component":"provisioning/fit"}]'
    cli apply "$CFG"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.models[0].name' "$STATE/eng2.json")" = "a" ]
    [ "$(jq -r '.models[0].name' "$STATE/eng.json")" = "b" ]
    [[ "$stderr" == *"fit check skipped"* ]]
}

@test "apply stops at the first failing step and a second run resumes" {
    full_config
    FAKE_FAIL=chat-install cli apply "$CFG"
    [ "$status" -eq 5 ]
    [[ "$stderr" == *"apply: install chat-interface chat failed (exit 5)"* ]]
    installed prox
    ! installed chat
    ! grep -q 'add-model' "$CALLS"
    cli apply "$CFG"
    [ "$status" -eq 0 ]
    installed chat
}

@test "a failing add is rolled back and the components stay" {
    full_config
    FAKE_FAIL=chat-add-endpoint cli apply "$CFG"
    [ "$status" -eq 5 ]
    [[ "$stderr" == *"apply: add m1 failed"* ]]
    installed eng
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 0 ]
}

@test "apply journals start and end with counts only" {
    full_config
    cli apply "$CFG"
    [[ "$stderr" == *"apply start components=4 models=1 prune=false"* ]]
    [[ "$stderr" == *"apply end exit=0"* ]]
}

# --- prune --------------------------------------------------------------------------------

@test "nothing is removed without --prune" {
    full_config
    cli apply "$CFG"
    vm_file '[{"component":"engine/eng"},{"component":"proxy/prox"},{"component":"provisioning/fit"}]'
    cli apply "$CFG"
    [ "$status" -eq 0 ]
    installed chat
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 1 ]
}

@test "--prune removes models and components the file does not name" {
    full_config
    cli apply "$CFG"
    vm_file '[{"component":"engine/eng","models":[{"model":"keep"}]},{"component":"proxy/prox"},{"component":"provisioning/fit"}]'
    cli apply "$CFG" --prune
    [ "$status" -eq 0 ]
    ! installed chat
    installed prox
    run jq -r '[.models[].name] | join(",")' "$STATE/eng.json"
    [ "$output" = "keep" ]
}

@test "--prune does nothing when a step failed" {
    full_config
    cli apply "$CFG"
    vm_file '[{"component":"engine/eng","options":{"port":1}}]'
    FAKE_FAIL=eng-install cli apply "$CFG" --prune
    [ "$status" -eq 5 ]
    installed chat
}
