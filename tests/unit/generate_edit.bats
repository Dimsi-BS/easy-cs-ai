#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The editor, `generate --edit <file>` (docs/spec-multi-vm.md#editing): opening an existing
# configuration in the session, the summary of the whole thing, and the a/e/m/l/n/r/f/y/q
# commands.
#
# Fake scripts shipped: proxy prox (tls, server-name, the actions next_steps needs), engine eng
# (option port), protected engine prot, chat-interface chat (requires proxy, add-endpoint opts).

SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    GEN="${BATS_TEST_DIRNAME}/../../vm_script/generate.sh"
    REAL="${BATS_TEST_DIRNAME}/../../install_scripts"
    export EASY_CS_AI_HOME="$BATS_TEST_TMPDIR/home"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    unset EASY_CS_AI_LOCK_HELD EASY_CS_AI_CLI_VERSION
    mkdir -p "$EASY_CS_AI_HOME"/{engine,proxy,chat-interface,provisioning}
    ln -s "$REAL/lib" "$EASY_CS_AI_HOME/lib"
    ln -s "$REAL/guide.txt" "$EASY_CS_AI_HOME/guide.txt"
    printf 'engine eng\nproxy prox\nchat-interface chat\n' >"$EASY_CS_AI_HOME/ranks.conf"
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false,"description":"certificate"},{"name":"server-name","default":"","secret":false,"description":"name"}]' \
        '{"actions":["install","status","show-key","list-upstreams"]}'
    make_fake engine eng '[]' '[{"name":"port","default":"11434","secret":false,"description":"Listening port"}]' '{}'
    make_fake engine prot '[]' '[]' '{"endpoint":{"protected":true}}'
    make_fake chat-interface chat '["proxy"]' '[]' '{"action_options":{"add-endpoint":[{"name":"model"},{"name":"api-key-file"},{"name":"ca-file"}]}}'
    cd "$BATS_TEST_TMPDIR"
    PKG=(--package-version 0.1.0 --package-sha256 "$SHA")
}

# make_fake <type> <name> <requires-json> <options-json> <extra-describe-json>
make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
jq -n '{name: "$2", type: "$1", component_version: "9.9", requires: $3, platforms: ["debian","ubuntu"], options: $4} + $5'
FAKE
}

gen() { run --separate-stderr bash "$GEN" "$@"; }
_join_lines() {
    local a
    REPLY_LINES=""
    for a in "$@"; do REPLY_LINES+="$a"$'\n'; done
}
# edit <file> <answers…>: open <file> in the editor with one answer per line on stdin.
edit() {
    local file="$1"
    shift
    _join_lines "$@"
    ANSWERS="$REPLY_LINES"
    export ANSWERS GEN_FILE="$file"
    run --separate-stderr bash -c 'bash "$0" --edit "$GEN_FILE" "${@:1}" <<<"$ANSWERS"' "$GEN" "${GEN_ARGS[@]}"
}
embedded() { sed -n "/<<'EASY_CS_AI_CONFIG'/,/^EASY_CS_AI_CONFIG\$/p" "$1" | sed '1d;$d'; }

two_vm_file() {
    cat >"$1" <<'JSON'
{
  "schema_version": 1,
  "components": [
    { "type": "proxy", "name": "prox", "vm": "engine" },
    { "type": "engine", "name": "eng", "vm": "engine" },
    { "type": "proxy", "name": "prox", "vm": "web" },
    { "type": "chat-interface", "name": "chat", "vm": "web" }
  ],
  "models": [ { "name": "m1", "force": true, "vm": "engine", "engine": "eng" } ],
  "links": [ { "web_vm": "web", "engine_vm": "engine" } ]
}
JSON
}

# --- usage -----------------------------------------------------------------------------------

@test "--edit is exclusive with --config and --config-only" {
    gen --edit f.json --config f.json
    [ "$status" -eq 2 ]
    gen --edit f.json --config-only
    [ "$status" -eq 2 ]
}

@test "--edit on a missing file, or a file that is not JSON, is exit 2" {
    gen --edit nope.json
    [ "$status" -eq 2 ]
    echo 'not json' >bad.json
    gen --edit bad.json
    [ "$status" -eq 2 ]
}

# --- opening and the summary -------------------------------------------------------------------

@test "opening a valid file shows its VMs, components, models and links" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"VM engine"* && "$stderr" == *"VM web"* ]]
    [[ "$stderr" == *"proxy prox"* && "$stderr" == *"engine eng"* && "$stderr" == *"chat-interface chat"* ]]
    [[ "$stderr" == *"models: m1"* ]]
    [[ "$stderr" == *"links: web -> engine"* ]]
    [[ "$stderr" == *"cancelled, nothing written"* ]]
    [ -z "$(ls f-*.sh 2>/dev/null)" ]
}

@test "opening a file with errors shows them, numbered, and q leaves it untouched" {
    two_vm_file f.json
    jq 'del(.links)' f.json >f.json.tmp && mv f.json.tmp f.json
    before="$(cat f.json)"
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"1. \$.components"*"unlinked_vm"* ]]
    [[ "$stderr" == *"2. \$.components"*"unlinked_vm"* ]]
    [ "$(cat f.json)" = "$before" ]
}

@test "y refuses while an error stands" {
    two_vm_file f.json
    jq 'del(.links)' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json y q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"nothing is written while an error stands"* ]]
    [ -z "$(ls f-*.sh 2>/dev/null)" ]
}

# --- y: write, atomically, regenerating the scripts --------------------------------------------

@test "y with no change writes the configuration back and regenerates the scripts" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json y
    [ "$status" -eq 0 ]
    [ -x f-engine.sh ] && [ -x f-web.sh ]
    [ "$(jq -S . f.json)" = "$(two_vm_file /dev/stdout | jq -S .)" ]
    [[ "$stderr" == *"Two scripts written, one per VM:"* ]]
    [[ "$stderr" == *"What is left to do once the VMs are up:"* ]]
}

@test "--dry-run writes nothing" {
    two_vm_file f.json
    before="$(cat f.json)"
    GEN_ARGS=("${PKG[@]}" --output f.sh --dry-run)
    edit f.json y
    [ "$status" -eq 0 ]
    [ "$(cat f.json)" = "$before" ]
    [ -z "$(ls f-*.sh 2>/dev/null)" ]
    [[ "$stderr" == *"dry run, would write f.json"* ]]
}


# --- n: rename ---------------------------------------------------------------------------------

@test "n <vm> renames it: components, models and links follow" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json "n engine" engine2 y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[].vm] | unique | sort | join(",")' f.json)" = "engine2,web" ]
    [ "$(jq -r '.models[0].vm' f.json)" = engine2 ]
    [ "$(jq -c '.links' f.json)" = '[{"web_vm":"web","engine_vm":"engine2"}]' ]
    [ -x f-engine2.sh ]
}

@test "n refuses a name of the wrong shape or already taken, and asks again" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json "n engine" Web web2 y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"is not lowercase letters"* ]]
    [ "$(jq -r '[.components[].vm] | unique | sort | join(",")' f.json)" = "web,web2" ]
    two_vm_file f.json
    edit f.json "n engine" web engine2 y
    [[ "$stderr" == *"is already the name of another VM"* ]]
    [ "$(jq -r '[.components[].vm] | unique | sort | join(",")' f.json)" = "engine2,web" ]
}

# --- r: remove -----------------------------------------------------------------------------------

@test "r <vm> removes it with its components, its models and the links naming it" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    # k: keep the vm field down to one VM (see the dedicated tests below for the default, drop)
    edit f.json "r web" y k y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[].vm] | unique | join(",")' f.json)" = engine ]
    [ "$(jq -c '.links' f.json)" = '[]' ]
    [ -x f-engine.sh ]
    [ ! -e f-web.sh ]
}

@test "removing down to one VM asks to keep its vm field or drop it; default drops it" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json "r web" y "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"One VM is left: keep its vm field (k), or drop it, a one-VM file (d) [d]:"* ]]
    [ "$(jq 'any(.components[]; has("vm"))' f.json)" = false ]
    [ "$(jq 'has("links")' f.json)" = false ]
    [ -x f.sh ]
    [ ! -e f-engine.sh ]
}

@test "removing down to one VM, k keeps the vm field (one name, no links)" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json "r web" y k y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.components[0].vm' f.json)" = engine ]
    [ "$(jq -c '.links' f.json)" = '[]' ]
    [ -x f-engine.sh ]
}

@test "the last VM cannot be removed" {
    cat >one.json <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng", "vm": "a" } ] }
JSON
    GEN_ARGS=("${PKG[@]}" --output one.sh)
    edit one.json "r a" q
    [[ "$stderr" == *"the last VM cannot be removed"* ]]
    [ "$(jq -r '.components[0].vm' one.json)" = a ]
}

@test "stale scripts are listed, not deleted, after a rename" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    gen --config f.json "${PKG[@]}" --output f.sh
    [ -x f-engine.sh ]
    edit f.json "n engine" engine2 y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"f-engine.sh"* ]]
    [ -e f-engine.sh ]
    [ -x f-engine2.sh ]
}

# --- l: redo the links ---------------------------------------------------------------------------

@test "l redoes the links, the current ones as the default" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json l "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"[engine]:"* ]]
    [ "$(jq -c '.links' f.json)" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
}

# --- m: redo the models only ---------------------------------------------------------------------

@test "m <vm> redoes its models only, keeping its components" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json "m engine" "m1, m2" y y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.models[].name] | join(",")' f.json)" = "m1,m2" ]
    [ "$(jq -r '[.components[] | select(.vm == "engine") | .type] | join(",")' f.json)" = "proxy,engine" ]
}

# --- e: cascade when a dependent (a model, a link) is removed with its component --------------

@test "e <vm> removing the engine announces its models; n leaves them (an error f then fixes)" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    before="$(cat f.json)"
    # VM engine: keep proxy, decline engine, decline chat-interface, its options, confirm
    edit f.json "e engine" "" "" n n "" "" y n q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"removing the engine also removes 1 model(s) of VM engine"* ]]
    [[ "$stderr" == *"unresolved_engine"* ]]
    [ "$(cat f.json)" = "$before" ]
}

@test "e <vm> removing the engine, y removes its models too" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json "e engine" "" "" n n "" "" y y q
    [[ "$stderr" == *"removing the engine also removes 1 model(s) of VM engine"* ]]
    [[ "$stderr" != *"unresolved_engine"* ]]
}

@test "e <vm> removing the chat interface announces the links that reach it; y removes them" {
    two_vm_file f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    # VM web: keep proxy, decline engine (not shipped there), decline chat-interface, options, confirm
    edit f.json "e web" "" "" "" n "" "" y y q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"removing the chat interface leaves 1 link(s) from VM web without one"* ]]
    [[ "$stderr" != *"link_without_chat_interface"* ]]
}

# --- a: add a VM -----------------------------------------------------------------------------

@test "a on a one-VM file names the existing machine first, then adds the second" {
    cat >one.json <<'JSON'
{ "schema_version": 1, "components": [ { "type": "proxy", "name": "prox" }, { "type": "engine", "name": "eng" } ] }
JSON
    GEN_ARGS=("${PKG[@]}" --output one.sh)
    # the existing machine named "engine", then a custom VM (default name "vm-1"): decline
    # proxy and engine, accept chat-interface, accept the proxy it needs, its options, confirm,
    # then its own links (default: engine), write
    edit one.json a engine custom "" n n y "" y "" "" y "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[].vm] | unique | sort | join(",")' one.json)" = "engine,vm-1" ]
    [[ "$stderr" == *"the existing machine is now VM engine"* ]]
}

@test "a asks a role, a name, a pass, then the links of that VM alone" {
    two_vm_file f.json
    jq '.components += [{"type": "proxy", "name": "prox", "vm": "extra"}, {"type": "engine", "name": "eng", "vm": "extra"}, {"type": "chat-interface", "name": "chat", "vm": "extra"}]
      | .links += [{"web_vm": "extra", "engine_vm": "engine"}]' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json a web web2 "" "" "" "" y "engine extra" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[] | select(.vm == "web2") | .type] | sort | join(",")' f.json)" = "chat-interface,proxy" ]
    [ "$(jq -c '[.links[] | select(.web_vm == "web2")] | sort' f.json)" = '[{"web_vm":"web2","engine_vm":"engine"},{"web_vm":"web2","engine_vm":"extra"}]' ]
    # the links of the other VMs are untouched
    [ "$(jq -c '[.links[] | select(.web_vm == "web")]' f.json)" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
}

# --- f: fix --------------------------------------------------------------------------------------

@test "f on unlinked_vm offers to redo the links, and fixes both VMs in one pass" {
    two_vm_file f.json
    jq 'del(.links)' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json f l "" y
    [ "$status" -eq 0 ]
    [ "$(jq -c '.links' f.json)" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
    [ -x f-engine.sh ]
}

@test "f on an unknown key offers to remove it" {
    two_vm_file f.json
    jq '.ghost = 1' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json f y y
    [ "$status" -eq 0 ]
    [ "$(jq 'has("ghost")' f.json)" = false ]
}

@test "f on wrong_type re-asks that one option directly" {
    two_vm_file f.json
    jq '.components[0].options = {"tls": {"bad": true}}' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json f lets-encrypt y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.components[0].options.tls' f.json)" = "lets-encrypt" ]
}

@test "f on duplicate_server_name re-asks the second VM's server-name directly" {
    two_vm_file f.json
    jq '.components[0].options["server-name"] = "same" | .components[2].options["server-name"] = "same"' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json f other y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.components[0].options["server-name"]' f.json)" = "same" ]
    [ "$(jq -r '.components[2].options["server-name"]' f.json)" = "other" ]
}

@test "f on missing_requirement adds the missing proxy directly" {
    cat >one.json <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ], "models": [ { "name": "m1", "force": true } ] }
JSON
    GEN_ARGS=("${PKG[@]}" --output one.sh)
    edit one.json f y "" "" "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[] | select(.type == "proxy") | .name] | join(",")' one.json)" = "prox" ]
}

@test "f on unresolved_engine re-asks that model's place directly" {
    two_vm_file f.json
    jq '.models[0].engine = "ghost"' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json f "" eng y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.models[0].engine' f.json)" = "eng" ]
    [ "$(jq -r '.models[0].vm' f.json)" = "engine" ]
}

@test "f on link_to_self offers to redo the links" {
    two_vm_file f.json
    jq '.links += [{"web_vm":"web","engine_vm":"web"}]' f.json >f.json.tmp && mv f.json.tmp f.json
    GEN_ARGS=("${PKG[@]}" --output f.sh)
    edit f.json f l engine y
    [ "$status" -eq 0 ]
    [ "$(jq -c '.links' f.json)" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
}
