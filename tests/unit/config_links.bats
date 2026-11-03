#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The `links` field of the configuration (docs/spec-config.md#links), and the errors and warnings
# that need the whole file (docs/spec-multi-vm.md#validation): engine_unreachable,
# duplicate_server_name, engine_address_unknown. Fake components shipped: engine eng, eng2 and prot
# (protected); proxy prox (options tls, server-name); chat-interface chat (requires proxy).

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
esac
exit 0
FAKE
}

cli() { run --separate-stderr bash "$CLI" "$@"; }
validate() { cli config validate "$CFG" --target fresh --json "$@"; }
codes() { jq -r '[.errors[].code] | sort | join(",")' <<<"$output"; }
paths() { jq -r '[.errors[] | "\(.code)@\(.path)"] | sort | join(" ")' <<<"$output"; }
wcodes() { jq -r '[.warnings[].code] | sort | join(",")' <<<"$output"; }

# two_vms [<models-json>]: engine VM (prox, eng, a model by default), web VM (chat), linked web -> engine.
two_vms() {
    local models='[ { "name": "m1", "vm": "engine", "engine": "eng", "force": true } ]'
    (($# == 0)) || models="$1"
    cat >"$CFG" <<JSON
{
  "schema_version": 1,
  "components": [
    { "type": "proxy", "name": "prox", "vm": "engine" },
    { "type": "engine", "name": "eng", "vm": "engine", "default": true },
    { "type": "proxy", "name": "prox", "vm": "web" },
    { "type": "chat-interface", "name": "chat", "vm": "web" },
    { "type": "provisioning", "name": "fit", "vm": "engine" }
  ],
  "models": $models,
  "links": [ { "web_vm": "web", "engine_vm": "engine" } ]
}
JSON
}

# --- schema and shape -------------------------------------------------------------------------

@test "config schema lists links, web_vm and engine_vm required" {
    cli config schema
    [ "$status" -eq 0 ]
    [ "$(jq -r '.properties.links.items.required | sort | join(",")' <<<"$output")" = "engine_vm,web_vm" ]
}

@test "links is an array of objects, wrong_type and unknown_key" {
    two_vms
    jq '.links = "nope"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(paths)" = 'wrong_type@$.links' ]
    two_vms
    jq '.links[0] = 3' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [[ "$(paths)" == *'wrong_type@$.links[0]'* ]]
    two_vms
    jq '.links[0].extra = 1' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [[ "$(paths)" == *'unknown_key@$.links[0].extra'* ]]
}

@test "unknown_vm: a link naming a VM no component has, also in a file that names no VM" {
    two_vms
    jq '.links[0].engine_vm = "ghost"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'unknown_vm@$.links[0].engine_vm'* ]]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" }, { "type": "proxy", "name": "prox" } ],
  "links": [ { "web_vm": "a", "engine_vm": "b" } ] }
JSON
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'unknown_vm@$.links[0]'* ]]
}

@test "link_to_self: a VM cannot link its own engine" {
    two_vms
    jq '.links[0].web_vm = "engine"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'link_to_self@$.links[0]'* ]]
}

@test "link_without_chat_interface: web_vm has no chat interface" {
    two_vms
    jq '.components += [ { "type": "engine", "name": "eng2", "vm": "c" }, { "type": "proxy", "name": "prox", "vm": "c" } ]
      | .links += [ { "web_vm": "engine", "engine_vm": "c" } ]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = link_without_chat_interface ]
    [[ "$(paths)" == 'link_without_chat_interface@$.links[1].web_vm' ]]
}

@test "link_without_engine: engine_vm has no engine" {
    two_vms
    jq '.components += [ { "type": "chat-interface", "name": "chat", "vm": "c" }, { "type": "proxy", "name": "prox", "vm": "c" } ]
      | .links += [ { "web_vm": "c", "engine_vm": "web" } ]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = link_without_engine ]
    [[ "$(paths)" == 'link_without_engine@$.links[1].engine_vm' ]]
}

@test "link_protected_engine: the engine_vm holds a protected engine" {
    two_vms '[]'
    jq '(.components[] | select(.name == "eng") | .name) = "prot"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'link_protected_engine@$.links[0]'* ]]
}

@test "duplicate_link: the same pair twice" {
    two_vms
    jq '.links += [ { "web_vm": "web", "engine_vm": "engine" } ]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'duplicate_link@$.links[1]'* ]]
}

@test "link_cycle: two VMs pointing at each other, a cycle of three, a chain stays valid" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1,
  "components": [
    { "type": "engine", "name": "eng", "vm": "a" }, { "type": "chat-interface", "name": "chat", "vm": "a" }, { "type": "proxy", "name": "prox", "vm": "a" },
    { "type": "engine", "name": "eng2", "vm": "b" }, { "type": "chat-interface", "name": "chat", "vm": "b" }, { "type": "proxy", "name": "prox", "vm": "b" }
  ],
  "links": [ { "web_vm": "a", "engine_vm": "b" }, { "web_vm": "b", "engine_vm": "a" } ] }
JSON
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'link_cycle@$.links[1]'* ]]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1,
  "components": [
    { "type": "engine", "name": "eng", "vm": "a" }, { "type": "chat-interface", "name": "chat", "vm": "a" }, { "type": "proxy", "name": "prox", "vm": "a" },
    { "type": "engine", "name": "eng2", "vm": "b" }, { "type": "chat-interface", "name": "chat", "vm": "b" }, { "type": "proxy", "name": "prox", "vm": "b" },
    { "type": "engine", "name": "eng", "vm": "c" }, { "type": "chat-interface", "name": "chat", "vm": "c" }, { "type": "proxy", "name": "prox", "vm": "c" }
  ],
  "links": [ { "web_vm": "a", "engine_vm": "b" }, { "web_vm": "b", "engine_vm": "c" }, { "web_vm": "c", "engine_vm": "a" } ] }
JSON
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'link_cycle@$.links[2]'* ]]
    # a to b, b to c: a chain, not a cycle, stays valid
    jq '.links = [ { "web_vm": "a", "engine_vm": "b" }, { "web_vm": "b", "engine_vm": "c" } ]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

@test "unlinked_vm: a VM in no link, with several VMs; none with one VM only" {
    two_vms
    jq '.components += [ { "type": "engine", "name": "eng2", "vm": "extra" } ] | .links = []' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = "unlinked_vm,unlinked_vm,unlinked_vm" ]
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng", "vm": "a" } ] }
JSON
    validate
    [ "$status" -eq 0 ]
}

@test "a valid link whose engine VM has no model yet" {
    two_vms '[]'
    validate
    [ "$status" -eq 0 ]
    [ "$(jq -c '.plan.links' <<<"$output")" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
}

@test "a link to an engine VM with no proxy: missing_requirement with a model, engine_unreachable without" {
    two_vms
    jq 'del(.components[0])' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = missing_requirement ]
    two_vms '[]'
    jq 'del(.components[0])' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = engine_unreachable ]
}

@test "no slice carries links, and a validation of one slice gives none of the link codes" {
    two_vms
    jq '.links[0].web_vm = "ghost"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    run --separate-stderr bash "$CLI" config validate "$CFG" --target fresh --vm engine --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.plan.vms[0].components | map(.name) | join(",")' <<<"$output")" = "prox,eng,fit" ]
}

@test "a file with no links: with several VMs, unlinked_vm for each VM" {
    two_vms
    jq 'del(.links)' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [ "$(codes)" = "unlinked_vm,unlinked_vm" ]
}

@test "a file that names one VM only needs no link" {
    cat >"$CFG" <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng", "vm": "a" }, { "type": "provisioning", "name": "fit", "vm": "a" } ] }
JSON
    validate
    [ "$status" -eq 0 ]
}

@test "an older reader refuses links with unknown_key: not a schema_version bump" {
    two_vms
    [ "$(jq '.schema_version' "$CFG")" = 1 ]
}

@test "an engine VM that no link targets needs no proxy, even with several VMs" {
    two_vms '[]'
    # eng2 is on the web VM, which is linked (as web_vm), but no link targets eng2 itself
    jq '.components += [ { "type": "engine", "name": "eng2", "vm": "web" } ]' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

# --- duplicate_server_name ---------------------------------------------------------------------

@test "duplicate_server_name: two VMs writing the same server-name, also with a different case" {
    two_vms '[]'
    jq '.components[0].options = {"server-name": "llm.example.org"} | .components[2].options = {"server-name": "LLM.example.org"}' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [[ "$(paths)" == *'duplicate_server_name@$.components[2].options.server-name'* ]]
    [ "$(jq -r '.errors[0].vm' <<<"$output")" = web ]
}

@test "duplicate_server_name: a default name is never compared, different names are fine" {
    two_vms '[]'
    validate
    [ "$status" -eq 0 ]
    jq '.components[0].options = {"server-name": "a.example.org"} | .components[2].options = {"server-name": "b.example.org"}' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 0 ]
}

@test "duplicate_server_name is not given by a validation of one slice" {
    two_vms '[]'
    jq '.components[0].options = {"server-name": "x"} | .components[2].options = {"server-name": "x"}' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    run --separate-stderr bash "$CLI" config validate "$CFG" --target fresh --vm engine --json
    [ "$status" -eq 0 ]
}

# --- engine_address_unknown ----------------------------------------------------------------------

@test "engine_address_unknown: a self-signed proxy with no server-name, a model, one linked chat-interface VM" {
    two_vms
    validate
    [ "$status" -eq 0 ]
    [ "$(wcodes)" = engine_address_unknown ]
    [ "$(jq -r '.warnings[0].vm' <<<"$output")" = engine ]
}

@test "engine_address_unknown is not given with a server-name written, tls provided or letsencrypt, no model, a protected engine, or an unreached VM" {
    two_vms
    jq '.components[0].options = {"server-name": "x"}' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$(wcodes)" = "" ]
    two_vms
    jq '.components[0].options = {"tls": "provided"}' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$(wcodes)" = "" ]
    two_vms '[]'
    validate
    [ "$status" -eq 0 ]
    [ "$(wcodes)" = "" ]
    two_vms
    jq '(.components[] | select(.name == "eng") | .name) = "prot" | .models[0].engine = "prot"' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    validate
    [ "$status" -eq 2 ]
    [[ "$(codes)" == *link_protected_engine* ]]
}

@test "engine_address_unknown is shown once, the same in config validate and generate --config" {
    two_vms
    validate
    [ "$(jq '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" -eq 1 ]
}
