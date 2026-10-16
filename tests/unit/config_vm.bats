#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The `vm` field of the configuration, the place of a model and what a model
# needs, see docs/spec-config.md. Fake components shipped: engine eng, eng2 and
# prot (protected: it enforces HTTPS and a key itself); proxy prox;
# chat-interface chat (requires the type proxy); provisioning fit. Calls are
# logged in $CALLS.

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
    make_fake engine eng '[]' '{}'
    make_fake engine eng2 '[]' '{}'
    make_fake engine prot '[]' '{"endpoint": {"protected": true}}'
    make_fake proxy prox '[]' '{}'
    make_fake chat-interface chat '["proxy"]' '{}'
    make_fake provisioning fit '[]' '{}'
    : >"$CALLS"
    CFG="$BATS_TEST_TMPDIR/cfg.json"
}

# make_fake <type> <name> <requires-json> <extra-describe-json>
make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
source "\$EASY_CS_AI_LIB/common.sh"
action="\$1"; shift
echo "$2 \$action \$*" >>"\$CALLS"
case "\$action" in
describe) jq -n '{name: "$2", type: "$1", requires: $3, options: [{name: "port", secret: false}]} + $4' ;;
install)
    state_read $2 >/dev/null 2>&1 && m= || m=',"models":[]'
    state_write $2 '{"name":"$2","type":"$1","version":"1","requires":$3,"endpoint":{"url":"http://127.0.0.1:1","openai_base_url":"http://127.0.0.1:1/v1","protected":false}'"\$m"'}' ;;
uninstall) state_remove $2 ;;
check) echo '{"fits": true, "reason": ""}' ;;
add-model)
    state_write $2 "\$(state_read $2 | jq --arg m "\$1" '{name, type, models: ((.models // []) + [{name: \$m, exposed_via: null, linked_to: []}])}')" ;;
add-upstream) jq -n --arg u "https://host/\$1" '{url: \$u}' ;;
add-endpoint) jq -n --arg u "\$2" '{url: \$u}' ;;
esac
exit 0
FAKE
}

cli() { run --separate-stderr bash "$CLI" "$@"; }
installed() { [ -f "$STATE/$1.json" ]; }

# validate: config validate of $CFG for a fresh VM, the document in $output
validate() { cli config validate "$CFG" --target fresh --json "$@"; }
codes() { jq -r '[.errors[].code] | sort | join(",")' <<<"$output"; }
paths() { jq -r '[.errors[] | "\(.code)@\(.path)"] | sort | join(" ")' <<<"$output"; }

# two_vms: the engine VM holds fit, prox and eng; the web VM prox and chat. $1 is
# the models array (default none).
two_vms() {
    cat >"$CFG" <<JSON
{
  "schema_version": 1,
  "components": [
    { "type": "provisioning", "name": "fit", "vm": "engine" },
    { "type": "proxy", "name": "prox", "vm": "engine" },
    { "type": "engine", "name": "eng", "vm": "engine", "default": true },
    { "type": "proxy", "name": "prox", "vm": "web" },
    { "type": "chat-interface", "name": "chat", "vm": "web" }
  ],
  "models": ${1:-[]}
}
JSON
}

# --- the vm field ----------------------------------------------------------------------------

@test "a file with two VMs is valid and its plan is one slice per VM" {
    two_vms '[ { "name": "m1" } ]'
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ok' <<<"$output")" = true ]
    [ "$(jq -r '[.plan.vms[].vm] | join(",")' <<<"$output")" = "engine,web" ]
    [ "$(jq -r '.plan.vms[0].components | map(.name) | join(",")' <<<"$output")" = "fit,prox,eng" ]
    [ "$(jq -r '.plan.vms[1].components | map(.name) | join(",")' <<<"$output")" = "prox,chat" ]
}

@test "the shape of vm: a string of lowercase letters, digits and dashes" {
    two_vms
    jq '.components[0].vm = 3' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'wrong_type@$.components[0].vm' ]
    two_vms
    jq '.components[0].vm = "Engine"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'invalid_value@$.components[0].vm' ]
    two_vms
    jq '.components[0].vm = "1engine"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$(paths)" = 'invalid_value@$.components[0].vm' ]
}

@test "missing_vm: the first component without a vm when another has one" {
    two_vms
    jq 'del(.components[2].vm)' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'missing_vm@$.components[2]' ]
}

@test "the same component on two VMs is valid, twice on one VM is duplicate_component" {
    two_vms
    validate
    [ "$status" -eq 0 ]
    jq '.components += [{ "type": "proxy", "name": "prox", "vm": "web" }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = duplicate_component ]
    [ "$(jq -r '.errors[0].vm' <<<"$output")" = web ]
}

@test "several_defaults is judged per VM" {
    two_vms
    jq '.components += [{ "type": "engine", "name": "eng2", "vm": "web", "default": true }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
    jq '.components += [{ "type": "engine", "name": "eng2", "vm": "engine", "default": true }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = several_defaults ]
    [ "$(jq -r '.errors[0].vm' <<<"$output")" = engine ]
}

@test "a requirement is satisfied by a component of the same VM only" {
    two_vms
    jq 'del(.components[3])' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'missing_requirement@$.components[3]' ]
    [ "$(jq -r '.errors[0].vm' <<<"$output")" = web ]
}

# --- the place of a model --------------------------------------------------------------------

@test "place: vm and engine given" {
    two_vms '[ { "name": "m1", "vm": "engine", "engine": "eng" } ]'
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.vms[0].models' <<<"$output")" = '[{"name":"m1","vm":"engine","engine":"eng","chat_interface":null,"force":false}]' ]
}

@test "place: vm given, engine absent takes the only engine, else the default of that VM" {
    two_vms '[ { "name": "m1", "vm": "engine" } ]'
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.plan.vms[0].models[0].engine' <<<"$output")" = eng ]
    jq '.components += [{ "type": "engine", "name": "eng2", "vm": "engine" }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.plan.vms[0].models[0].engine' <<<"$output")" = eng ]
    jq '(.components[] | select(.name == "eng") | .default) = false' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'ambiguous_engine@$.models[0].engine' ]
}

@test "place: a VM with no engine is unresolved_engine" {
    two_vms '[ { "name": "m1", "vm": "web" } ]'
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'unresolved_engine@$.models[0].engine' ]
}

@test "place: engine given on another VM is engine_other_vm, on none is unresolved_engine" {
    two_vms '[ { "name": "m1", "vm": "web", "engine": "eng" } ]'
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'engine_other_vm@$.models[0].engine' ]
    two_vms '[ { "name": "m1", "vm": "engine", "engine": "nope" } ]'
    validate
    [ "$(paths)" = 'unresolved_engine@$.models[0].engine' ]
}

@test "place: vm absent, engine given finds the VM that has it, else ambiguous_engine" {
    two_vms '[ { "name": "m1", "engine": "eng" } ]'
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.plan.vms[0].models[0].vm' <<<"$output")" = engine ]
    jq '.components += [{ "type": "engine", "name": "eng", "vm": "web" }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'ambiguous_engine@$.models[0].engine' ]
}

@test "place: neither given is the only engine of the file, else ambiguous_engine even with a default" {
    two_vms '[ { "name": "m1" } ]'
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.plan.vms[0].models[0] | "\(.vm)/\(.engine)"' <<<"$output")" = engine/eng ]
    jq '.components += [{ "type": "engine", "name": "eng2", "vm": "web" }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'ambiguous_engine@$.models[0].engine' ]
    [[ "$(jq -r '.errors[0].message' <<<"$output")" == *engine/eng*web/eng2* ]]
}

@test "unknown_vm: a VM no component has, and a vm on a model of a file that names none" {
    two_vms '[ { "name": "m1", "vm": "ghost" } ]'
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'unknown_vm@$.models[0].vm' ]
    [[ "$(jq -r '.errors[0].message' <<<"$output")" == *engine*web* ]]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" }, { "type": "proxy", "name": "prox" }, { "type": "provisioning", "name": "fit" } ], "models": [ { "name": "m1", "vm": "a" } ] }
JSON
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'unknown_vm@$.models[0].vm' ]
}

@test "the same model on two places is valid, twice on one place is duplicate_model" {
    two_vms '[ { "name": "m1" } ]'
    jq '.components += [{ "type": "engine", "name": "eng2", "vm": "web" }, { "type": "proxy", "name": "prox", "vm": "x" }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    jq '.components += [{ "type": "provisioning", "name": "fit", "vm": "web" }]
        | .models = [ { "name": "m1", "vm": "engine" }, { "name": "m1", "vm": "web" } ]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    jq '.components |= map(select(.vm != "x"))' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
    jq '.models += [ { "name": "m1", "vm": "engine", "engine": "eng" } ]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'duplicate_model@$.models[2]' ]
}

@test "a model is linked to the chat interface of its own VM, else none" {
    two_vms '[ { "name": "m1" } ]'
    validate
    [ "$(jq -r '.plan.vms[0].models[0].chat_interface' <<<"$output")" = null ]
    jq '.components += [{ "type": "chat-interface", "name": "chat", "vm": "engine" }]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.plan.vms[0].models[0].chat_interface' <<<"$output")" = chat ]
}

@test "chat_interface_other_vm: an explicit chat interface that exists only on another VM" {
    two_vms '[ { "name": "m1", "chat_interface": "chat" } ]'
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'chat_interface_other_vm@$.models[0].chat_interface' ]
    two_vms '[ { "name": "m1", "chat_interface": "nope" } ]'
    validate
    [ "$(paths)" = 'unresolved_chat_interface@$.models[0].chat_interface' ]
}

# --- what a model needs ----------------------------------------------------------------------

@test "a model needs a proxy and a provisioning component in its own VM" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ], "models": [ { "name": "m1" } ] }
JSON
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'missing_requirement@$.models[0] missing_requirement@$.models[0]' ]
    [[ "$(jq -r '[.errors[].message] | join(" ")' <<<"$output")" == *"proxy prox"*"provisioning fit"* ]]
}

@test "a provisioning component is not needed with force, a protected engine needs no proxy" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" }, { "type": "proxy", "name": "prox" } ],
  "models": [ { "name": "m1", "force": true } ] }
JSON
    validate
    [ "$status" -eq 0 ]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "prot" }, { "type": "provisioning", "name": "fit" } ],
  "models": [ { "name": "m1" } ] }
JSON
    validate
    [ "$status" -eq 0 ]
}

@test "what a model needs is read from the slice: a proxy on another VM does not count" {
    two_vms '[ { "name": "m1" } ]'
    jq 'del(.components[1])' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'missing_requirement@$.models[0]' ]
    [ "$(jq -r '.errors[0].vm' <<<"$output")" = engine ]
}

@test "an engine VM with no model needs no proxy" {
    two_vms
    jq 'del(.components[1])' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

@test "with --target this, what is installed satisfies a model's needs" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ], "models": [ { "name": "m1" } ] }
JSON
    cli config validate "$CFG" --json
    [ "$status" -eq 2 ]
    bash "$CLI" install proxy prox
    bash "$CLI" install provisioning fit
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
}

@test "apply keeps exit 4 when what a model needs is the only error" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ], "models": [ { "name": "m1" } ] }
JSON
    cli apply "$CFG" --dry-run --json
    [ "$status" -eq 4 ]
    [ "$(codes)" = missing_requirement,missing_requirement ]
}

# --- --vm --------------------------------------------------------------------------------------

@test "config validate on a file with VMs needs --vm for this machine and fits --vm to the file" {
    two_vms
    cli config validate "$CFG" --json
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"select one with --vm"* ]]
    [ -z "$output" ]
    validate --vm ghost
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"engine, web"* ]]
    [ -z "$output" ]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ] }
JSON
    validate --vm a
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"names no VM"* ]]
}

@test "config validate --vm gives one slice, its errors and warnings only" {
    two_vms '[ { "name": "m1" } ]'
    jq 'del(.components[3])' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate --vm engine
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.plan.vms[].vm] | join(",")' <<<"$output")" = engine ]
    validate --vm web
    [ "$status" -eq 2 ]
    [ "$(codes)" = missing_requirement ]
    [ "$(jq -r '.plan' <<<"$output")" = null ]
}

@test "the plan of a file with no vm is unchanged" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" }, { "type": "proxy", "name": "prox" }, { "type": "provisioning", "name": "fit" } ],
  "models": [ { "name": "m1" } ] }
JSON
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.plan | keys | join(",")' <<<"$output")" = components,models,prune ]
}

@test "apply is refused without --vm on a file with VMs, with an unknown name, or --vm on a file with none" {
    two_vms
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"select one with --vm"* ]]
    cli apply "$CFG" --vm ghost
    [ "$status" -eq 2 ]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ] }
JSON
    cli apply "$CFG" --vm a
    [ "$status" -eq 2 ]
    run ! installed eng
}

@test "apply --vm applies one slice as a one-VM file, models included" {
    two_vms '[ { "name": "m1" } ]'
    cli apply "$CFG" --vm engine
    [ "$status" -eq 0 ]
    installed eng
    installed fit
    installed prox
    run ! installed chat
    grep -q "^eng add-model m1" "$CALLS"
    [[ "$stderr" == *"apply start components=3 models=1 prune=false vm=engine"* ]]
}

@test "apply --vm on the web slice installs its components only" {
    two_vms '[ { "name": "m1" } ]'
    cli apply "$CFG" --vm web
    [ "$status" -eq 0 ]
    installed chat
    installed prox
    run ! installed eng
    run ! installed fit
    run ! grep -q "add-model" "$CALLS"
}

@test "apply --vm --dry-run plans that slice alone" {
    two_vms '[ { "name": "m1" } ]'
    cli apply "$CFG" --vm engine --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: install engine eng"* ]]
    [[ "$stderr" != *"chat-interface"* ]]
    [ ! -s "$CALLS" ] || ! grep -q install "$CALLS"
}

@test "config schema lists vm on components and models" {
    cli config schema
    [ "$status" -eq 0 ]
    [ "$(jq -r '.properties.components.items.oneOf[0].properties.vm.type' <<<"$output")" = string ]
    [ "$(jq -r '.properties.models.items.properties.vm.type' <<<"$output")" = string ]
}
