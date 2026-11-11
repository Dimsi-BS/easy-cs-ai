#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The configuration format of version 2 (docs/spec-config.md): the VMs and their components, the models
# held by their engine, the links, the references, the slices, what a model needs, and the errors and
# warnings that need the whole file (docs/spec-multi-vm.md#validation). Fake components shipped: engine
# eng, eng2 and prot (protected); proxy prox (options tls, server-name); chat-interface chat and chat2
# (require a proxy); provisioning fit.

setup() {
    CLI="${BATS_TEST_DIRNAME}/../../package/bin/easy-cs-ai"
    REAL="${BATS_TEST_DIRNAME}/../../install_scripts"
    export EASY_CS_AI_HOME="$BATS_TEST_TMPDIR/home"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    unset EASY_CS_AI_LOCK_HELD
    mkdir -p "$EASY_CS_AI_HOME"/{engine,proxy,chat-interface,provisioning}
    ln -s "$REAL/lib" "$EASY_CS_AI_HOME/lib"
    printf 'engine eng\nproxy prox\nchat-interface chat\nprovisioning fit\n' >"$EASY_CS_AI_HOME/ranks.conf"
    make_fake engine eng '[]' '{}'
    make_fake engine eng2 '[]' '{}'
    make_fake engine prot '[]' '{"endpoint": {"protected": true}}'
    make_fake proxy prox '[]' '{"actions": ["install", "status", "show-key", "list-upstreams"]}'
    make_fake chat-interface chat '["proxy"]' '{"action_options": {"add-endpoint": [{"name": "model"}, {"name": "api-key-file"}, {"name": "ca-file"}]}}'
    make_fake chat-interface chat2 '["proxy"]' '{}'
    make_fake provisioning fit '[]' '{}'
    CFG="$BATS_TEST_TMPDIR/cfg.json"
}

# make_fake <type> <name> <requires-json> <extra-describe-json>
make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
source "\$EASY_CS_AI_LIB/common.sh"
action="\$1"; shift
case "\$action" in
describe) jq -n '{name: "$2", type: "$1", requires: $3,
    options: [{name: "port", secret: false}, {name: "tls", secret: false, type: "enum", values: ["self-signed","letsencrypt","provided"], default: "self-signed"}, {name: "server-name", secret: false}]} + $4' ;;
install) state_write $2 '{"name":"$2","type":"$1"}' ;;
uninstall) state_remove $2 ;;
add-model) : ;;
esac
exit 0
FAKE
}

cli() { run --separate-stderr bash "$CLI" "$@"; }
validate() { cli config validate "$CFG" --target fresh --json "$@"; }
codes() { jq -r '[.errors[].code] | sort | join(",")' <<<"$output"; }
paths() { jq -r '[.errors[] | "\(.code)@\(.path)"] | sort | join(" ")' <<<"$output"; }
wcodes() { jq -r '[.warnings[].code] | sort | join(",")' <<<"$output"; }

# two_vms [<models-json>]: engine VM "engine" (proxy, engine eng named eng, fit, one model), web VM "web"
# (proxy, chat named chat), the model linked to the chat interface.
two_vms() {
    local models='[ { "model": "m1", "name": "m1", "force": true } ]'
    (($# == 0)) || models="$1"
    cat >"$CFG" <<JSON
{
  "schema_version": 2,
  "vms": [
    { "name": "engine", "components": [
        { "component": "proxy/prox" },
        { "component": "engine/eng", "name": "eng", "models": $models },
        { "component": "provisioning/fit" } ] },
    { "name": "web", "components": [
        { "component": "proxy/prox" },
        { "component": "chat-interface/chat", "name": "chat" } ] }
  ],
  "links": [ { "model": { "vm_ref": "engine", "component_ref": "eng", "model_ref": "m1" },
               "chat_interface": { "vm_ref": "web", "component_ref": "chat" } } ]
}
JSON
}

# --- the file is a list of VMs -------------------------------------------------------------------

@test "a file with two VMs is valid and its plan is one slice per VM, in the order of the file" {
    two_vms
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.vms | map(.name)' <<<"$output")" = '["engine","web"]' ]
    [ "$(jq -c '.plan.vms[0].components | map(.component)' <<<"$output")" = '["proxy/prox","engine/eng","provisioning/fit"]' ]
}

@test "the name of a VM: optional for a lone VM with no link, required with several VMs or when a link designates it" {
    printf '%s' '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"}]}]}' >"$CFG"
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.vms | map(.name)' <<<"$output")" = '[null]' ]
    [ "$(jq -c '.warnings | map(.vm_ref)' <<<"$output")" = '[]' ]
    two_vms
    jq 'del(.vms[0].name)' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(codes)" = "missing_vm_name,unknown_vm" ]
}

@test "the same component on two VMs is valid, twice on one VM is duplicate_component whatever the names" {
    two_vms
    validate
    [ "$status" -eq 0 ]
    jq '.vms[0].components += [{"component":"proxy/prox","name":"second"}]' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'duplicate_component@$.vms[0].components[3]' ]
}

@test "several_defaults is judged per VM" {
    two_vms
    jq '.vms[0].components[1].default = true | .vms[1].components[1].default = true' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
    jq '.vms[0].components += [{"component":"engine/eng2","default":true}]' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(codes)" = several_defaults ]
}

@test "a requirement is satisfied by a component of the same VM only" {
    two_vms
    jq 'del(.vms[1].components[0])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'missing_requirement@$.vms[1].components[0]' ]
}

# --- the models, held by their engine -----------------------------------------------------------------

@test "a model is in its engine: the place is the engine, its VM and its component, in the plan" {
    two_vms
    validate
    [ "$(jq -c '.plan.vms[0].models' <<<"$output")" = '[{"model":"m1","name":"m1","engine":{"vm_ref":"engine","component_ref":"eng","component":"engine/eng"},"force":true}]' ]
    [ "$(jq -c '.plan.vms[1].models' <<<"$output")" = '[]' ]
}

@test "the same model in two engines is two instances, twice in one engine is duplicate_model" {
    two_vms
    jq '.vms[0].components += [{"component":"engine/eng2","name":"eng2","models":[{"model":"m1","name":"m1","force":true}]}]' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
    jq '.vms[0].components[1].models += [{"model":"m1","name":"other","force":true}]' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'duplicate_model@$.vms[0].components[1].models[1].model' ]
}

@test "an instance with no name is valid and cannot be linked" {
    two_vms
    jq 'del(.vms[0].components[1].models[0].name)' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'unresolved_model@$.links[0].model.model_ref' ]
    [[ "$(jq -r '.errors[0].message' <<<"$output")" == *"has no name written"* ]]
    jq 'del(.links)' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

@test "a model name is any string without control characters: slashes and colons are fine" {
    two_vms '[{"model":"library/llama3:8b","name":"library/llama3:8b","force":true}]'
    jq '.links[0].model.model_ref = "library/llama3:8b"' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

# --- what a model needs -------------------------------------------------------------------------------

@test "a model needs a proxy and, without force, a provisioning component, in its own VM" {
    two_vms '[{"model":"m1","name":"m1"}]'
    validate
    [ "$status" -eq 0 ]
    jq 'del(.vms[0].components[2])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'missing_requirement@$.vms[0].components[1].models[0]' ]
    [[ "$(jq -r '.errors[0].message' <<<"$output")" == *"provisioning component"* ]]
    jq 'del(.vms[0].components[0])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq '[.errors[] | select(.code == "missing_requirement")] | length' <<<"$output")" -eq 2 ]
}

@test "a provisioning component is not needed with force, a protected engine needs no proxy" {
    two_vms
    jq 'del(.vms[0].components[2])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
    [ "$(wcodes)" = "engine_address_unknown,models_not_checked" ]
    jq '.vms[0].components = [{"component":"engine/prot","name":"prot","models":[{"model":"m1","name":"m1","force":true}]}] | del(.links)' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

@test "what a model needs is read from its own VM: a proxy on another VM does not count" {
    two_vms
    jq 'del(.vms[0].components[0])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'missing_requirement@$.vms[0].components[0].models[0]' ]
}

@test "an engine VM with no model and no proxy is valid: the proxy is required by a model, not by an engine" {
    two_vms '[]'
    jq 'del(.vms[0].components[0]) | del(.links)' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

@test "with --target this, what is installed satisfies what a model needs" {
    two_vms '[{"model":"m1","name":"m1"}]'
    jq 'del(.vms[0].components[2]) | del(.vms[0].components[0])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    cli config validate "$CFG" --vm engine --json
    [ "$status" -eq 2 ]
    bash "$CLI" install proxy prox
    bash "$CLI" install provisioning fit
    cli config validate "$CFG" --vm engine --json
    [ "$status" -eq 0 ]
}

@test "apply --dry-run --json keeps exit 4 when what a model needs is the only error" {
    two_vms '[{"model":"m1","name":"m1"}]'
    jq 'del(.vms[0].components[2])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    cli apply "$CFG" --vm engine --dry-run --json
    [ "$status" -eq 4 ]
    [ "$(codes)" = missing_requirement ]
}

# --- links and references --------------------------------------------------------------------------------

@test "a link is complete: every field of a reference is written, also with one VM" {
    printf '%s' '{"schema_version":2,"vms":[{"name":"vm-1","components":[{"component":"proxy/prox"},{"component":"engine/eng","name":"eng","models":[{"model":"m","name":"m","force":true}]},{"component":"chat-interface/chat","name":"chat"}]}],"links":[{"model":{"vm_ref":"vm-1","component_ref":"eng"},"chat_interface":{"component_ref":"chat"}}]}' >"$CFG"
    validate
    [ "$(paths)" = 'missing_key@$.links[0].chat_interface missing_key@$.links[0].model' ]
}

@test "nothing is resolved by default: a component added on another VM, a second chat interface or a VM changes no link" {
    two_vms
    validate
    before="$(jq -c '.plan.links' <<<"$output")"
    jq '.vms[1].components += [{"component":"chat-interface/chat2","name":"chat2","default":true}] | .vms[0].components += [{"component":"engine/eng2","name":"eng2","default":true}]' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.links' <<<"$output")" = "$before" ]
    jq '.vms += [{"name":"spare","components":[{"component":"proxy/prox"},{"component":"chat-interface/chat","name":"chat"}]}]' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq -c '.plan.links' <<<"$output")" = "$before" ]
}

@test "a link with a component of the wrong type: unresolved, and the message says so" {
    two_vms
    jq '.links[0].chat_interface.component_ref = "eng" | .links[0].chat_interface.vm_ref = "engine"' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'unresolved_chat_interface@$.links[0].chat_interface.component_ref' ]
    [[ "$(jq -r '.errors[0].message' <<<"$output")" == *"another type of component"* ]]
}

@test "a link of a protected engine to another VM is refused, to the same VM accepted" {
    two_vms
    jq '.vms[0].components[1] = {"component":"engine/prot","name":"eng","models":[{"model":"m1","name":"m1","force":true}]}' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'protected_engine_other_vm@$.links[0]' ]
    jq '.vms[0].components += [{"component":"chat-interface/chat","name":"chat"}] | .links[0].chat_interface.vm_ref = "engine"' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

@test "a link to a VM that has no proxy in front of an engine that is not protected is the missing requirement of the model" {
    two_vms
    jq 'del(.vms[0].components[0])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(paths)" = 'missing_requirement@$.vms[0].components[0].models[0]' ]
}

# --- slices ---------------------------------------------------------------------------------------------

@test "validate --vm plans one slice: its models with their engine, and no link that leaves the VM" {
    two_vms
    cli config validate "$CFG" --vm engine --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.vms | map(.name)' <<<"$output")" = '["engine"]' ]
    [ "$(jq -c '.plan.vms[0].models | map(.model)' <<<"$output")" = '["m1"]' ]
    [ "$(jq -c '.plan.links' <<<"$output")" = '[]' ]
    cli config validate "$CFG" --vm web --json
    [ "$(jq -c '.plan.vms[0].components | map(.component)' <<<"$output")" = '["proxy/prox","chat-interface/chat"]' ]
}

@test "a link whose two ends are on the VM stays in its slice, as written" {
    printf '%s' '{"schema_version":2,"vms":[{"name":"a","components":[{"component":"proxy/prox"},{"component":"engine/eng","name":"eng","models":[{"model":"m","name":"m","force":true}]},{"component":"chat-interface/chat","name":"chat"}]},{"name":"b","components":[{"component":"proxy/prox"}]}],"links":[{"model":{"vm_ref":"a","component_ref":"eng","model_ref":"m"},"chat_interface":{"vm_ref":"a","component_ref":"chat"}}]}' >"$CFG"
    cli config validate "$CFG" --vm a --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.links | map([.model.vm_ref, .model.component_ref, .model.model_ref, .chat_interface.vm_ref, .chat_interface.component_ref])' <<<"$output")" = '[["a","eng","m","a","chat"]]' ]
}

@test "a slice is validated as a file of one VM: the errors of the other VMs are not given" {
    two_vms
    jq '.vms[1].components[1].options = {"bogus": 1}' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    cli config validate "$CFG" --vm engine --json
    [ "$status" -eq 0 ]
    cli config validate "$CFG" --vm web --json
    [ "$status" -eq 2 ]
    [ "$(codes)" = unknown_option ]
}

@test "config validate --target this needs --vm on a file of several VMs, and an unknown name is exit 2" {
    two_vms
    cli config validate "$CFG" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    cli config validate "$CFG" --vm zzz --json
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"the file names: engine, web"* ]]
    printf '%s' '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"}]}]}' >"$CFG"
    cli config validate "$CFG" --json
    [ "$status" -eq 0 ]
}

@test "apply --vm applies one slice, models included, and refuses a file of several VMs without it" {
    two_vms
    cli apply "$CFG"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"select one with --vm"* ]]
    cli apply "$CFG" --vm engine --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: install proxy prox"* && "$stderr" == *"plan: add m1 to eng (chat interface: null)"* ]]
    [[ "$stderr" != *"chat-interface chat"* ]]
}

# --- the steps, and the errors and warnings that need the whole file ----------------------------------------

@test "a link to another VM gives step 1, then the steps of the engine VM and of the pair" {
    two_vms
    validate
    [ "$(jq -r '.next_steps | length' <<<"$output")" -eq 4 ]
    [ "$(jq -r '.next_steps[0]' <<<"$output")" = "Run each script as root on its VM, the engine VMs first." ]
    [[ "$(jq -r '.next_steps[1]' <<<"$output")" == "On the engine VM engine, read"*"show-key"*"list-upstreams"*"status"* ]]
    [[ "$(jq -r '.next_steps[2]' <<<"$output")" == "Let the VM web reach the VM engine"* ]]
    [[ "$(jq -r '.next_steps[3]' <<<"$output")" == "On the VM web, link each model of the VM engine:"*"add-endpoint engine-eng-m1 <url>"*"--model m1"* ]]
}

@test "one add-endpoint per linked model, and a model with no link gives none" {
    two_vms '[{"model":"m1","name":"m1","force":true},{"model":"Q:7b","name":"Q:7b","force":true},{"model":"free","name":"free","force":true}]'
    jq '.links += [{"model":{"vm_ref":"engine","component_ref":"eng","model_ref":"Q:7b"},"chat_interface":{"vm_ref":"web","component_ref":"chat"}}]' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    step="$(jq -r '.next_steps[3]' <<<"$output")"
    [[ "$step" == *"add-endpoint engine-eng-m1 "* && "$step" == *"add-endpoint engine-eng-q-7b "* ]]
    [[ "$step" != *"free"* ]]
}

@test "a file whose links stay on their VM, or with none, has step 1 alone, in its second wording" {
    two_vms
    jq 'del(.links)' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq -c '.next_steps' <<<"$output")" = '["Run each script as root on its VM."]' ]
}

@test "the steps name only actions and options the describe of the scripts declares, else step 1 alone" {
    make_fake proxy prox '[]' '{"actions": ["install"]}'
    two_vms
    validate
    [ "$(jq -c '.next_steps' <<<"$output")" = '["Run each script as root on its VM."]' ]
}

@test "duplicate_server_name: two VMs writing the same server-name, also with a different case, at the path of the second" {
    two_vms
    jq '.vms[0].components[0].options = {"server-name": "A.example.org"} | .vms[1].components[0].options = {"server-name": "a.example.org"}' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'duplicate_server_name@$.vms[1].components[0].options.server-name' ]
    [ "$(jq -r '.errors[0].vm_ref' <<<"$output")" = web ]
    # a default name is never compared, different names are fine, a validation of one slice gives none
    jq '.vms[1].components[0].options = {"server-name": "b.example.org"}' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$status" -eq 0 ]
    jq '.vms[1].components[0].options = {"server-name": "a.example.org"}' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    cli config validate "$CFG" --vm web --json
    [ "$status" -eq 0 ]
}

@test "engine_address_unknown: a self-signed proxy with no server-name on the engine VM of a steps link, once" {
    two_vms
    validate
    [ "$status" -eq 0 ]
    [ "$(wcodes)" = "engine_address_unknown,models_not_checked" ] || [ "$(wcodes)" = engine_address_unknown ]
    [ "$(jq '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '[.warnings[] | select(.code == "engine_address_unknown")][0].vm_ref' <<<"$output")" = engine ]
}

@test "engine_address_unknown is not given with a server-name written, tls provided, no steps link, or a model on its own VM" {
    two_vms
    jq '.vms[0].components[0].options = {"server-name": "x"}' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" -eq 0 ]
    two_vms
    jq '.vms[0].components[0].options = {"tls": "provided"}' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" -eq 0 ]
    two_vms
    jq 'del(.links)' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" -eq 0 ]
    two_vms
    jq '.vms[0].components += [{"component":"chat-interface/chat","name":"chat"}] | .links[0].chat_interface.vm_ref = "engine"' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" -eq 0 ]
}

@test "models_not_checked: a model with force and no provisioning component on its VM" {
    two_vms
    jq 'del(.vms[0].components[2])' "$CFG" >"$CFG.t" && mv "$CFG.t" "$CFG"
    validate
    [ "$(jq -r '[.warnings[] | select(.code == "models_not_checked") | .vm_ref] | join(",")' <<<"$output")" = engine ]
}

@test "config schema lists the links with every field of a reference required" {
    cli config schema
    [ "$(jq -c '.properties.links.items.properties.model.required, .properties.links.items.properties.chat_interface.required' <<<"$output" | paste -sd' ')" = '["vm_ref","component_ref","model_ref"] ["vm_ref","component_ref"]' ]
}
