#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Any number of VMs, and the editor of the configuration (docs/spec-multi-vm.md): the question of
# another VM after each pass, roles, names, a pass per VM, the links question, the summary of the
# whole configuration, one script per VM, the next steps, the warnings and errors between the VMs.
#
# Fake scripts shipped (only describe answers): proxy prox with the actions and the options of the
# real nginx that matter here (tls, server-name), engine eng (option port), protected engine prot,
# chat-interface chat (requires the type proxy) with the options of add-endpoint.

SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    GEN="${BATS_TEST_DIRNAME}/../../vm_script/config.sh"
    SCRIPT="${BATS_TEST_DIRNAME}/../../vm_script/script.sh"
    OUTFILE=""
    CLI="${BATS_TEST_DIRNAME}/../../package/bin/easy-cs-ai"
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
# _join_lines <answers…>: one line per answer; unlike "$(printf …)", a trailing empty answer is
# kept (command substitution would strip it, dropping a default taken at the end of the session).
_join_lines() {
    local a
    REPLY_LINES=""
    for a in "$@"; do REPLY_LINES+="$a"$'\n'; done
}
# ask <answers…>: the generator with one answer per line on stdin. A session ends on the editor of the
# whole configuration, where `y` writes, then the file to write (default ./easy-cs-ai.json), and the
# confirmation of an overwrite when the file exists already.
ask() {
    _join_lines "$@"
    ANSWERS="$REPLY_LINES"
    if [[ -n "$OUTFILE" ]]; then
        ANSWERS+=$'y\n'"$OUTFILE"$'\n'
        [[ ! -e "$OUTFILE" ]] || ANSWERS+=$'y\n'
    else
        ANSWERS+=$'y\n'
    fi
    export ANSWERS
    run --separate-stderr bash -c 'bash "$0" new "${@:1}" <<<"$ANSWERS"' "$GEN" "${GEN_ARGS[@]}"
}

# ask_script <answers…>: the session writes a configuration (session.json), then `script` makes the
# scripts from it, with GEN_ARGS as its options. A session that writes nothing (cancelled) stops here.
ask_script() {
    local script_args=("${GEN_ARGS[@]}") session_err
    GEN_ARGS=()
    OUTFILE=session.json
    ask "$@"
    [ "$status" -eq 0 ] || return 0
    [ -e session.json ] || return 0
    session_err="$stderr"
    gen session.json "${script_args[@]}"
    stderr="$session_err$stderr"
    OUTFILE=""
}
embedded() { sed -n "/<<'EASY_CS_AI_CONFIG'/,/^EASY_CS_AI_CONFIG\$/p" "$1" | sed '1d;$d'; }

# two_vm_file [<file> [<models-json>]]: an engine VM (proxy, engine, a model by default) and a web VM
# (proxy, chat-interface), the model shown in the chat interface: the file the session below writes.
two_vm_file() {
    local models='[ { "model": "m1", "name": "m1", "force": true } ]'
    (($# < 2)) || models="$2"
    cat >"$1" <<JSON
{
  "schema_version": 2,
  "vms": [
    { "name": "engine", "components": [
        { "component": "proxy/prox" },
        { "component": "engine/eng", "name": "eng", "models": $models } ] },
    { "name": "web", "components": [
        { "component": "proxy/prox" },
        { "component": "chat-interface/chat", "name": "chat" } ] }
  ],
  "links": [ { "model": { "vm_ref": "engine", "component_ref": "eng", "model_ref": "m1" },
               "chat_interface": { "vm_ref": "web", "component_ref": "chat" } } ]
}
JSON
}

# --- a two-VM session: role and name first, for every VM ------------------------------------------
#
# VM1: role engine, name (default "engine"), proxy and engine kept, their options kept (tls, server-name,
# port), a model, confirm. Another VM (y); VM2: role web, name (default "web"), proxy and chat-interface
# kept, the options of the proxy kept, confirm. No more VMs (n); where m1 is shown (default: web).
VM1_ANSWERS=(engine "" "" "" "" "" "" m1 y)
VM2_ANSWERS=(web "" "" "" "" "" y)
TWO_VM_SESSION=("${VM1_ANSWERS[@]}" y "${VM2_ANSWERS[@]}" n "")

# --- the question of another VM, and the three roles ---------------------------------------------

@test "the question of another VM is asked after the first pass, n (default) keeps one VM, named vm-1" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # role custom, name vm-1, proxy and engine, no chat interface, options, a model
    ask "" "" y "" y "" n "" "" "" m1 y ""
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Role of the new VM: engine, web or custom [custom]:"*"Name of the VM [vm-1]:"* ]]
    [[ "$stderr" == *"Add another VM? (y/n) [n]:"* ]]
    [ "$(jq -c '[.vms[] | .name]' cfg.json)" = '["vm-1"]' ]
    [ "$(jq -c '.vms[0].components | map(.component)' cfg.json)" = '["proxy/prox","engine/eng"]' ]
    [ "$(jq 'has("links")' cfg.json)" = "false" ]
}

@test "the question is not asked when nothing can be split" {
    rm "$EASY_CS_AI_HOME/chat-interface/chat.sh"
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" "" y "" y "" "" "" "" m1 y
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"Add another VM?"* ]]
}

@test "y builds a second VM, role and name first again, and where the model is shown is asked at the end" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${TWO_VM_SESSION[@]}"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Name of the VM [engine]:"* && "$stderr" == *"Name of the VM [web]:"* ]]
    [[ "$stderr" == *"Which chat interface shows m1 (on engine)? (a VM with a chat interface, none) [web]:"* ]]
    [ "$(jq -c '[.vms[] | [.name, (.components | map(.component))]]' cfg.json)" = '[["engine",["proxy/prox","engine/eng"]],["web",["proxy/prox","chat-interface/chat"]]]' ]
    [ "$(jq -c '.vms[0].components[1].models' cfg.json)" = '[{"model":"m1","name":"m1","force":true}]' ]
    [ "$(jq -c '.links' cfg.json)" = '[{"model":{"vm_ref":"engine","component_ref":"eng","model_ref":"m1"},"chat_interface":{"vm_ref":"web","component_ref":"chat"}}]' ]
    [ "$(grep -c '^Summary' <<<"$stderr")" -eq 2 ]
    [[ "$stderr" == *"m1 on engine, shown in web"* ]]
    bash "$CLI" config validate cfg.json --target fresh --json | jq -e '.ok'
}

@test "three VMs: the question, the role and the name are asked again after each pass" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y \
        engine eng2 "" "" "" "" "" "" y \
        y \
        web "" "" "" "" "" y \
        n ""
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.vms[].name] | join(",")' cfg.json)" = "engine,eng2,web" ]
    [ "$(jq -c '.links | length' cfg.json)" = 1 ]
}

@test "role engine or web must select the component that defines it: none is refused and asked again" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y \
        engine eng2 "" none "" "" "" "" "" y \
        y \
        web "" "" none "" "" "" y \
        n ""
    [ "$status" -eq 0 ]
    [ "$(grep -c 'is defined by its engine' <<<"$stderr")" -eq 1 ]
    [ "$(grep -c 'is defined by its chat-interface' <<<"$stderr")" -eq 1 ]
}

@test "role custom: every type one at a time, Add a <type>?, y by default, restarts if empty" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # the second VM, custom: decline every type (nothing yet, the walk restarts), then decline proxy and
    # engine again but accept the chat interface (which pulls the proxy in as a dependency)
    ask "${VM1_ANSWERS[@]}" y \
        custom "" n n n  n n y "" y "" "" y \
        n ""
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Add a proxy on vm-1? (y/n) [y]:"* ]]
    [[ "$stderr" == *"this VM has no component yet, choose again"* ]]
    [ "$(jq -r '.vms[] | select(.name == "vm-1") | [.components[].component] | sort | join(",")' cfg.json)" = "chat-interface/chat,proxy/prox" ]
}

@test "role custom: y then the choice of the component, rank 1 preselected" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y \
        custom "" y "" n y "" "" "" y \
        n ""
    [ "$status" -eq 0 ]
    [ "$(jq -r '.vms[] | select(.name == "vm-1") | [.components[].component] | sort | join(",")' cfg.json)" = "chat-interface/chat,proxy/prox" ]
}

@test "models in every pass that has an engine, each in the models of its engine; m offered only there" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # VM2 (engine role, named eng2): proxy, engine, tls, server-name, port, a model, confirm
    ask "${VM1_ANSWERS[@]}" y \
        engine eng2 "" "" "" "" "" m2 y \
        y \
        web "" "" "" "" "" y \
        n "" ""
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.vms[] | .name as $v | .components[] | select(.component == "engine/eng") | .models[] | [.model, $v]]' cfg.json)" = '[["m1","engine"],["m2","eng2"]]' ]
    [ "$(jq -c '.links | map(.model.model_ref)' cfg.json)" = '["m1","m2"]' ]
}

@test "m is offered at the summary of an engine-role pass and not at a web-role one" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y \
        engine eng2 "" "" "" "" "" "" m "" y \
        y \
        web "" "" "" "" "" m y \
        n "" ""
    [[ "$stderr" == *"redo a step: components (c), options (o), models (m)"* ]]
    [[ "$stderr" == *"redo a step: components (c), options (o)"* ]]
    [[ "$stderr" == *"'m' is not a valid answer"* ]]
}

@test "cancelling after a pass writes nothing" {
    GEN_ARGS=("${PKG[@]}" --output vm.sh)
    ask_script "${VM1_ANSWERS[@]}" y web "" "" "" "" n
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cancelled, nothing written"* ]]
    [ -z "$(ls vm*.sh 2>/dev/null)" ]
}

@test "the engine role proposes a proxy even with no model: refusing goes back to the components" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y \
        engine eng2 none "" "" "" n "" "" "" "" "" "" y \
        n "" ""
    [[ "$stderr" == *"Other VMs reach eng through a proxy (it listens on the loopback only). Add prox? (y/n) [y]:"* ]]
    [[ "$stderr" == *"other VMs could not reach eng without a proxy, choose the components again"* ]]
}

@test "no proxy is proposed for a protected engine, not even on an engine-role pass" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask engine "" none prot "" y \
        n
    [[ "$stderr" != *"reaches prot through a proxy"* ]]
    [[ "$stderr" == *"engine prot"* ]]
}

@test "each pass is sized from its own components: a web-role pass has no model and no share of the engine's" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask engine "" "" "" "" "" "" "" y y \
        web "" "" "" "" "" y \
        n
    [ "$status" -eq 0 ]
    [ "$(grep -c 'no recommendation: this package ships no sizing component' <<<"$stderr")" -eq 2 ]
}

# --- where each model is shown -------------------------------------------------------------------------

@test "the question names the models one by one, refuses a VM with no chat interface, none writes no link" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y "${VM2_ANSWERS[@]}" n ghost engine none
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"a model is installed on an engine and shown in a chat interface"* ]]
    [[ "$stderr" == *"'ghost' is not a VM with a chat interface (web)"* ]]
    [[ "$stderr" == *"'engine' is not a VM with a chat interface (web)"* ]]
    [ "$(jq 'has("links")' cfg.json)" = "false" ]
    [[ "$stderr" == *"m1 on engine, shown nowhere"* ]]
}

@test "with one VM and one chat interface it is a yes or no, never linked without the answer" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # role custom, name, proxy, engine, chat; options; a model; confirm; no other VM; the link
    ask "" "" y "" y "" y "" "" "" "" m1 y "" n
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Show m1 (on vm-1) in chat? (y/n) [y]:"* ]]
    [ "$(jq 'has("links")' cfg.json)" = "false" ]
}

@test "a link written by the session designates by name: the engine, the instance and the chat interface get theirs" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" "" y "" y "" y "" "" "" "" m1 y "" ""
    [ "$status" -eq 0 ]
    [ "$(jq -c '.links' cfg.json)" = '[{"model":{"vm_ref":"vm-1","component_ref":"eng","model_ref":"m1"},"chat_interface":{"vm_ref":"vm-1","component_ref":"chat"}}]' ]
    [ "$(jq -r '.vms[0].components | map(.name) | join(",")' cfg.json)" = ",eng,chat" ]
}

@test "the default is the engine's own VM when it holds a chat interface" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y \
        custom own y "" y "" y "" "" "" "" m2 y \
        y \
        web "" "" "" "" "" y \
        n web ""
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Which chat interface shows m2 (on own)? (a VM with a chat interface, none) [own]:"* ]]
    [[ "$stderr" == *"Which chat interface shows m1 (on engine)? (a VM with a chat interface, none) [none]:"* ]]
    [ "$(jq -c '.links | map([.model.vm_ref, .chat_interface.vm_ref])' cfg.json)" = '[["engine","web"],["own","own"]]' ]
}

# --- one script per VM ---------------------------------------------------------------------------

@test "a session of two VMs writes one script per VM, named from --output, each with its slice and its header" {
    GEN_ARGS=("${PKG[@]}" --output vm.sh)
    ask_script "${TWO_VM_SESSION[@]}"
    [ "$status" -eq 0 ]
    [ -x vm-engine.sh ] && [ -x vm-web.sh ]
    [ ! -e vm.sh ]
    grep -q '^# VM: engine (1 of 2)$' vm-engine.sh
    grep -q '^# VM: web (2 of 2)$' vm-web.sh
    [ "$(embedded vm-engine.sh | jq -c '[.vms[0].components[].component]')" = '["proxy/prox","engine/eng"]' ]
    [ "$(embedded vm-web.sh | jq -c '[.vms[0].components[].component]')" = '["proxy/prox","chat-interface/chat"]' ]
    [ "$(embedded vm-engine.sh | jq -c '.vms | length')" = 1 ]
    [ "$(embedded vm-engine.sh | jq -c '.vms[0].components[1].models | map(.model)')" = '["m1"]' ]
    [ "$(embedded vm-web.sh | jq '[.vms[0].components[] | has("models")] | any')" = "false" ]
    # the link of two machines is in no slice
    [ "$(embedded vm-engine.sh | jq 'has("links")')" = "false" ]
    [ "$(embedded vm-web.sh | jq 'has("links")')" = "false" ]
    bash -n vm-engine.sh && bash -n vm-web.sh
    [[ "$stderr" == *"Two scripts written, one per VM:"*"vm-engine.sh   VM engine"*"vm-web.sh   VM web"* ]]
}

@test "without --output the scripts are ./easy-cs-ai-vm-engine.sh and ./easy-cs-ai-vm-web.sh" {
    GEN_ARGS=("${PKG[@]}")
    ask_script "${TWO_VM_SESSION[@]}"
    [ "$status" -eq 0 ]
    [ -x easy-cs-ai-vm-engine.sh ] && [ -x easy-cs-ai-vm-web.sh ]
}

@test "--dry-run writes nothing and prints every script, --output with no extension appends the VM" {
    GEN_ARGS=("${PKG[@]}" --output out/vm --dry-run)
    mkdir out
    ask_script "${TWO_VM_SESSION[@]}"
    [ "$status" -eq 0 ]
    [ -z "$(ls out)" ]
    two_vm_file f.json
    gen f.json "${PKG[@]}" --output out/vm --dry-run
    [[ "$stderr" == *"would write out/vm-engine"*"would write out/vm-web"* ]]
    gen f.json "${PKG[@]}" --output out/vm
    [ -x out/vm-engine ] && [ -x out/vm-web ]
}

@test "one script that cannot be written keeps none" {
    two_vm_file f.json
    gen f.json "${PKG[@]}" --output nodir/vm.sh
    [ "$status" -eq 1 ]
    [ ! -e nodir ] && [ -z "$(ls vm*.sh 2>/dev/null)" ]
}

@test "the session of several VMs writes one file, the VMs with their components and the links" {
    GEN_ARGS=(); OUTFILE=only.json
    ask "${TWO_VM_SESSION[@]}"
    [ -s only.json ]
    [ "$(jq -r '[.vms[].name] | join(",")' only.json)" = "engine,web" ]
    [ "$(jq -c '.links | length' only.json)" = 1 ]
}

# --- a file of VMs ---------------------------------------------------------------------------------

@test "script on a file gives the scripts of the session and the same configuration" {
    two_vm_file f.json
    gen f.json "${PKG[@]}" --output file.sh
    [ "$status" -eq 0 ]
    file_err="$stderr"
    GEN_ARGS=("${PKG[@]}" --output ses.sh)
    ask_script "${TWO_VM_SESSION[@]}"
    [ "$status" -eq 0 ]
    diff <(embedded file-engine.sh | jq -S .) <(embedded ses-engine.sh | jq -S .)
    diff <(embedded file-web.sh | jq -S .) <(embedded ses-web.sh | jq -S .)
    diff <(grep -v '^# easy-cs-ai VM' file-engine.sh) <(grep -v '^# easy-cs-ai VM' ses-engine.sh)
    [[ "$file_err" != *"Confirm ("* ]]
    [[ "$file_err" == *"VM engine"*"VM web"* ]]
}

@test "script --json: script is null, scripts has one entry per VM, next_steps the instructions" {
    two_vm_file f.json
    gen f.json --json "${PKG[@]}" --output j.sh
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.ok, .script, (.scripts | map(.vm)), (.scripts | map(.path)), (.scripts | map(.written))]' <<<"$output")" = '[true,null,["engine","web"],["j-engine.sh","j-web.sh"],[true,true]]' ]
    [ "$(jq '.next_steps | length' <<<"$output")" -eq 4 ]
    [ "$(jq -r '.plan.vms | map(.name) | join(",")' <<<"$output")" = "engine,web" ]
    [ "$(jq -c '.plan.links | map([.model.vm_ref, .chat_interface.vm_ref])' <<<"$output")" = '[["engine","web"]]' ]
    jq 'del(.vms[0].name)' f.json >bad.json
    gen bad.json --json "${PKG[@]}" --output k.sh
    [ "$status" -eq 2 ]
    [ "$(jq -c '[.ok, .script, .scripts, .next_steps]' <<<"$output")" = '[false,null,[],[]]' ]
    [ ! -e k-engine.sh ]
}

@test "a model on an engine VM with no proxy is refused before any script is written" {
    two_vm_file f.json
    jq 'del(.vms[0].components[0])' f.json >np.json
    gen np.json "${PKG[@]}" --output n.sh
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"needs a proxy"* ]]
    [ -z "$(ls n*.sh 2>/dev/null)" ]
}

@test "a lone VM with no name gives the script ./easy-cs-ai-vm.sh, with no VM line, and no next steps text" {
    printf '%s' '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"engine/eng"}]}]}' >one.json
    gen one.json --json "${PKG[@]}" --output o.sh
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.script.path, .next_steps]' <<<"$output")" = '["o.sh",["Run each script as root on its VM."]]' ]
    [ -z "$(grep '^# VM:' o.sh)" ]
    [[ "$stderr" != *"What is left to do"* ]] || true
}

@test "a file that names one VM takes the path of several: a script named after the VM, its header, scripts with one entry" {
    printf '%s' '{"schema_version":2,"vms":[{"name":"a","components":[{"component":"proxy/prox"},{"component":"engine/eng"}]}]}' >one.json
    gen one.json --json "${PKG[@]}" --output o.sh
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.script, (.scripts | map(.vm)), (.scripts | map(.path))]' <<<"$output")" = '[null,["a"],["o-a.sh"]]' ]
    grep -q '^# VM: a (1 of 1)$' o-a.sh
    [ ! -e o.sh ]
    # a file of one VM needs no --vm
    run --separate-stderr bash "$CLI" apply one.json --dry-run
    [ "$status" -eq 0 ]
}

# --- the next steps ----------------------------------------------------------------------------

@test "two VMs, an engine behind a proxy with a model: the four steps of the administrator, one command per linked model" {
    two_vm_file f.json '[{"model":"m1","name":"m1","force":true},{"model":"m2","name":"m2","force":true}]'
    jq '.links += [{"model":{"vm_ref":"engine","component_ref":"eng","model_ref":"m2"},"chat_interface":{"vm_ref":"web","component_ref":"chat"}}]' f.json >g.json
    gen g.json "${PKG[@]}" --output s.sh
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"What is left to do once the VMs are up:"* ]]
    [[ "$stderr" == *"1. Run each script as root on its VM, the engine VMs first."* ]]
    [[ "$stderr" == *"2. On the engine VM engine, read the API key, the URL of each model and the names"* ]]
    [[ "$stderr" == *"sudo easy-cs-ai component proxy prox show-key"* && "$stderr" == *"easy-cs-ai component proxy prox list-upstreams"* ]]
    [[ "$stderr" == *"3. Let the VM web reach the VM engine on the HTTPS port of its proxy"* ]]
    [[ "$stderr" == *"4. On the VM web, link each model of the VM engine:"* ]]
    [[ "$stderr" == *"add-endpoint engine-eng-m1"*"--model m1 --api-key-file <file>"*"add-endpoint engine-eng-m2"*"--model m2 --api-key-file <file>"* ]]
    [[ "$stderr" == *"sudo easy-cs-ai install proxy prox <the options it was installed with>"* ]]
    [[ "$stderr" == *"Until step 4 is done, the model list of the chat interface stays empty."* ]]
    gen g.json --json "${PKG[@]}" --output s.sh
    [ "$(jq '.next_steps | length' <<<"$output")" -eq 4 ]
    [[ "$(jq -r '.next_steps | join(" ")' <<<"$output")" != *"s-engine.sh"* ]]
    [ "$(jq -r '.next_steps[0]' <<<"$output")" = "Run each script as root on its VM, the engine VMs first." ]
    [[ "$(jq -r '.next_steps[1]' <<<"$output")" != "2."* ]]
}

@test "the steps are the validation's: config validate gives the same ones, with no script written" {
    two_vm_file f.json
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$status" -eq 0 ]
    doc="$output"
    gen f.json --json "${PKG[@]}" --output t.sh
    [ "$(jq -c '.next_steps' <<<"$output")" = "$(jq -c '.next_steps' <<<"$doc")" ]
    run --separate-stderr bash "$CLI" config validate f.json --target fresh
    [[ "$stderr" == *"What is left to do once the VMs are up:"* ]]
}

@test "step 1 alone when a condition of the steps 2 to 4 is broken, one case per condition" {
    two_vm_file f.json
    one='["Run each script as root on its VM."]'
    jq 'del(.links)' f.json >c1.json
    run --separate-stderr bash "$CLI" config validate c1.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    # a link to a model of a protected engine to another VM is an error: no step at all
    jq '.vms[0].components[1].component = "engine/prot"' f.json >c3.json
    run --separate-stderr bash "$CLI" config validate c3.json --target fresh --json
    [ "$status" -eq 2 ]
    [ "$(jq -c '.next_steps' <<<"$output")" = "[]" ]
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false,"description":"certificate"}]' '{"actions":["install","status"]}'
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false,"description":"certificate"}]' '{"actions":["install","status","show-key","list-upstreams"]}'
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --vm engine --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
}

# --- the warnings and errors between the VMs ------------------------------------------------------

@test "engine_address_unknown: a self-signed proxy with no server name, a model shown on another VM" {
    two_vm_file f.json
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm_ref]' <<<"$output")" = '["engine"]' ]
    [ "$status" -eq 0 ]
    jq '(.vms[0].components[0].options) = {"server-name": "llm.example.org"}' f.json >w1.json
    jq '(.vms[0].components[0].options) = {"tls": "letsencrypt"}' f.json >w2.json
    for f in w1 w2; do
        run --separate-stderr bash "$CLI" config validate $f.json --target fresh --json
        [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
    done
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --vm engine --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
}

@test "models_not_checked is judged per VM and shown once, in the summary of the VM that holds the model" {
    two_vm_file f.json
    gen f.json "${PKG[@]}" --output m.sh
    [ "$(grep -c 'models not checked for fit on the VM' <<<"$stderr")" -eq 1 ]
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '[.warnings[] | select(.code == "models_not_checked") | .vm_ref]' <<<"$output")" = '["engine"]' ]
}

@test "the guide names the commands of the next steps" {
    run bash "$CLI" guide
    [ "$status" -eq 0 ]
    for w in "proxy NAME show-key" "proxy NAME list-upstreams" "proxy NAME status" "add-endpoint" "install proxy NAME" "--server-name" "next_steps"; do
        [[ "$output" == *"$w"* ]] || { echo "the guide does not name: $w"; false; }
    done
}

# --- with the shipped scripts ---------------------------------------------------------------

@test "with the shipped scripts the next steps are the four, and name only actions and options that exist" {
    export EASY_CS_AI_HOME="$REAL"
    cat >real.json <<'JSON'
{
  "schema_version": 2,
  "vms": [
    { "name": "engine", "components": [
        { "component": "proxy/nginx" },
        { "component": "engine/ollama", "name": "ollama", "models": [ { "model": "llama3.2:3b", "name": "llama3.2:3b", "force": true } ] } ] },
    { "name": "web", "components": [
        { "component": "proxy/nginx" },
        { "component": "chat-interface/librechat", "name": "librechat" } ] }
  ],
  "links": [ { "model": { "vm_ref": "engine", "component_ref": "ollama", "model_ref": "llama3.2:3b" },
               "chat_interface": { "vm_ref": "web", "component_ref": "librechat" } } ]
}
JSON
    run --separate-stderr bash "$CLI" config validate real.json --target fresh --json
    [ "$status" -eq 0 ]
    [ "$(jq '.next_steps | length' <<<"$output")" -eq 4 ]
    text="$(jq -r '.next_steps | join("\n")' <<<"$output")"
    [[ "$text" == *"easy-cs-ai component proxy nginx list-upstreams"* && "$text" == *"component chat-interface librechat add-endpoint"* ]]
    [[ "$text" == *"--model llama3.2:3b --api-key-file <file>"* && "$text" == *"--ca-file <file>"* ]]
    nginx="$(bash "$REAL/proxy/nginx.sh" describe)"
    librechat="$(bash "$REAL/chat-interface/librechat.sh" describe)"
    for a in show-key list-upstreams status install; do
        jq -e --arg a "$a" '.actions | index($a)' <<<"$nginx" >/dev/null
    done
    jq -e '.options | map(.name) | index("server-name")' <<<"$nginx" >/dev/null
    for o in model api-key-file ca-file; do
        jq -e --arg o "$o" '.action_options["add-endpoint"] | map(.name) | index($o)' <<<"$librechat" >/dev/null
    done
    jq -e '.actions | index("add-endpoint")' <<<"$librechat" >/dev/null
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm_ref]' <<<"$(bash "$CLI" config validate real.json --target fresh --json)")" = '["engine"]' ]
}

@test "the command of step 4 is on two lines: a backslash, then a real new line" {
    two_vm_file f.json
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    step4="$(jq -r '.next_steps[3]' <<<"$output")"
    [[ "$step4" != *'\n'* ]]
    grep -qxF '  sudo easy-cs-ai component chat-interface chat add-endpoint engine-eng-m1 <url> \' <<<"$step4"
    grep -qx '    --model m1 --api-key-file <file>' <<<"$step4"
    grep -qx '    --server-name <name or address>' <<<"$step4"
}

# --- the sizing of each pass, with a llmfit that is there --------------------------------------

make_llmfit() {
    cat >"$EASY_CS_AI_HOME/provisioning/llmfit.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$1" in
describe) jq -n '{name: "llmfit", type: "provisioning", component_version: "9.9", requires: [], platforms: ["debian","ubuntu"], options: []}' ;;
status) echo '{"installed":true,"running":true,"healthy":true}' ;;
suggest) printf '   1) m1:1b   Good, needs 1 GB\n' ;;
plan) printf '\nFAKE PLAN of %s\n' "$*" ;;
esac
FAKE
    chmod +x "$EASY_CS_AI_HOME/provisioning/llmfit.sh"
    printf 'provisioning llmfit\nengine eng\nproxy prox\nchat-interface chat\n' >"$EASY_CS_AI_HOME/ranks.conf"
    export CALLS="$BATS_TEST_TMPDIR/llmfit-calls"
    : >"$CALLS"
}

@test "each pass is sized from its own components, and the cores given for the engine VM stay with it" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    # VM1 (engine role, "engine"): llmfit, proxy, engine, hardware first, no spec, no model.
    # VM2 (engine role, "engine-2"): same, but 16 GB RAM, no GPU and 4 cores. VM3 (web role).
    ask engine "" "" "" "" "" "" "" "" "" "" "" "" y \
        y \
        engine "" "" "" "" "" "" "" "" 16 "" 4 "" y \
        y \
        web "" "" "" "" "" y \
        n
    [ "$status" -eq 0 ]
    grep -qx 'plan --component provisioning/llmfit --component proxy/prox --component engine/eng' "$CALLS"
    grep -qx 'plan --component provisioning/llmfit --component proxy/prox --component engine/eng --target-cpu-cores 4' "$CALLS"
    grep -qx 'plan --component proxy/prox --component chat-interface/chat' "$CALLS"
    [ "$(grep -c '^plan' "$CALLS")" -eq 3 ]
    [[ "$stderr" == *"FAKE PLAN of plan --component provisioning/llmfit"* && "$stderr" == *"FAKE PLAN of plan --component proxy/prox --component chat-interface/chat"* ]]
}

@test "in the m order the engine role asks for its models as <model>@<engine>, with its own components and no chat interface" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask engine "" "" "" "" "" "" "" m "m1, m2" y \
        y \
        web "" "" "" "" "" y \
        n "" ""
    [ "$status" -eq 0 ]
    grep -qx 'plan m1@eng m2@eng --component provisioning/llmfit --component proxy/prox --component engine/eng' "$CALLS"
    [ "$(jq -c '[.vms[0].components[] | .models[]? | .model]' cfg.json)" = '["m1","m2"]' ]
}
