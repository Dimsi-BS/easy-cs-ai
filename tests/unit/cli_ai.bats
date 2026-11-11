#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The machine interface of the CLI, see docs/spec-capabilities.md: catalog, host,
# config schema / validate, guide, the result documents of the changing commands.
#
# Fake components shipped: provisioning fit; proxy prox; engine eng (ranked second)
# and eng2 (ranked first); chat-interface chat (requires the type proxy, option
# open with a warning when true). ranks.conf also ranks "ghost", which has no script.

setup() {
    CLI="${BATS_TEST_DIRNAME}/../../package/bin/easy-cs-ai"
    REAL="${BATS_TEST_DIRNAME}/../../install_scripts"
    export EASY_CS_AI_HOME="$BATS_TEST_TMPDIR/home"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    STATE="$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/components"
    unset EASY_CS_AI_LOCK_HELD EASY_CS_AI_HOST_IDS FAKE_FAIL
    mkdir -p "$EASY_CS_AI_HOME"/{engine,proxy,chat-interface,provisioning}
    ln -s "$REAL/lib" "$EASY_CS_AI_HOME/lib"
    ln -s "$REAL/guide.txt" "$EASY_CS_AI_HOME/guide.txt"
    printf '# comment\nengine eng2\nengine ghost\nengine eng\nproxy prox\nchat-interface chat\nprovisioning fit\n' >"$EASY_CS_AI_HOME/ranks.conf"
    printf 'eng2 small-model\n' >"$EASY_CS_AI_HOME/default-models.conf"
    make_fake engine eng '[]'
    make_fake engine eng2 '[]'
    make_fake proxy prox '[]'
    make_fake chat-interface chat '["proxy"]'
    make_fake provisioning fit '[]'
    : >"$CALLS"
    CFG="$BATS_TEST_TMPDIR/cfg.json"
}

# make_fake <type> <name> <requires-json>: describe with typed options, a secret and a warning.
make_fake() {
    local extra="${4:-}"
    [[ -n "$extra" ]] || extra='{}'
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
source "\$EASY_CS_AI_LIB/common.sh"
action="\$1"; shift
echo "$2 \$action \$*" >>"\$CALLS"
[[ " \${FAKE_FAIL:-} " == *" $2-\$action "* ]] && { echo "[ERROR] $2 \$action broke" >&2; exit 5; }
echo "[INFO] $2 \$action runs" >&2
[[ " \$* " == *" --dry-run "* ]] && { echo "[INFO] dry run: would \$action $2" >&2; exit 0; }
case "\$action" in
describe) jq -n '{schema_version: 1, name: "$2", type: "$1", component_version: "1.2", requires: $3, platforms: ["debian", "ubuntu"], options: [
    {name: "port", default: "11434", secret: false, type: "integer", min: 1, max: 65535, description: "Listening port"},
    {name: "open", default: "true", secret: false, type: "boolean", description: "Open to all", warn: {when: "true", message: "it is open"}},
    {name: "mode", default: "a", secret: false, type: "enum", values: ["a", "b"], description: "Mode"},
    {name: "label", default: "", secret: false, description: "Free text"},
    {name: "api-key", default: "generated", secret: true, description: "Key"}]} + $extra' ;;
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
# one_document: stdout is exactly one JSON document.
one_document() { [ "$(jq -s 'length' <<<"$output")" = 1 ]; }

# --- catalog -------------------------------------------------------------------------------

@test "catalog --json lists the shipped components, in install order of their types, then by rank" {
    cli catalog --json
    [ "$status" -eq 0 ]
    one_document
    [ "$(jq -r .schema_version <<<"$output")" = 1 ]
    run jq -r '.components | map("\(.type):\(.name):\(.rank)") | join(" ")' <<<"$output"
    [ "$output" = "provisioning:fit:1 proxy:prox:1 engine:eng2:1 engine:eng:2 chat-interface:chat:1" ]
}

@test "catalog: the describe is verbatim, the default model is on engines only, unranked is null, a ranked ghost is absent" {
    cli catalog --json
    run jq -c '[.components[] | select(.name == "eng2") | .default_model, .describe.component_version, (.describe.options | length)]' <<<"$output"
    [ "$output" = '["small-model","1.2",5]' ]
    cli --json catalog
    [ "$(jq -r '[.components[] | select(.name == "eng") | .default_model] | .[0]' <<<"$output")" = "null" ]
    [ "$(jq -r '[.components[] | select(.type == "proxy") | has("default_model")] | .[0]' <<<"$output")" = "false" ]
    [ "$(jq -r '[.components[].name] | index("ghost")' <<<"$output")" = "null" ]
    rm "$EASY_CS_AI_HOME/ranks.conf"
    cli catalog --json
    [ "$(jq -r '[.components[] | select(.name == "eng") | .rank] | .[0]' <<<"$output")" = "null" ]
}

@test "catalog without --json is a table for humans, and needs no root nor state" {
    cli catalog
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "TYPE"*"NAME"*"RANK"* ]]
    [[ "$output" == *"engine"*"eng2"*"small-model"* ]]
    [[ "$output" != "{"* ]]
    [ ! -d "$STATE" ]
}

@test "catalog takes no argument" {
    cli catalog now
    [ "$status" -eq 2 ]
}

# --- host ----------------------------------------------------------------------------------

fake_host() {
    mkdir -p "$EASY_CS_AI_ROOT/etc" "$EASY_CS_AI_ROOT/proc" "$EASY_CS_AI_ROOT/run/systemd/system"
    printf 'ID=ubuntu\nID_LIKE="debian"\nVERSION_ID="24.04"\n' >"$EASY_CS_AI_ROOT/etc/os-release"
    printf 'processor\t: 0\nmodel name\t: Fake CPU 3000\nprocessor\t: 1\nmodel name\t: Fake CPU 3000\n' >"$EASY_CS_AI_ROOT/proc/cpuinfo"
    printf 'MemTotal:        8192000 kB\nMemFree: 1 kB\n' >"$EASY_CS_AI_ROOT/proc/meminfo"
}

@test "host --json reports the facts it can read" {
    fake_host
    cli host --json
    [ "$status" -eq 0 ]
    one_document
    run jq -c '[.platform.id, .platform.id_like, .platform.version, .platform.systemd, .cpu.cores, .cpu.model, .ram_mb, .gpus, .root]' <<<"$output"
    [ "$output" = '["ubuntu","debian","24.04",true,2,"Fake CPU 3000",8000,[],false]' ]
    cli host --json
    [ "$(jq -r '.disk.free_mb | type' <<<"$output")" = number ]
    [ "$(jq -r '.docker.installed | type' <<<"$output")" = boolean ]
}

@test "host: what cannot be read is null, never guessed" {
    cli host --json
    run jq -c '[.platform.id, .platform.version, .cpu.cores, .cpu.model, .ram_mb, .platform.systemd]' <<<"$output"
    [ "$output" = '[null,null,null,null,null,false]' ]
}

@test "host reads the GPUs from nvidia-smi, else from lspci" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho "NVIDIA RTX 4090, 24564"\n' >"$BATS_TEST_TMPDIR/bin/nvidia-smi"
    chmod +x "$BATS_TEST_TMPDIR/bin/nvidia-smi"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" cli host --json
    [ "$(jq -c '.gpus' <<<"$output")" = '[{"vendor":"nvidia","name":"NVIDIA RTX 4090","vram_mb":24564}]' ]
    rm "$BATS_TEST_TMPDIR/bin/nvidia-smi"
    printf '#!/bin/sh\necho "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics"\n' >"$BATS_TEST_TMPDIR/bin/lspci"
    chmod +x "$BATS_TEST_TMPDIR/bin/lspci"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" cli host --json
    [ "$(jq -c '.gpus[0] | [.vendor, .vram_mb]' <<<"$output")" = '["intel",null]' ]
}

@test "host without --json is a few readable lines" {
    fake_host
    cli host
    [ "$status" -eq 0 ]
    [[ "$output" == *"platform: ubuntu 24.04"* && "$output" == *"memory:   8000 MB"* ]]
    [[ "$output" != "{"* ]]
}

# --- config validate: the document ---------------------------------------------------------

# vmfile <components-json> [<links-json>]: a file of one VM named vm-1.
vmfile() {
    printf '{"schema_version":2,"vms":[{"name":"vm-1","components":%s}]%s}' "$1" "${2:+,\"links\":$2}"
}

full_config() {
    cat >"$CFG" <<'JSON'
{
  "schema_version": 2,
  "vms": [ { "name": "vm-1", "components": [
    { "component": "chat-interface/chat", "name": "chat", "default": true },
    { "component": "engine/eng", "name": "eng", "default": true, "options": { "port": 11500, "api-key": { "env": "KEY" } },
      "models": [ { "model": "m1", "name": "m1", "force": true } ] },
    { "component": "proxy/prox" }
  ] } ],
  "links": [ { "model": { "vm_ref": "vm-1", "component_ref": "eng", "model_ref": "m1" },
               "chat_interface": { "vm_ref": "vm-1", "component_ref": "chat" } } ]
}
JSON
}

@test "config validate --json: ok, the plan per VM in install order, the models and the links, the warnings, one document" {
    full_config
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
    one_document
    run jq -c '[.schema_version, .ok, .target, .errors, (.plan.vms | map(.name)), (.plan.vms[0].components | map("\(.order):\(.component)")), .plan.vms[0].models, .plan.vms[0].prune, .plan.links]' <<<"$output"
    [ "$output" = '[2,true,"this",[],["vm-1"],["1:engine/eng","2:proxy/prox","3:chat-interface/chat"],[{"model":"m1","name":"m1","engine":{"vm_ref":"vm-1","component_ref":"eng","component":"engine/eng"},"force":true}],false,[{"model":{"vm_ref":"vm-1","component_ref":"eng","model_ref":"m1","component":"engine/eng"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat","component":"chat-interface/chat"}}]]' ]
    cli config validate "$CFG" --json
    # a secret is shown as its source, never as a value
    [ "$(jq -c '.plan.vms[0].components[0].options' <<<"$output")" = '{"port":11500,"api-key":{"env":"KEY"}}' ]
    # nothing to do between machines: step 1 alone
    [ "$(jq -c '.next_steps' <<<"$output")" = '["Run each script as root on its VM."]' ]
}

@test "config validate: the warn entries of describe whose condition holds, the default value included" {
    full_config
    cli config validate "$CFG" --json
    run jq -c '.warnings | map(select(.option != null) | [.path, .component_ref, .component, .option, .value, .message, .vm_ref])' <<<"$output"
    [ "$output" = '[["$.vms[0].components[0]","chat","chat-interface/chat","open","true","it is open","vm-1"],["$.vms[0].components[1]","eng","engine/eng","open","true","it is open","vm-1"],["$.vms[0].components[2]",null,"proxy/prox","open","true","it is open","vm-1"]]' ]
    jq '.vms[0].components[0].options = {"open": false}' "$CFG" >"$CFG.2"
    cli config validate "$CFG.2" --json
    [ "$(jq -r '.warnings | map(select(.option != null) | .component) | join(",")' <<<"$output")" = "engine/eng,proxy/prox" ]
    # a model written with force and no provisioning component gives the warning of the validation
    [ "$(jq -c '.warnings | map(select(.code != null) | [.code, .path, .vm_ref])' <<<"$output")" = '[["models_not_checked","$.vms[0]","vm-1"]]' ]
}

@test "config validate: a warning does not change the exit code" {
    full_config
    cli config validate "$CFG"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"[WARN] chat-interface/chat --open=true: it is open"* ]]
}

@test "config validate: without --json the output is for humans, on stderr, and stdout is empty" {
    full_config
    cli config validate "$CFG"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"plan: [vm-1] install engine/eng --port 11500"*"plan: [vm-1] install proxy/prox"*"plan: [vm-1] add m1 to eng"* ]]
    [[ "$stderr" == *"What is left to do once the VMs are up:"*"1. Run each script as root on its VM."* ]]
}

@test "config validate --target this marks the installed components, fresh ignores what is installed" {
    full_config
    cli install proxy prox
    cli config validate "$CFG" --json
    [ "$(jq -c '.plan.vms[0].components | map(.installed)' <<<"$output")" = "[false,false,true]" ]
    vmfile '[{"component":"chat-interface/chat"}]' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 2 ]
    [ "$(jq -r '.target, .errors[0].code' <<<"$output" | paste -sd' ')" = "fresh missing_requirement" ]
    [ "$(jq -r '.plan' <<<"$output")" = "null" ]
    [ "$(jq -c '.next_steps' <<<"$output")" = "[]" ]
}

@test "config validate reads stdin with -" {
    full_config
    run --separate-stderr bash -c 'bash "$0" config validate - --json <"$1"' "$CLI" "$CFG"
    [ "$status" -eq 0 ]
    [ "$(jq -r .ok <<<"$output")" = "true" ]
}

@test "config validate needs no root, reads nothing it should not, and installs nothing" {
    full_config
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ] || ! grep -q ' install' "$CALLS"
    ! installed eng
}

@test "config validate: usage errors exit 2 with nothing on stdout" {
    cli config validate
    [ "$status" -eq 2 ]
    cli config validate "$CFG.missing" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    full_config
    cli config validate "$CFG" --target moon
    [ "$status" -eq 2 ]
    cli config validate "$CFG" --target
    [ "$status" -eq 2 ]
    cli config validate "$CFG" --bogus
    [ "$status" -eq 2 ]
    cli config
    [ "$status" -eq 2 ]
    cli config nothing
    [ "$status" -eq 2 ]
}

# --- config validate: the codes ------------------------------------------------------------

# problems <json> [<extra args>]: validate a configuration given as text; prints "path code" lines.
problems() {
    printf '%s' "$1" >"$CFG"
    cli config validate "$CFG" --json "${@:2}"
    [ "$status" -eq 2 ]
    one_document
    [ "$(jq -r .ok <<<"$output")" = "false" ]
    [ "$(jq -r .plan <<<"$output")" = "null" ]
    jq -r '.errors[] | "\(.path) \(.code)"' <<<"$output"
}
# one VM, unnamed, with these components
v() { printf '{"schema_version":2,"vms":[{"components":%s}]}' "$1"; }

@test "codes: structure" {
    run problems '{"schema_version":2,"vms":[],"bogus":1}'
    [ "$output" = '$.bogus unknown_key' ]
    run problems '{"vms":[]}'
    [ "$output" = '$.schema_version missing_key' ]
    run problems '{"schema_version":"2","vms":[]}'
    [ "$output" = '$.schema_version wrong_type' ]
    run problems '{"schema_version":3,"vms":[]}'
    [ "$output" = '$.schema_version unsupported_schema_version' ]
    run problems '{"schema_version":1,"vms":[]}'
    [ "$output" = '$.schema_version unsupported_schema_version' ]
    run problems '[1]'
    [ "$output" = '$ wrong_type' ]
    run problems '{"schema_version":2}'
    [ "$output" = '$.vms missing_key' ]
    run problems '{"schema_version":2,"vms":{}}'
    [ "$output" = '$.vms wrong_type' ]
    run problems '{"schema_version":2,"vms":[1]}'
    [ "$output" = '$.vms[0] wrong_type' ]
    run problems '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng"}],"x":1}]}'
    [ "$output" = '$.vms[0].x unknown_key' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng"}]}'
    [[ "$output" == *'$.schema_version unsupported_schema_version'* && "$output" == *'$.components unknown_key'* ]]
}

@test "codes: VMs" {
    run problems '{"schema_version":2,"vms":[{"name":"a"}]}'
    [ "$output" = '$.vms[0].components missing_key' ]
    run problems '{"schema_version":2,"vms":[{"name":"a","components":[]}]}'
    [ "$output" = '$.vms[0] empty_vm' ]
    run problems '{"schema_version":2,"vms":[{"name":7,"components":[{"component":"engine/eng"}]}]}'
    [ "$output" = '$.vms[0].name wrong_type' ]
    run problems '{"schema_version":2,"vms":[{"name":"Big","components":[{"component":"engine/eng"}]}]}'
    [ "$output" = '$.vms[0].name invalid_value' ]
    run problems '{"schema_version":2,"vms":[{"name":"a","components":[{"component":"engine/eng"}]},{"name":"a","components":[{"component":"engine/eng"}]}]}' --target fresh
    [ "$output" = '$.vms[1].name duplicate_vm' ]
    run problems '{"schema_version":2,"vms":[{"name":"a","components":[{"component":"engine/eng"}]},{"components":[{"component":"engine/eng"}]}]}' --target fresh
    [ "$output" = '$.vms[1] missing_vm_name' ]
}

@test "codes: components" {
    run problems "$(v '[{"component":"plugin/x"}]')"
    [ "$output" = '$.vms[0].components[0].component unknown_type' ]
    run problems "$(v '[{"component":"engine/nope"}]')"
    [ "$output" = '$.vms[0].components[0].component unknown_component' ]
    run problems "$(v '[{"component":"engine"}]')"
    [ "$output" = '$.vms[0].components[0].component invalid_value' ]
    run problems "$(v '[{"component":7}]')"
    [ "$output" = '$.vms[0].components[0].component wrong_type' ]
    run problems "$(v '[{}]')"
    [ "$output" = '$.vms[0].components[0].component missing_key' ]
    run problems "$(v '[{"component":"engine/eng","name":"Eng"}]')"
    [ "$output" = '$.vms[0].components[0].name invalid_value' ]
    run problems "$(v '[{"component":"engine/eng","name":"a"},{"component":"engine/eng2","name":"a"}]')"
    [ "$output" = '$.vms[0].components[1].name duplicate_name' ]
    run problems "$(v '[{"component":"engine/eng"},{"component":"engine/eng","name":"other"}]')"
    [ "$output" = '$.vms[0].components[1] duplicate_component' ]
    run problems "$(v '[{"component":"engine/eng","default":true},{"component":"engine/eng2","default":true}]')"
    [ "$output" = '$.vms[0].components[1].default several_defaults' ]
    run problems "$(v '[{"component":"engine/eng","default":"yes"}]')"
    [ "$output" = '$.vms[0].components[0].default wrong_type' ]
    run problems "$(v '[{"component":"chat-interface/chat"}]')"
    [ "$output" = '$.vms[0].components[0] missing_requirement' ]
    run problems "$(v '[{"component":"engine/eng","x":1}]')"
    [ "$output" = '$.vms[0].components[0].x unknown_key' ]
}

@test "the same component on two VMs is accepted, a requirement on another VM is not" {
    printf '%s' '{"schema_version":2,"vms":[{"name":"a","components":[{"component":"proxy/prox"}]},{"name":"b","components":[{"component":"proxy/prox"}]}]}' >"$CFG"
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    run problems '{"schema_version":2,"vms":[{"name":"a","components":[{"component":"proxy/prox"}]},{"name":"b","components":[{"component":"chat-interface/chat"}]}]}' --target fresh
    [ "$output" = '$.vms[1].components[0] missing_requirement' ]
}

@test "codes: options" {
    run problems "$(v '[{"component":"engine/eng","options":{"colour":"red"}}]')"
    [ "$output" = '$.vms[0].components[0].options.colour unknown_option' ]
    run problems "$(v '[{"component":"engine/eng","options":{"label":[1]}}]')"
    [ "$output" = '$.vms[0].components[0].options.label wrong_type' ]
    run problems "$(v '[{"component":"engine/eng","options":"x"}]')"
    [ "$output" = '$.vms[0].components[0].options wrong_type' ]
    run problems "$(v '[{"component":"engine/eng","options":{"api-key":"s3cret"}}]')"
    [ "$output" = '$.vms[0].components[0].options.api-key secret_literal' ]
    run problems "$(v '[{"component":"engine/eng","options":{"api-key":{"file":"/a","env":"B"}}}]')"
    [ "$output" = '$.vms[0].components[0].options.api-key secret_source' ]
    run problems "$(v '[{"component":"engine/eng","options":{"api-key":{"generate":false}}}]')"
    [ "$output" = '$.vms[0].components[0].options.api-key secret_source' ]
}

@test "codes: typed options are checked before anything runs" {
    local base='{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","options":{'
    run problems "$base"'"port":99999}}]}]}'
    [ "$output" = '$.vms[0].components[0].options.port invalid_value' ]
    run problems "$base"'"port":0}}]}]}'
    [ "$output" = '$.vms[0].components[0].options.port invalid_value' ]
    run problems "$base"'"port":"http"}}]}]}'
    [ "$output" = '$.vms[0].components[0].options.port invalid_value' ]
    run problems "$base"'"port":1.5}}]}]}'
    [ "$output" = '$.vms[0].components[0].options.port invalid_value' ]
    run problems "$base"'"open":"maybe"}}]}]}'
    [ "$output" = '$.vms[0].components[0].options.open invalid_value' ]
    run problems "$base"'"open":3}}]}]}'
    [ "$output" = '$.vms[0].components[0].options.open invalid_value' ]
    run problems "$base"'"mode":"c"}}]}]}'
    [ "$output" = '$.vms[0].components[0].options.mode invalid_value' ]
    jq -r '.errors[0].message' <<<"$(bash "$CLI" config validate "$CFG" --json 2>/dev/null)" | grep -q "one of a, b is expected"
}

@test "typed options accept the JSON type or its text, as the CLI passes the text" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 2, "vms": [ { "components": [ { "component": "engine/eng",
  "options": { "port": "11500", "open": "false", "mode": "b" } },
  { "component": "proxy/prox", "options": { "port": 443, "open": true } } ] } ] }
JSON
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
}

@test "codes: models" {
    run problems "$(v '[{"component":"proxy/prox","models":[]}]')"
    [ "$output" = '$.vms[0].components[0].models models_on_non_engine' ]
    run problems "$(v '[{"component":"engine/eng","models":{}}]')"
    [ "$output" = '$.vms[0].components[0].models wrong_type' ]
    run problems "$(v '[{"component":"engine/eng","models":[1]}]')"
    [ "$output" = '$.vms[0].components[0].models[0] wrong_type' ]
    run problems "$(v '[{"component":"engine/eng","models":[{}]}]')"
    [ "$output" = '$.vms[0].components[0].models[0].model missing_key' ]
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"m","chat_interfaces":[]}]}]')"
    [[ "$output" == *'$.vms[0].components[0].models[0].chat_interfaces unknown_key'* ]]
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"m","force":"yes"}]}]')"
    [[ "$output" == *'$.vms[0].components[0].models[0].force wrong_type'* ]]
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"m","name":""}]}]')"
    [[ "$output" == *'$.vms[0].components[0].models[0].name invalid_value'* ]]
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"m","name":7}]}]')"
    [[ "$output" == *'$.vms[0].components[0].models[0].name wrong_type'* ]]
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"m","force":true},{"model":"m","force":true}]}]')"
    [[ "$output" == *'$.vms[0].components[0].models[1].model duplicate_model'* ]]
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"a","name":"x","force":true},{"model":"b","name":"x","force":true}]}]')"
    [[ "$output" == *'$.vms[0].components[0].models[1].name duplicate_name'* ]]
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"m","options":{"x":1},"force":true}]}]')"
    [[ "$output" == *'$.vms[0].components[0].models[0].options.x unknown_option'* ]]
}

@test "the same model in two engines is accepted" {
    vmfile '[{"component":"proxy/prox"},{"component":"engine/eng","models":[{"model":"m","force":true}]},{"component":"engine/eng2","models":[{"model":"m","force":true}]}]' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
}

@test "codes: what a model needs, at the path of the model" {
    run problems "$(v '[{"component":"engine/eng","models":[{"model":"m","force":true}]}]')"
    [ "$output" = '$.vms[0].components[0].models[0] missing_requirement' ]
    run problems "$(v '[{"component":"proxy/prox"},{"component":"engine/eng","models":[{"model":"m"}]}]')"
    [ "$output" = '$.vms[0].components[1].models[0] missing_requirement' ]
    # accepted once the proxy is installed here, a model with force needs no provisioning component
    cli install proxy prox
    vmfile '[{"component":"engine/eng","models":[{"model":"m","force":true}]}]' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 2 ]
}

@test "codes: links" {
    make_fake chat-interface chat2 '["proxy"]'
    local files='{"component":"proxy/prox"},{"component":"engine/eng","name":"eng","models":[{"model":"m","name":"m","force":true}]},{"component":"chat-interface/chat","name":"chat"}'
    local ok='{"model":{"vm_ref":"vm-1","component_ref":"eng","model_ref":"m"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}'
    run problems "$(vmfile "[$files]" "[$ok,$ok]")"
    [ "$output" = '$.links[1] duplicate_link' ]
    run problems "$(vmfile "[$files,{\"component\":\"chat-interface/chat2\",\"name\":\"chat2\"}]" "[$ok,$(sed 's/"chat"/"chat2"/' <<<"$ok")]")"
    [ "$output" = '$.links[1] unsupported_count' ]
    run problems "$(vmfile "[$files]" '[{"model":{"vm_ref":"vm-1","component_ref":"eng"},"chat_interface":{"vm_ref":"vm-1"}}]')"
    [[ "$output" == *'$.links[0].model missing_key'* && "$output" == *'$.links[0].chat_interface missing_key'* ]]
    run problems "$(vmfile "[$files]" '[{"model":{"vm_ref":"zz","component_ref":"eng","model_ref":"m"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}]')"
    [ "$output" = '$.links[0].model.vm_ref unknown_vm' ]
    run problems "$(vmfile "[$files]" '[{"model":{"vm_ref":"vm-1","component_ref":"nope","model_ref":"m"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}]')"
    [ "$output" = '$.links[0].model.component_ref unresolved_engine' ]
    run problems "$(vmfile "[$files]" '[{"model":{"vm_ref":"vm-1","component_ref":"eng","model_ref":"zz"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}]')"
    [ "$output" = '$.links[0].model.model_ref unresolved_model' ]
    run problems "$(vmfile "[$files]" '[{"model":{"vm_ref":"vm-1","component_ref":"eng","model_ref":"m"},"chat_interface":{"vm_ref":"vm-1","component_ref":"eng"}}]')"
    [ "$output" = '$.links[0].chat_interface.component_ref unresolved_chat_interface' ]
    # a component with no name cannot be designated
    run problems "$(vmfile '[{"component":"proxy/prox"},{"component":"engine/eng","models":[{"model":"m","force":true}]},{"component":"chat-interface/chat"}]' "[$ok]")"
    [[ "$output" == *'$.links[0].model.component_ref unresolved_engine'* ]]
}

@test "codes: a link of a protected engine to another VM" {
    cat >"$EASY_CS_AI_HOME/engine/prot.sh" <<'FAKE'
#!/usr/bin/env bash
jq -n '{name: "prot", type: "engine", requires: [], platforms: ["debian"], options: [], endpoint: {protected: true}}'
FAKE
    local web='{"name":"web","components":[{"component":"proxy/prox"},{"component":"chat-interface/chat","name":"chat"}]}'
    local eng='{"name":"gpu","components":[{"component":"engine/prot","name":"prot","models":[{"model":"m","name":"m","force":true}]}]}'
    printf '%s' '{"schema_version":2,"vms":['"$eng,$web"'],"links":[{"model":{"vm_ref":"gpu","component_ref":"prot","model_ref":"m"},"chat_interface":{"vm_ref":"web","component_ref":"chat"}}]}' >"$CFG"
    run problems "$(cat "$CFG")" --target fresh
    [ "$output" = '$.links[0] protected_engine_other_vm' ]
    # on the same VM it is accepted
    printf '%s' '{"schema_version":2,"vms":[{"name":"gpu","components":[{"component":"proxy/prox"},{"component":"chat-interface/chat","name":"chat"},{"component":"engine/prot","name":"prot","models":[{"model":"m","name":"m","force":true}]}]}],"links":[{"model":{"vm_ref":"gpu","component_ref":"prot","model_ref":"m"},"chat_interface":{"vm_ref":"gpu","component_ref":"chat"}}]}' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
}

@test "a model with no link is accepted, a link designates by name and not by default" {
    vmfile '[{"component":"proxy/prox"},{"component":"engine/eng","default":true,"name":"eng","models":[{"model":"m","name":"m","force":true}]},{"component":"engine/eng2","name":"eng2"},{"component":"chat-interface/chat","name":"chat"}]' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.links' <<<"$output")" = "[]" ]
    jq '.links = [{"model":{"vm_ref":"vm-1","component_ref":"eng2","model_ref":"m"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}]' "$CFG" >"$CFG.2"
    cli config validate "$CFG.2" --json
    [ "$(jq -r '.errors[0].code' <<<"$output")" = unresolved_model ]
}

@test "codes: a platform the component does not support, only for this machine" {
    export EASY_CS_AI_HOST_IDS="fedora rhel"
    v '[{"component":"engine/eng"}]' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0] | "\(.path) \(.code)"' <<<"$output")" = '$.vms[0].components[0].component unsupported_platform' ]
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    export EASY_CS_AI_HOST_IDS="linuxmint ubuntu debian"
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
}

@test "codes: not JSON, with the document and exit 2" {
    echo '{nope' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 2 ]
    one_document
    [ "$(jq -c '[.ok, .errors[0].code, .errors[0].path, .plan]' <<<"$output")" = '[false,"not_json","$",null]' ]
    cli config validate "$CFG"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"not valid JSON"* ]]
}

@test "config validate reports every problem at once, with the message of the human form" {
    printf '%s' '{"schema_version":2,"bogus":1,"vms":[{"components":[{"component":"engine/eng","options":{"port":0,"colour":1}}]}]}' >"$CFG"
    cli config validate "$CFG" --json
    [ "$(jq '.errors | length' <<<"$output")" = 3 ]
    cli config validate "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *'$.bogus: unknown key'*'$.vms[0].components[0].options.port: an integer between 1 and 65535 is expected'* ]]
}

# --- several VMs: the slices, the steps, the cross checks -----------------------------------

two_vms() {
    cat >"$CFG" <<'JSON'
{ "schema_version": 2, "vms": [
  { "name": "gpu", "components": [ { "component": "proxy/prox" },
      { "component": "engine/eng", "name": "eng", "models": [ { "model": "m1", "name": "m1", "force": true } ] } ] },
  { "name": "web", "components": [ { "component": "proxy/prox" }, { "component": "chat-interface/chat", "name": "chat" } ] } ],
  "links": [ { "model": { "vm_ref": "gpu", "component_ref": "eng", "model_ref": "m1" },
               "chat_interface": { "vm_ref": "web", "component_ref": "chat" } } ] }
JSON
}

@test "config validate on several VMs: one plan per VM in the order of the file, the links as resolved" {
    two_vms
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.vms | map([.name, (.components | map(.component)), (.models | map(.model))])' <<<"$output")" = '[["gpu",["proxy/prox","engine/eng"],["m1"]],["web",["proxy/prox","chat-interface/chat"],[]]]' ]
    [ "$(jq -c '.plan.links | map([.model.vm_ref, .chat_interface.vm_ref])' <<<"$output")" = '[["gpu","web"]]' ]
}

@test "config validate --target this needs --vm on a file of several VMs, and plans that slice alone" {
    two_vms
    cli config validate "$CFG" --json
    [ "$status" -eq 2 ]
    cli config validate "$CFG" --json --vm zzz
    [ "$status" -eq 2 ]
    cli config validate "$CFG" --json --vm gpu
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.vms | map(.name)' <<<"$output")" = '["gpu"]' ]
    [ "$(jq -c '.plan.links' <<<"$output")" = '[]' ]
    [ "$(jq -c '.next_steps' <<<"$output")" = '["Run each script as root on its VM."]' ]
}

@test "next steps: a link to another VM gives the steps of the contract, when the describes have them" {
    make_fake proxy prox '[]' '{"actions":["install","status","show-key","list-upstreams"]}'
    make_fake chat-interface chat '["proxy"]' '{"action_options":{"add-endpoint":[{"name":"model"},{"name":"api-key-file"},{"name":"ca-file"}]}}'
    two_vms
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    [ "$(jq -r '.next_steps | length' <<<"$output")" -eq 4 ]
    [ "$(jq -r '.next_steps[0]' <<<"$output")" = "Run each script as root on its VM, the engine VMs first." ]
    [[ "$(jq -r '.next_steps[3]' <<<"$output")" == *"On the VM web, link each model of the VM gpu:"*"add-endpoint gpu-eng-m1 <url>"*"--model m1"* ]]
    # the address of the engine VM is not known: the warning, once
    [ "$(jq -r '[.warnings[] | select(.code == "engine_address_unknown") | .vm_ref] | join(",")' <<<"$output")" = gpu ]
    # a server-name written removes it
    jq '.vms[0].components[0].options = {"server-name": "gpu.example.org"}' "$CFG" >"$CFG.2"
    cli config validate "$CFG.2" --json --target fresh
    [ "$(jq '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" -eq 0 ]
}

@test "duplicate_server_name: two VMs writing the same server-name are an error at the path of the second" {
    make_fake proxy prox '[]' '{"options":[{"name":"server-name","default":"","secret":false}]}'
    two_vms
    jq '.vms[0].components[0].options = {"server-name": "A.example.org"} | .vms[1].components[0].options = {"server-name": "a.example.org"}' "$CFG" >"$CFG.2"
    cli config validate "$CFG.2" --json --target fresh
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0] | "\(.path) \(.code) \(.vm_ref)"' <<<"$output")" = '$.vms[1].components[0].options.server-name duplicate_server_name web' ]
    cli config validate "$CFG.2" --json --vm web
    [ "$status" -eq 0 ]
}

# a proxy that declares what nginx declares: tls-cert and tls-key required with tls provided, server-name and
# tls-accept-terms required with letsencrypt, tls-key never generated
make_tls_proxy() {
    make_fake proxy prox '[]' '{"options":[
      {"name":"tls","default":"self-signed","secret":false,"type":"enum","values":["self-signed","provided","letsencrypt"]},
      {"name":"server-name","default":"","secret":false,"required_when":{"option":"tls","values":["letsencrypt"]}},
      {"name":"tls-cert","default":"","secret":false,"relevant_when":{"option":"tls","values":["provided"]},"required_when":{"option":"tls","values":["provided"]}},
      {"name":"tls-key","default":"","secret":true,"sources":["file","env"],"required_when":{"option":"tls","values":["provided"]}},
      {"name":"tls-accept-terms","default":"false","secret":false,"type":"boolean","required_when":{"option":"tls","values":["letsencrypt"]}}]}'
}

@test "codes: missing_option, an option the component requires with the choices made, at the path of its options" {
    make_tls_proxy
    run problems "$(v '[{"component":"proxy/prox","options":{"tls":"letsencrypt"}}]')"
    [ "$output" = "$(printf '%s
%s' '$.vms[0].components[0].options missing_option' '$.vms[0].components[0].options missing_option')" ]
    [[ "$(jq -r '.errors[0].message' <<<"$(bash "$CLI" config validate "$CFG" --target fresh --json 2>/dev/null)")" == "option server-name is required when tls is letsencrypt" ]]
    run problems "$(v '[{"component":"proxy/prox","options":{"tls":"provided"}}]')"
    [ "$(grep -c missing_option <<<"$output")" -eq 2 ]
    # not raised when the condition does not hold, nor when the options are given
    vmfile '[{"component":"proxy/prox"}]' >"$CFG"
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    vmfile '[{"component":"proxy/prox","options":{"tls":"letsencrypt","server-name":"a.example.org","tls-accept-terms":true}}]' >"$CFG"
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
}

@test "a secret that declares its sources refuses the others, and the schema encodes both rules" {
    make_tls_proxy
    run problems "$(v '[{"component":"proxy/prox","options":{"tls":"provided","tls-cert":"/c","tls-key":{"generate":true}}}]')"
    [ "$output" = '$.vms[0].components[0].options.tls-key secret_source' ]
    vmfile '[{"component":"proxy/prox","options":{"tls":"provided","tls-cert":"/c","tls-key":{"file":"/k"}}}]' >"$CFG"
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    cli config schema
    node='.properties.vms.items.properties.components.items.oneOf[] | select(.properties.component.const == "proxy/prox")'
    [ "$(jq -r "$node"' | .properties.options.properties["tls-key"].oneOf | map(.required[0]) | join(",")' <<<"$output")" = "file,env" ]
    [ "$(jq -c "$node"' | [.allOf[] | .description]' <<<"$output")" = '["option server-name is required when tls is letsencrypt","option tls-cert is required when tls is provided","option tls-key is required when tls is provided","option tls-accept-terms is required when tls is letsencrypt"]' ]
}

# --- apply --dry-run --json ----------------------------------------------------------------

@test "apply --dry-run --json prints the document of config validate --target this" {
    full_config
    cli apply "$CFG" --dry-run --json
    [ "$status" -eq 0 ]
    one_document
    expected="$(bash "$CLI" config validate "$CFG" --json 2>/dev/null)"
    [ "$output" = "$expected" ]
    cli --dry-run --json apply "$CFG" --prune
    [ "$(jq -r '.plan.vms[0].prune' <<<"$output")" = "true" ]
    ! installed eng
}

@test "apply --dry-run --json: an invalid file is exit 2, a requirement nothing satisfies keeps exit 4" {
    printf '%s' '{"schema_version":2,"vms":[],"bogus":1}' >"$CFG"
    cli apply "$CFG" --dry-run --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0].code' <<<"$output")" = unknown_key ]
    vmfile '[{"component":"chat-interface/chat"}]' >"$CFG"
    cli apply "$CFG" --dry-run --json
    [ "$status" -eq 4 ]
    [ "$(jq -r '.errors[0].code' <<<"$output")" = missing_requirement ]
    echo '{nope' >"$CFG"
    cli apply "$CFG" --dry-run --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0].code' <<<"$output")" = not_json ]
}

@test "apply --dry-run without --json shows the warnings with the plan" {
    full_config
    cli apply "$CFG" --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: install"*"[WARN] chat-interface/chat --open=true: it is open"* ]]
}

# --- config schema -------------------------------------------------------------------------

@test "config schema is one JSON Schema, generated from the catalog" {
    cli config schema
    [ "$status" -eq 0 ]
    one_document
    run jq -r '."$schema"' <<<"$output"
    [[ "$output" == *"2020-12"* ]]
    cli config schema
    [ "$(jq -c '.properties.schema_version' <<<"$output")" = '{"const":2}' ]
    [ "$(jq -c '.required' <<<"$output")" = '["schema_version","vms"]' ]
    [ "$(jq -c '.properties.vms.items.properties.components.items.oneOf | map(.properties.component.const)' <<<"$output")" = '["provisioning/fit","proxy/prox","engine/eng2","engine/eng","chat-interface/chat"]' ]
    [ "$(jq -c '.properties.vms.items.properties.components.items.properties.component.enum | length' <<<"$output")" = 5 ]
    # models are held by the engines only
    [ "$(jq -c '[.properties.vms.items.properties.components.items.oneOf[] | select(.properties.models != null) | .properties.component.const]' <<<"$output")" = '["engine/eng2","engine/eng"]' ]
    [ "$(jq -c '.properties.vms.items.properties.components.items.oneOf[] | select(.properties.component.const == "engine/eng") | .properties.models.items.required' <<<"$output")" = '["model"]' ]
    # a link is complete: every field of a reference is required
    [ "$(jq -c '.properties.links.items.properties.model.required' <<<"$output")" = '["vm_ref","component_ref","model_ref"]' ]
    [ "$(jq -c '.properties.links.items.properties.chat_interface.required' <<<"$output")" = '["vm_ref","component_ref"]' ]
    # the name of a VM is required when the file has several
    [ "$(jq -c '.allOf[0].then.properties.vms.items.required' <<<"$output")" = '["name"]' ]
}

@test "config schema: options are typed from describe, secrets are sources, warnings are in the description" {
    cli config schema
    opts='.properties.vms.items.properties.components.items.oneOf[] | select(.properties.component.const == "engine/eng") | .properties.options.properties'
    [ "$(jq -c "$opts"'.port.anyOf[0] | [.type, .minimum, .maximum]' <<<"$output")" = '["integer",1,65535]' ]
    [ "$(jq -c "$opts"'.mode.enum' <<<"$output")" = '["a","b"]' ]
    [ "$(jq -c "$opts"'.open.anyOf | map(.type // .enum)' <<<"$output")" = '["boolean",["true","false"]]' ]
    [ "$(jq -r "$opts"'."api-key".oneOf | map(.required[0]) | join(",")' <<<"$output")" = "file,env,generate" ]
    [[ "$(jq -r "$opts"'.open.description' <<<"$output")" == *"WARNING: it is open"* ]]
    [ "$(jq -r "$opts"'.label.type | join(",")' <<<"$output")" = "string,number,boolean" ]
    [ "$(jq -r '.properties.vms.items.properties.components.items.oneOf[] | select(.properties.component.const == "chat-interface/chat") | .description' <<<"$output")" = "chat-interface/chat, rank 1, requires proxy" ]
}

@test "config schema takes no argument" {
    cli config schema now
    [ "$status" -eq 2 ]
}

# --- guide ---------------------------------------------------------------------------------

@test "guide is text, short, and names the commands of the procedure" {
    cli guide
    [ "$status" -eq 0 ]
    [[ "$output" == *"catalog --json"*"host --json"*"config schema"*"config validate"*"apply FILE --json"* ]]
    [[ "$output" == *"Never"* || "$output" == *"Never run"* ]]
    [ "$(wc -l <<<"$output")" -lt 80 ]
    # the two orders of the model choice are a step of their own, with what an agent needs to read the answers
    [[ "$output" == *" 3. Choose the models. There are TWO ORDERS"* ]]
    [[ "$output" == *"HARDWARE FIRST"*"provisioning llmfit suggest --json"*"check MODEL"* ]]
    [[ "$output" == *"MODELS FIRST"*"provisioning llmfit plan MODEL@ENGINE... --json"*"--component TYPE/NAME"*"quantisations.best"*"margin_gb"*"unsized"*"ESTIMATE"* ]]
    [[ "$output" == *" 9. Never run"* ]]
    [[ "$output" != "{"* ]]
    cli guide now
    [ "$status" -eq 2 ]
}

# --- result documents of the changing commands ---------------------------------------------

@test "install --json: one result document, the steps that ran, the logs stay on stderr" {
    cli install proxy prox --json
    [ "$status" -eq 0 ]
    one_document
    run jq -c '[.schema_version, .command, .ok, .exit, .failed_step, .message, (.steps | map("\(.step):\(.exit)")), .rollback_complete]' <<<"$output"
    [ "$output" = '[1,"install",true,0,null,null,["install proxy prox:0"],true]' ]
    [[ "$stderr" == *"prox install runs"* ]]
    installed prox
}

@test "install --json of a failing step: the exit code, the failed step and its message" {
    FAKE_FAIL="eng-install" cli install engine eng --json
    [ "$status" -eq 5 ]
    one_document
    run jq -c '[.ok, .exit, .failed_step, .message, (.steps | map(.exit))]' <<<"$output"
    [ "$output" = '[false,5,"install engine eng","eng install broke",[5]]' ]
}

@test "a usage error is a result document too, with no failed step" {
    cli install --json
    [ "$status" -eq 2 ]
    one_document
    run jq -c '[.ok, .exit, .failed_step, (.message | test("install needs a component"))]' <<<"$output"
    [ "$output" = '[false,2,null,true]' ]
}

@test "add --json, remove --json and uninstall --json" {
    cli install --defaults
    cli add m1 --json
    [ "$status" -eq 0 ]
    one_document
    [ "$(jq -r '.command, .ok' <<<"$output" | paste -sd' ')" = "add true" ]
    [ "$(jq -r '.steps | map(.step) | join(",")' <<<"$output")" = "check provisioning fit,add-model engine eng2,add-upstream proxy prox,add-endpoint chat-interface chat" ]
    cli remove m1 --json
    [ "$(jq -r '.command, .ok' <<<"$output" | paste -sd' ')" = "remove true" ]
    cli uninstall --all --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.command, .ok' <<<"$output" | paste -sd' ')" = "uninstall true" ]
    ! installed eng2
}

@test "apply --json: the result of the run, a failing step stops it and is named" {
    full_config
    jq '.vms[0].components[1].options = {"port": 11500} | .vms[0].components += [{"component": "provisioning/fit"}] | del(.vms[0].components[1].models[0].force)' "$CFG" >"$CFG.2"
    cli apply "$CFG.2" --json
    [ "$status" -eq 0 ]
    one_document
    [ "$(jq -r '.command, .ok' <<<"$output" | paste -sd' ')" = "apply true" ]
    [ "$(jq -r '.steps | map(.step) | join(",")' <<<"$output")" = "install engine eng,install proxy prox,install chat-interface chat,install provisioning fit,check provisioning fit,add-model engine eng,add-upstream proxy prox,add-endpoint chat-interface chat" ]
    cli uninstall --all
    FAKE_FAIL="eng-install" cli apply "$CFG.2" --json
    [ "$status" -eq 5 ]
    [ "$(jq -r '.ok, .failed_step' <<<"$output" | paste -sd' ')" = "false install engine eng" ]
    ! installed chat
}

@test "apply --json: a failure outside a component script still names the step" {
    full_config
    jq 'del(.vms[0].components[1].models[0].force)' "$CFG" >"$CFG.2"
    KEY=x cli apply "$CFG.2" --json
    [ "$status" -eq 4 ]
    [ "$(jq -r '.ok, .failed_step, .message' <<<"$output" | paste -sd'|')" = "false|add m1|fit is required to add a model (exit 4: precondition not met)" ]
}

@test "with --dry-run, install, add and uninstall print their plan as the document" {
    # the CLI's own plan, then the plan of the component itself when --dry-run follows the command
    cli --dry-run --json install engine eng
    [ "$status" -eq 0 ]
    one_document
    run jq -c '[.command, .dry_run, .ok, (.plan | map(.step))]' <<<"$output"
    [[ "$output" == '["install",true,true,["would install engine eng'* ]]
    cli install engine eng --dry-run --json
    [ "$status" -eq 0 ]
    one_document
    [ "$(jq -c '[.dry_run, (.plan | map(.step))]' <<<"$output")" = '[true,["would install eng"]]' ]
    ! installed eng
    cli install --defaults
    cli add m1 --dry-run --json
    [ "$(jq -r '.dry_run, (.plan | length > 0)' <<<"$output" | paste -sd' ')" = "true true" ]
    [[ "$(jq -r '.plan[0].step' <<<"$output")" == "add m1 to eng2"* ]]
    cli --dry-run --json uninstall --all
    [ "$(jq -c '.plan | map(.step)' <<<"$output")" = '["uninstall chat-interface chat","uninstall engine eng2","uninstall proxy prox","uninstall provisioning fit"]' ]
    installed eng2
}

@test "without --json the changing commands print nothing on stdout, as before" {
    cli install proxy prox
    [ -z "$output" ]
}

@test "the general options are accepted after status, add, remove, apply and the new commands" {
    full_config
    cli status --json
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
    cli catalog --json
    [ "$(jq -r .schema_version <<<"$output")" = 1 ]
    cli apply "$CFG" --dry-run
    [ "$status" -eq 0 ]
    ! installed eng
}

# --- the shipped scripts --------------------------------------------------------------------

@test "every typed option of the shipped scripts is well formed and its default satisfies it" {
    export EASY_CS_AI_HOME="$REAL"
    cli catalog --json
    [ "$status" -eq 0 ]
    run jq -r '
      .components[] | .name as $n | .describe.options[] | select(.type != null) | . as $o
      | if $o.type == "integer" then
          (if ($o.default | test("^[0-9]+$")) and (($o.min == null) or (($o.default | tonumber) >= $o.min)) and (($o.max == null) or (($o.default | tonumber) <= $o.max)) then empty
           else "\($n) \($o.name): default \($o.default) is not an integer in range" end)
        elif $o.type == "boolean" then (if $o.default | IN("true", "false") then empty else "\($n) \($o.name): default \($o.default) is not a boolean" end)
        elif $o.type == "enum" then (if ($o.values | type) == "array" and ($o.values | index($o.default)) != null then empty else "\($n) \($o.name): default is not one of the values" end)
        else "\($n) \($o.name): unknown type \($o.type)" end' <<<"$output"
    [ -z "$output" ]
}

@test "the shipped scripts type their ports, timeouts, booleans and choices" {
    export EASY_CS_AI_HOME="$REAL"
    cli catalog --json
    run jq -r '.components[] | .name as $n | .describe.options[] | select(.type != null) | "\($n).\(.name)=\(.type)"' <<<"$output"
    for expected in ollama.port=integer ollama.health-timeout=integer nginx.port=integer nginx.site-port=integer nginx.tls=enum \
        nginx.tls-accept-terms=boolean librechat.port=integer librechat.db-port=integer librechat.allow-registration=boolean llmfit.lock-timeout=integer; do
        [[ "$output" == *"$expected"* ]] || { echo "missing $expected"; return 1; }
    done
}

@test "config validate on the shipped scripts: the default stack is valid, with the registration warning, and typed values are checked" {
    export EASY_CS_AI_HOME="$REAL"
    cat >"$CFG" <<'JSON'
{ "schema_version": 2, "vms": [ { "name": "vm-1", "components": [
  { "component": "provisioning/llmfit" },
  { "component": "proxy/nginx", "options": { "server-name": "ai.example.org", "port": 443 } },
  { "component": "engine/ollama", "name": "ollama", "default": true, "models": [ { "model": "llama3.2:3b", "name": "llama3.2:3b" } ] },
  { "component": "chat-interface/librechat", "name": "librechat", "options": { "allow-registration": false } } ] } ],
  "links": [ { "model": { "vm_ref": "vm-1", "component_ref": "ollama", "model_ref": "llama3.2:3b" },
               "chat_interface": { "vm_ref": "vm-1", "component_ref": "librechat" } } ] }
JSON
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    [ "$(jq -c '.warnings' <<<"$output")" = "[]" ]
    jq 'del(.vms[0].components[3].options)' "$CFG" >"$CFG.2"
    cli config validate "$CFG.2" --json --target fresh
    [ "$(jq -r '.warnings[0].option' <<<"$output")" = "allow-registration" ]
    jq '.vms[0].components[1].options.tls = "selfsigned" | .vms[0].components[2].options.port = 70000 | .vms[0].components[3].options["allow-registration"] = "nope"' "$CFG" >"$CFG.3"
    cli config validate "$CFG.3" --json --target fresh
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors | map(.code) | join(",")' <<<"$output")" = "invalid_value,invalid_value,invalid_value" ]
}

@test "config schema of the shipped scripts is a valid JSON Schema document with the shipped components" {
    export EASY_CS_AI_HOME="$REAL"
    cli config schema
    [ "$status" -eq 0 ]
    [ "$(jq -c '.properties.vms.items.properties.components.items.oneOf | map(.properties.component.const)' <<<"$output")" = '["provisioning/llmfit","proxy/nginx","engine/ollama","chat-interface/librechat"]' ]
    [ "$(jq -c '.properties.vms.items.properties.components.items.oneOf[] | select(.properties.component.const == "proxy/nginx") | .properties.options.properties.tls.enum' <<<"$output")" = '["self-signed","provided","letsencrypt"]' ]
}

@test "config validate ends its text on a verdict: valid with the counts, or invalid with the errors" {
    export EASY_CS_AI_CHARSET=ascii EASY_CS_AI_COLOR=never
    full_config
    export KEY=x
    cli config validate "$CFG"
    [[ "${stderr##*$'\n'}" != "" ]]
    [[ "$stderr" == *"ok valid 3 components, 1 model, "* ]]
    vmfile '[{"component":"nope/x"}]' >"$CFG"
    cli config validate "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"[ERROR] invalid 1 error, 0 warnings"* ]]
    cli config validate "$CFG" --json
    [[ "$output" != *"valid"*"components"* ]]
}
