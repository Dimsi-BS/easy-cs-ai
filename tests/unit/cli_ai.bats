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
    {name: "api-key", default: "generated", secret: true, description: "Key"}]}' ;;
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

full_config() {
    cat >"$CFG" <<'JSON'
{
  "schema_version": 1,
  "components": [
    { "type": "chat-interface", "name": "chat", "default": true },
    { "type": "engine", "name": "eng", "default": true, "options": { "port": 11500, "api-key": { "env": "KEY" } } },
    { "type": "proxy", "name": "prox" }
  ],
  "models": [ { "name": "m1", "force": true } ]
}
JSON
}

@test "config validate --json: ok, the plan in install order with the models resolved, the warnings, one document" {
    full_config
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
    one_document
    run jq -c '[.schema_version, .ok, .target, .errors, (.plan.components | map("\(.order):\(.name)")), .plan.models, .plan.prune]' <<<"$output"
    [ "$output" = '[1,true,"this",[],["1:eng","2:prox","3:chat"],[{"name":"m1","engine":"eng","chat_interface":"chat","force":true}],false]' ]
    cli config validate "$CFG" --json
    # a secret is shown as its source, never as a value
    [ "$(jq -c '.plan.components[0].options' <<<"$output")" = '{"port":11500,"api-key":{"env":"KEY"}}' ]
}

@test "config validate: the warn entries of describe whose condition holds, the default value included" {
    full_config
    cli config validate "$CFG" --json
    run jq -c '.warnings | map([.path, .component.name, .option, .value, .message])' <<<"$output"
    [ "$output" = '[["$.components[0]","chat","open","true","it is open"],["$.components[1]","eng","open","true","it is open"],["$.components[2]","prox","open","true","it is open"]]' ]
    jq '.components[0].options = {"open": false}' "$CFG" >"$CFG.2"
    cli config validate "$CFG.2" --json
    [ "$(jq -r '.warnings | map(.component.name) | join(",")' <<<"$output")" = "eng,prox" ]
}

@test "config validate: a warning does not change the exit code" {
    full_config
    cli config validate "$CFG"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"[WARN] chat --open=true: it is open"* ]]
}

@test "config validate: without --json the output is for humans, on stderr, and stdout is empty" {
    full_config
    cli config validate "$CFG"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"plan: install engine eng --port 11500"*"plan: install proxy prox"*"plan: add m1 to eng"* ]]
}

@test "config validate --target this marks the installed components, fresh ignores what is installed" {
    full_config
    cli install proxy prox
    cli config validate "$CFG" --json
    [ "$(jq -c '.plan.components | map(.installed)' <<<"$output")" = "[false,false,true]" ]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "chat-interface", "name": "chat" } ] }
JSON
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 2 ]
    [ "$(jq -r '.target, .errors[0].code' <<<"$output" | paste -sd' ')" = "fresh missing_requirement" ]
    [ "$(jq -r '.plan' <<<"$output")" = "null" ]
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

# code_of <json> [<extra args>]: validate a configuration given as text; prints "path code" lines.
problems() {
    printf '%s' "$1" >"$CFG"
    cli config validate "$CFG" --json "${@:2}"
    [ "$status" -eq 2 ]
    one_document
    [ "$(jq -r .ok <<<"$output")" = "false" ]
    [ "$(jq -r .plan <<<"$output")" = "null" ]
    jq -r '.errors[] | "\(.path) \(.code)"' <<<"$output"
}

@test "codes: structure" {
    run problems '{"schema_version":1,"bogus":1}'
    [ "$output" = '$.bogus unknown_key' ]
    run problems '{"components":[]}'
    [ "$output" = '$.schema_version wrong_type' ]
    run problems '{"schema_version":"1"}'
    [ "$output" = '$.schema_version wrong_type' ]
    run problems '{"schema_version":2}'
    [ "$output" = '$.schema_version unsupported_schema_version' ]
    run problems '[1]'
    [ "$output" = '$ wrong_type' ]
    run problems '{"schema_version":1,"components":{}}'
    [ "$output" = '$.components wrong_type' ]
    run problems '{"schema_version":1,"components":[1]}'
    [ "$output" = '$.components[0] wrong_type' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","x":1}]}'
    [ "$output" = '$.components[0].x unknown_key' ]
}

@test "codes: components" {
    run problems '{"schema_version":1,"components":[{"type":"plugin","name":"x"}]}'
    [ "$output" = '$.components[0].type unknown_type' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"nope"}]}'
    [ "$output" = '$.components[0].name unknown_component' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":7}]}'
    [ "$output" = '$.components[0].name wrong_type' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng"},{"type":"engine","name":"eng"}]}'
    [ "$output" = '$.components duplicate_component' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","default":true},{"type":"engine","name":"eng2","default":true}]}'
    [ "$output" = '$.components several_defaults' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","default":"yes"}]}'
    [ "$output" = '$.components[0].default wrong_type' ]
    run problems '{"schema_version":1,"components":[{"type":"chat-interface","name":"chat"}]}'
    [ "$output" = '$.components[0] missing_requirement' ]
}

@test "codes: options" {
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","options":{"colour":"red"}}]}'
    [ "$output" = '$.components[0].options.colour unknown_option' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","options":{"label":[1]}}]}'
    [ "$output" = '$.components[0].options.label wrong_type' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","options":"x"}]}'
    [ "$output" = '$.components[0].options wrong_type' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","options":{"api-key":"s3cret"}}]}'
    [ "$output" = '$.components[0].options.api-key secret_literal' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","options":{"api-key":{"file":"/a","env":"B"}}}]}'
    [ "$output" = '$.components[0].options.api-key secret_source' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","options":{"api-key":{"generate":false}}}]}'
    [ "$output" = '$.components[0].options.api-key secret_source' ]
}

@test "codes: typed options are checked before anything runs" {
    local base='{"schema_version":1,"components":[{"type":"engine","name":"eng","options":{'
    run problems "$base"'"port":99999}}]}'
    [ "$output" = '$.components[0].options.port invalid_value' ]
    run problems "$base"'"port":0}}]}'
    [ "$output" = '$.components[0].options.port invalid_value' ]
    run problems "$base"'"port":"http"}}]}'
    [ "$output" = '$.components[0].options.port invalid_value' ]
    run problems "$base"'"port":1.5}}]}'
    [ "$output" = '$.components[0].options.port invalid_value' ]
    run problems "$base"'"open":"maybe"}}]}'
    [ "$output" = '$.components[0].options.open invalid_value' ]
    run problems "$base"'"open":3}}]}'
    [ "$output" = '$.components[0].options.open invalid_value' ]
    run problems "$base"'"mode":"c"}}]}'
    [ "$output" = '$.components[0].options.mode invalid_value' ]
    jq -r '.errors[0].message' <<<"$(bash "$CLI" config validate "$CFG" --json 2>/dev/null)" | grep -q "one of a, b is expected"
}

@test "typed options accept the JSON type or its text, as the CLI passes the text" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng",
  "options": { "port": "11500", "open": "false", "mode": "b" } },
  { "type": "proxy", "name": "prox", "options": { "port": 443, "open": true } } ] }
JSON
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
}

@test "codes: models" {
    local c='{"schema_version":1,"components":[{"type":"engine","name":"eng"},{"type":"engine","name":"eng2"}'
    run problems "$c"'],"models":[{"name":"m"}]}'
    [ "$output" = '$.models[0].engine ambiguous_engine' ]
    run problems "$c"'],"models":[{"name":"m","engine":"zzz"}]}'
    [ "$output" = '$.models[0].engine unresolved_engine' ]
    run problems '{"schema_version":1,"models":[{"name":"m"}]}'
    [ "$output" = '$.models[0].engine unresolved_engine' ]
    run problems "$c"',{"type":"proxy","name":"prox"},{"type":"chat-interface","name":"chat"},{"type":"chat-interface","name":"chat"}],"models":[{"name":"m","engine":"eng"}]}'
    [[ "$output" == *'$.components duplicate_component'* ]]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng","default":true},{"type":"proxy","name":"prox"}],"models":[{"name":"m","force":true,"chat_interface":"zzz"}]}'
    [ "$output" = '$.models[0].chat_interface unresolved_chat_interface' ]
    run problems '{"schema_version":1,"components":[{"type":"engine","name":"eng"}],"models":[{"name":"","force":"yes"}]}'
    [[ "$output" == *'$.models[0].name wrong_type'* && "$output" == *'$.models[0].force wrong_type'* ]]
}

@test "codes: a configuration with several chat interfaces and no default is ambiguous" {
    make_fake chat-interface chat2 '["proxy"]'
    run problems '{"schema_version":1,"components":[{"type":"proxy","name":"prox"},{"type":"engine","name":"eng"},{"type":"chat-interface","name":"chat"},{"type":"chat-interface","name":"chat2"}],"models":[{"name":"m","force":true}]}'
    [ "$output" = '$.models[0].chat_interface ambiguous_chat_interface' ]
}

@test "codes: a platform the component does not support, only for this machine" {
    export EASY_CS_AI_HOST_IDS="fedora rhel"
    echo '{"schema_version":1,"components":[{"type":"engine","name":"eng"}]}' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0] | "\(.path) \(.code)"' <<<"$output")" = '$.components[0].name unsupported_platform' ]
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
    printf '%s' '{"schema_version":1,"bogus":1,"components":[{"type":"engine","name":"eng","options":{"port":0,"colour":1}}]}' >"$CFG"
    cli config validate "$CFG" --json
    [ "$(jq '.errors | length' <<<"$output")" = 3 ]
    cli config validate "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *'$.bogus: unknown key'*'$.components[0].options.port: an integer between 1 and 65535 is expected'* ]]
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
    [ "$(jq -r .plan.prune <<<"$output")" = "true" ]
    ! installed eng
}

@test "apply --dry-run --json: an invalid file is exit 2, a requirement nothing satisfies keeps exit 4" {
    printf '%s' '{"schema_version":1,"bogus":1}' >"$CFG"
    cli apply "$CFG" --dry-run --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0].code' <<<"$output")" = unknown_key ]
    printf '%s' '{"schema_version":1,"components":[{"type":"chat-interface","name":"chat"}]}' >"$CFG"
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
    [[ "$stderr" == *"plan: install"*"[WARN] chat --open=true: it is open"* ]]
}

# --- config schema -------------------------------------------------------------------------

@test "config schema is one JSON Schema, generated from the catalog" {
    cli config schema
    [ "$status" -eq 0 ]
    one_document
    run jq -r '."$schema"' <<<"$output"
    [[ "$output" == *"2020-12"* ]]
    cli config schema
    [ "$(jq -r '.properties.schema_version.maximum' <<<"$output")" = 1 ]
    [ "$(jq -c '.properties.components.items.oneOf | map(.properties.name.const)' <<<"$output")" = '["fit","prox","eng2","eng","chat"]' ]
    [ "$(jq -c '.properties.models.items.properties.engine.enum' <<<"$output")" = '["eng2","eng"]' ]
    [ "$(jq -c '.properties.models.items.properties.chat_interface.enum' <<<"$output")" = '["chat",null]' ]
}

@test "config schema: options are typed from describe, secrets are sources, warnings are in the description" {
    cli config schema
    opts='.properties.components.items.oneOf[] | select(.properties.name.const == "eng") | .properties.options.properties'
    [ "$(jq -c "$opts"'.port.anyOf[0] | [.type, .minimum, .maximum]' <<<"$output")" = '["integer",1,65535]' ]
    [ "$(jq -c "$opts"'.mode.enum' <<<"$output")" = '["a","b"]' ]
    [ "$(jq -c "$opts"'.open.anyOf | map(.type // .enum)' <<<"$output")" = '["boolean",["true","false"]]' ]
    [ "$(jq -r "$opts"'."api-key".oneOf | map(.required[0]) | join(",")' <<<"$output")" = "file,env,generate" ]
    [[ "$(jq -r "$opts"'.open.description' <<<"$output")" == *"WARNING: it is open"* ]]
    [ "$(jq -r "$opts"'.label.type | join(",")' <<<"$output")" = "string,number,boolean" ]
    [ "$(jq -r '.properties.components.items.oneOf[] | select(.properties.name.const == "chat") | .description' <<<"$output")" = "chat-interface chat, rank 1, requires proxy" ]
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
    jq '.components[1].options = {"port": 11500} | .components += [{"type": "provisioning", "name": "fit"}] | del(.models[0].force)' "$CFG" >"$CFG.2"
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
    jq 'del(.models[0].force)' "$CFG" >"$CFG.2"
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
{ "schema_version": 1, "components": [
  { "type": "provisioning", "name": "llmfit" },
  { "type": "proxy", "name": "nginx", "options": { "server-name": "ai.example.org", "port": 443 } },
  { "type": "engine", "name": "ollama", "default": true },
  { "type": "chat-interface", "name": "librechat", "options": { "allow-registration": false } } ],
  "models": [ { "name": "llama3.2:3b" } ] }
JSON
    cli config validate "$CFG" --json --target fresh
    [ "$status" -eq 0 ]
    [ "$(jq -c '.warnings' <<<"$output")" = "[]" ]
    jq 'del(.components[3].options)' "$CFG" >"$CFG.2"
    cli config validate "$CFG.2" --json --target fresh
    [ "$(jq -r '.warnings[0].option' <<<"$output")" = "allow-registration" ]
    jq '.components[1].options.tls = "selfsigned" | .components[2].options.port = 70000 | .components[3].options["allow-registration"] = "nope"' "$CFG" >"$CFG.3"
    cli config validate "$CFG.3" --json --target fresh
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors | map(.code) | join(",")' <<<"$output")" = "invalid_value,invalid_value,invalid_value" ]
}

@test "config schema of the shipped scripts is a valid JSON Schema document with the shipped components" {
    export EASY_CS_AI_HOME="$REAL"
    cli config schema
    [ "$status" -eq 0 ]
    [ "$(jq -c '.properties.components.items.oneOf | map(.properties.name.const)' <<<"$output")" = '["llmfit","nginx","ollama","librechat"]' ]
    [ "$(jq -c '.properties.components.items.oneOf[] | select(.properties.name.const == "nginx") | .properties.options.properties.tls.enum' <<<"$output")" = '["self-signed","provided","letsencrypt"]' ]
}
