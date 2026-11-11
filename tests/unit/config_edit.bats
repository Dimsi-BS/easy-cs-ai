#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The editor, `config edit <file>` (docs/spec-multi-vm.md#editing): opening an existing
# configuration in the session, the summary of the whole thing, and the a/e/m/l/n/r/f/y/q
# commands.
#
# Fake scripts shipped: proxy prox (tls, server-name, the actions next_steps needs), engine eng
# (option port), protected engine prot, chat-interface chat (requires proxy, add-endpoint opts).

SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    GEN="${BATS_TEST_DIRNAME}/../../vm_script/config.sh"
    SCRIPT="${BATS_TEST_DIRNAME}/../../vm_script/script.sh"
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

gen() { run --separate-stderr bash "$SCRIPT" "$@"; }
# cfg <args…>: the session, `config edit` with arguments.
cfg() { run --separate-stderr bash "$GEN" edit "$@"; }
_join_lines() {
    local a
    REPLY_LINES=""
    for a in "$@"; do REPLY_LINES+="$a"$'\n'; done
}
# edit <file> <answers…>: open <file> in the editor with one answer per line on stdin. When the
# last answer is y (write), an empty one follows: the default of the question of the file written.
edit() {
    local file="$1"
    shift
    if [[ "${!#}" == y ]]; then _join_lines "$@" ""; else _join_lines "$@"; fi
    ANSWERS="$REPLY_LINES"
    export ANSWERS GEN_FILE="$file"
    run --separate-stderr bash -c 'bash "$0" edit "$GEN_FILE" "${@:1}" <<<"$ANSWERS"' "$GEN" "${GEN_ARGS[@]}"
}
embedded() { sed -n "/<<'EASY_CS_AI_CONFIG'/,/^EASY_CS_AI_CONFIG\$/p" "$1" | sed '1d;$d'; }

two_vm_file() {
    cat >"$1" <<'JSON'
{
  "schema_version": 2,
  "vms": [
    { "name": "engine", "components": [
        { "component": "proxy/prox" },
        { "component": "engine/eng", "name": "eng", "models": [ { "model": "m1", "name": "m1", "force": true } ] } ] },
    { "name": "web", "components": [
        { "component": "proxy/prox" },
        { "component": "chat-interface/chat", "name": "chat" } ] }
  ],
  "links": [ { "model": { "vm_ref": "engine", "component_ref": "eng", "model_ref": "m1" },
               "chat_interface": { "vm_ref": "web", "component_ref": "chat" } } ]
}
JSON
}

one_vm_file() { # <file> [<name>]
    cat >"$1" <<JSON
{
  "schema_version": 2,
  "vms": [ { ${2:+\"name\": \"$2\",} "components": [
      { "component": "proxy/prox" },
      { "component": "engine/eng", "models": [ { "model": "m1", "force": true } ] },
      { "component": "chat-interface/chat" } ] } ]
}
JSON
}

# --- usage -----------------------------------------------------------------------------------

@test "config edit: --json and an unknown option are exit 2, a second file too" {
    cfg --json
    [ "$status" -eq 2 ]
    cfg --bogus
    [ "$status" -eq 2 ]
    two_vm_file f.json
    cfg f.json g.json
    [ "$status" -eq 2 ]
}

@test "config edit on a missing file, or a file that is not JSON, is exit 2" {
    cfg nope.json
    [ "$status" -eq 2 ]
    echo 'not json' >bad.json
    cfg bad.json
    [ "$status" -eq 2 ]
}

# --- opening and the summary -------------------------------------------------------------------

@test "opening a valid file shows its VMs, components, models and where each model is shown" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"VM engine"* && "$stderr" == *"VM web"* ]]
    [[ "$stderr" == *"proxy prox"* && "$stderr" == *"engine eng"* && "$stderr" == *"chat-interface chat"* ]]
    [[ "$stderr" == *"models: m1"* ]]
    [[ "$stderr" == *"m1 on engine, shown in web"* ]]
    [[ "$stderr" == *"cancelled, nothing written"* ]]
}

@test "a model with no link is shown nowhere, and the VM with no engine prints no models line" {
    two_vm_file f.json
    jq 'del(.links)' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"m1 on engine, shown nowhere"* ]]
    [[ "$stderr" != *"[ERROR]"* ]]
    [ "$(grep -c 'models: ' <<<"$stderr")" -eq 1 ]
}

@test "a file of version 1 is refused at loading with a message that the format changed" {
    echo '{"schema_version":1,"components":[]}' >v1.json
    GEN_ARGS=()
    edit v1.json q
    [[ "$stderr" == *"the format changed"* ]]
    [[ "$stderr" == *"[unsupported_schema_version]"* ]]
}

@test "opening a file with errors shows them, numbered, and q leaves it untouched" {
    two_vm_file f.json
    jq '.links[0].model.model_ref = "zzz"' f.json >f.tmp && mv f.tmp f.json
    before="$(cat f.json)"
    GEN_ARGS=()
    edit f.json q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"1. \$.links[0].model.model_ref"*"[unresolved_model]"* ]]
    [ "$(cat f.json)" = "$before" ]
}

@test "y refuses while an error stands" {
    two_vm_file f.json
    jq '.links[0].model.model_ref = "zzz"' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json y q
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"nothing is written while an error stands"* ]]
}

# --- y: write ------------------------------------------------------------------------------------

@test "y with no change writes the configuration back, no script, and names the command for them" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json y
    [ "$status" -eq 0 ]
    [ -z "$(ls f-*.sh easy-cs-ai-vm*.sh 2>/dev/null)" ]
    [ "$(jq -S . f.json)" = "$(two_vm_file /dev/stdout | jq -S .)" ]
    [[ "$stderr" == *"File to write (overwritten, or created if it does not exist) [f.json]:"* ]]
    [[ "$stderr" == *"configuration written to f.json"* ]]
    [[ "$stderr" == *"to generate the scripts: easy-cs-ai script f.json"* ]]
}

@test "the file written: another name makes a copy and leaves the file opened as it was" {
    two_vm_file f.json
    before="$(cat f.json)"
    GEN_ARGS=()
    edit f.json "n engine" engine2 y copy.json
    [ "$status" -eq 0 ]
    [ "$(cat f.json)" = "$before" ]
    [ "$(jq -r '[.vms[].name] | sort | join(",")' copy.json)" = "engine2,web" ]
    [ "$(jq -r '.links[0].model.vm_ref' copy.json)" = engine2 ]
}

@test "the file written: an existing file other than the one opened is confirmed, n asks again" {
    two_vm_file f.json
    echo '{"keep":1}' >other.json
    GEN_ARGS=()
    edit f.json y other.json n new.json
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"other.json exists. Overwrite? (y/n) [n]:"* ]]
    [ "$(cat other.json)" = '{"keep":1}' ]
    [ -s new.json ]
    edit f.json y other.json y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema_version' other.json)" = 2 ]
}

@test "the file written: a directory, or a directory that does not exist, is refused and asked again" {
    two_vm_file f.json
    mkdir adir
    GEN_ARGS=()
    edit f.json y adir nodir/x.json ok.json
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"adir is a directory"* ]]
    [[ "$stderr" == *"cannot write in nodir"* ]]
    [ -s ok.json ]
}

@test "the end of input at the question of the file writes nothing" {
    two_vm_file f.json
    before="$(cat f.json)"
    run --separate-stderr bash -c 'printf "y\n" | bash "$0" edit f.json' "$GEN"
    [ "$status" -eq 0 ]
    [ "$(cat f.json)" = "$before" ]
}

@test "--dry-run writes nothing" {
    two_vm_file f.json
    before="$(cat f.json)"
    GEN_ARGS=(--dry-run)
    edit f.json "n engine" engine2 y
    [ "$status" -eq 0 ]
    [ "$(cat f.json)" = "$before" ]
    [[ "$stderr" == *"dry run, would write f.json"* ]]
}

# --- rename and remove ---------------------------------------------------------------------------

@test "n <vm> renames it and the references of the links that designate it follow" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json "n web" site y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms[1].name' f.json)" = site ]
    [ "$(jq -r '.links[0].chat_interface.vm_ref' f.json)" = site ]
    [[ "$stderr" == *"m1 on engine, shown in site"* ]]
}

@test "n refuses a name of the wrong shape or already taken, and asks again" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json "n web" Bad engine site q
    [[ "$stderr" == *"'Bad' is not lowercase letters"* ]]
    [[ "$stderr" == *"'engine' is already the name of another VM"* ]]
    [[ "$stderr" == *"VM site"* ]]
}

@test "r <vm> removes it with its components, its models and the links naming it" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json "r engine" y y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms | length' f.json)" -eq 1 ]
    [ "$(jq 'has("links")' f.json)" = false ]
    [[ "$stderr" == *"removing VM engine: proxy/prox, engine/eng"* ]]
}

@test "removing the chat interface's VM leaves the model shown nowhere" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json "r web" y y
    [ "$status" -eq 0 ]
    [ "$(jq 'has("links")' f.json)" = false ]
    [ "$(jq -r '.vms[0].components[1].models[0].model' f.json)" = m1 ]
}

@test "down to one VM, the name stays and so do the references" {
    two_vm_file f.json
    jq '.links += []' f.json >/dev/null
    GEN_ARGS=()
    edit f.json "r web" y q
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"keep its vm field"* ]]
    [[ "$stderr" == *"VM engine"* ]]
}

@test "the last VM cannot be removed" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json "r web" y "r engine" q
    [[ "$stderr" == *"the last VM cannot be removed"* ]]
}

@test "saving regenerates nothing: the scripts of an older configuration stay, and script lists the stale ones" {
    two_vm_file f.json
    gen f.json --output out.sh "${PKG[@]}"
    [ "$status" -eq 0 ]
    [ -f out-engine.sh ] && [ -f out-web.sh ]
    GEN_ARGS=()
    edit f.json "n web" site y
    [ "$status" -eq 0 ]
    [ -f out-web.sh ]
    gen f.json --output out.sh "${PKG[@]}"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"no longer produced by any VM"*"out-web.sh"* ]]
    [ -f out-web.sh ]
}

# --- where the models are shown -------------------------------------------------------------------

@test "l asks where each model is shown, the current link as the default, none removes it" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json l none y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Which chat interface shows m1 (on engine)? (a VM with a chat interface, none) [web]:"* ]]
    [ "$(jq 'has("links")' f.json)" = false ]
}

@test "l refuses a VM that holds no chat interface, with the reason" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json l engine web y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"'engine' is not a VM with a chat interface (web)"* ]]
    [ "$(jq -r '.links[0].chat_interface.vm_ref' f.json)" = web ]
}

@test "with one VM and one chat interface the question is a yes or no, and n writes no link" {
    one_vm_file f.json vm-1
    GEN_ARGS=()
    edit f.json l n y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Show m1 (on vm-1) in chat? (y/n) [y]:"* ]]
    [ "$(jq 'has("links")' f.json)" = false ]
}

@test "a link written by the session names what it designates: the VM, the engine, the instance, the chat interface" {
    one_vm_file f.json vm-1
    GEN_ARGS=()
    edit f.json l y y
    [ "$status" -eq 0 ]
    [ "$(jq -c '.links' f.json)" = '[{"model":{"vm_ref":"vm-1","component_ref":"eng","model_ref":"m1"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}]' ]
    [ "$(jq -r '.vms[0].components[1].name' f.json)" = eng ]
    [ "$(jq -r '.vms[0].components[1].models[0].name' f.json)" = m1 ]
    [ "$(jq -r '.vms[0].components[2].name' f.json)" = chat ]
}

@test "a lone VM with no name is asked its name when a link is to be written" {
    one_vm_file f.json
    GEN_ARGS=()
    edit f.json l "" y y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Name of the VM [vm-1]:"* ]]
    [ "$(jq -r '.vms[0].name' f.json)" = vm-1 ]
    [ "$(jq '.links | length' f.json)" -eq 1 ]
}

@test "m <vm> redoes its models, keeping its components, then asks where each is shown" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json "m engine" "m1,m2" y "" "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.vms[0].components[1].models[].model] | join(",")' f.json)" = "m1,m2" ]
}

# --- e: edit a VM, a: add one ---------------------------------------------------------------------

@test "e <vm> keeps the names and what the pass does not show, and removing the engine removes the links of its models" {
    two_vm_file f.json
    GEN_ARGS=()
    edit f.json "e engine" "" "" n "" "" "" y y
    [ "$status" -eq 0 ]
    [ "$(jq '.vms[0].components | length' f.json)" -eq 1 ]
    [ "$(jq 'has("links")' f.json)" = false ]
    [[ "$stderr" == *"removing 1 link(s) that designated what is gone"* ]]
}

@test "a on a file of one VM with no name names it first, then adds the second" {
    one_vm_file f.json
    GEN_ARGS=()
    edit f.json a "" web "" "" "" "" y "" "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.vms[].name] | join(",")' f.json)" = "vm-1,web" ]
}

@test "a asks a role, a name, a pass, then where the models without a link are shown" {
    two_vm_file f.json
    jq 'del(.links)' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json a web web2 "" "" "" "" y web2 y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Which chat interface shows m1 (on engine)? (a VM with a chat interface, none) ["* ]]
    [ "$(jq -r '.links[0].chat_interface.vm_ref' f.json)" = web2 ]
}

# --- f: fixing -------------------------------------------------------------------------------------

@test "f on an unknown key offers to remove it" {
    two_vm_file f.json
    jq '.vms[0].bogus = 1' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f y y
    [ "$status" -eq 0 ]
    [ "$(jq '.vms[0] | has("bogus")' f.json)" = false ]
}

@test "f on an unresolved model asks where that model is shown again, a link that designates nothing is offered for removal" {
    two_vm_file f.json
    jq 'del(.vms[0].components[1].models[0].name)' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms[0].components[1].models[0].name' f.json)" = m1 ]
    [ "$(jq -c '.links[0].model' f.json)" = '{"vm_ref":"engine","component_ref":"eng","model_ref":"m1"}' ]
    [ "$(jq '.links | length' f.json)" -eq 1 ]
}

@test "f on a duplicate link offers to remove the second" {
    two_vm_file f.json
    jq '.links += [.links[0]]' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f y y
    [ "$status" -eq 0 ]
    [ "$(jq '.links | length' f.json)" -eq 1 ]
}

@test "f on wrong_type re-asks that one option directly" {
    two_vm_file f.json
    jq '.vms[0].components[1].options = {"port": [1]}' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f 11500 y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms[0].components[1].options.port' f.json)" = 11500 ]
}

@test "f on duplicate_server_name re-asks the second VM's server-name directly" {
    two_vm_file f.json
    jq '.vms[0].components[0].options = {"server-name":"a.example.org"} | .vms[1].components[0].options = {"server-name":"A.example.org"}' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f b.example.org y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms[1].components[0].options["server-name"]' f.json)" = b.example.org ]
}

@test "f on missing_requirement adds the missing proxy directly" {
    two_vm_file f.json
    jq 'del(.vms[0].components[0])' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f y prox "" "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.vms[0].components[].component] | join(",")' f.json | grep -c 'proxy/prox')" -eq 1 ]
}

@test "f on a VM with no name asks the name, and on a duplicate asks again" {
    two_vm_file f.json
    jq 'del(.vms[1].name) | .links = []' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f site y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms[1].name' f.json)" = site ]
}

@test "f on missing_option re-asks that option, and a secret as the path of the file that holds it" {
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false},{"name":"server-name","default":"","secret":false,"required_when":{"option":"tls","values":["letsencrypt"]}},{"name":"tls-key","default":"","secret":true,"sources":["file","env"],"required_when":{"option":"tls","values":["provided"]}}]' '{"actions":["install"]}'
    two_vm_file f.json
    jq '.vms[1].components[0].options = {"tls":"letsencrypt"}' f.json >f.tmp && mv f.tmp f.json
    GEN_ARGS=()
    edit f.json f x.example.org y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms[1].components[0].options["server-name"]' f.json)" = x.example.org ]
    jq '.vms[1].components[0].options = {"tls":"provided"}' f.json >f.tmp && mv f.tmp f.json
    edit f.json f /etc/key y
    [ "$status" -eq 0 ]
    [ "$(jq -c '.vms[1].components[0].options["tls-key"]' f.json)" = '{"file":"/etc/key"}' ]
}

@test "config needs new or edit <file>: new takes no file, edit needs one, each hint names the other" {
    run --separate-stderr bash "$GEN"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"config new"*"config edit <file>"* ]]
    run --separate-stderr bash "$GEN" new f.json
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"config edit f.json"* ]]
    run --separate-stderr bash "$GEN" edit
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"config new"* ]]
}
