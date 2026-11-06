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
# ask <answers…>: the generator with one answer per line on stdin.
ask() {
    _join_lines "$@"
    ANSWERS="$REPLY_LINES"
    export ANSWERS
    # the last question of the session is the file to write (default ./easy-cs-ai.json), and the
    # confirmation of an overwrite when the file exists already
    if [[ -n "$OUTFILE" ]]; then
        ANSWERS+="$OUTFILE"$'\n'
        [[ ! -e "$OUTFILE" ]] || ANSWERS+=$'y\n'
    fi
    export ANSWERS
    run --separate-stderr bash -c 'bash "$0" "${@:1}" <<<"$ANSWERS"' "$GEN" "${GEN_ARGS[@]}"
}

# ask_script <answers…>: the session writes a configuration (session.json), then `script` makes the
# scripts from it, with GEN_ARGS as its options. Two commands since the split of generate: the
# session writes no script. A session that writes nothing (cancelled) stops here, status 0.
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

# two_vm_file [<models-json>]: an engine VM (proxy, engine, a model by default) and a web VM
# (proxy, chat-interface), linked web -> engine.
two_vm_file() {
    local models='[ { "name": "m1", "force": true, "vm": "engine", "engine": "eng" } ]'
    (($# < 2)) || models="$2"
    cat >"$1" <<JSON
{
  "schema_version": 1,
  "components": [
    { "type": "proxy", "name": "prox", "vm": "engine" },
    { "type": "engine", "name": "eng", "vm": "engine" },
    { "type": "proxy", "name": "prox", "vm": "web" },
    { "type": "chat-interface", "name": "chat", "vm": "web" }
  ],
  "models": $models,
  "links": [ { "web_vm": "web", "engine_vm": "engine" } ]
}
JSON
}

# --- a two-VM session: the first VM plain, then a role, a name and a pass for the second --------
#
# VM1 (the plain pass, no role): proxy and engine kept at their default, chat-interface declined,
# their options kept, a model, confirm. Then: add another VM (y), name it "engine", role "web",
# name it (default "web"), its pass (proxy and chat-interface kept, options kept, confirm, no
# models step), no more VMs, the links question (default: web -> engine), write.
VM1_ANSWERS=("" "" none "" "" "" m1 y)
VM2_ANSWERS=("" "" "" "" y)
TWO_VM_SESSION=("${VM1_ANSWERS[@]}" y engine web "" "${VM2_ANSWERS[@]}" n "" y)

# --- the question of another VM, and the three roles ---------------------------------------------

@test "the question of another VM is asked after the first pass, n (default) keeps one VM" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" ""
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Add another VM? (y/n) [n]:"* ]]
    [ "$(jq -c '[.components[] | .type]' cfg.json)" = '["proxy","engine"]' ]
    [ "$(jq 'has("vm")' cfg.json)" = "false" ]
    [ "$(jq 'has("links")' cfg.json)" = "false" ]
}

@test "the question is not asked when nothing can be split" {
    rm "$EASY_CS_AI_HOME/chat-interface/chat.sh"
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" "" "" "" "" m1 y
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"Add another VM?"* ]]
}

@test "y names the first VM and builds a second, asking its role and its name, for any number of VMs" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${TWO_VM_SESSION[@]}"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Name of the VM [vm-1]:"* ]]
    [[ "$stderr" == *"Role of the new VM: engine, web or custom [custom]:"* ]]
    [[ "$stderr" == *"Name of the VM [web]:"* ]]
    [ "$(jq -c '[.components[] | [.vm, .type, .name]]' cfg.json)" = '[["engine","proxy","prox"],["engine","engine","eng"],["web","proxy","prox"],["web","chat-interface","chat"]]' ]
    [ "$(jq -c '.models' cfg.json)" = '[{"name":"m1","force":true,"vm":"engine","engine":"eng"}]' ]
    [ "$(jq -c '.links' cfg.json)" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
    [ "$(grep -c '^Summary' <<<"$stderr")" -eq 2 ]
    [[ "$stderr" == *"VM web"* ]]
    bash "$CLI" config validate cfg.json --target fresh --json | jq -e '.ok'
}

@test "three VMs: the question and the role are asked again after each pass" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # engine, then a second engine-role VM "eng2" (its own proxy and engine, no model), then a web
    # VM linked to both (the default of the links question)
    ask "${VM1_ANSWERS[@]}" y engine \
        engine eng2 "" "" "" "" "" "" y \
        y \
        web "" "" "" "" "" y \
        n "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[].vm] | unique | join(",")' cfg.json)" = "eng2,engine,web" ]
    [ "$(jq -c '.links' cfg.json)" = '[{"web_vm":"web","engine_vm":"engine"},{"web_vm":"web","engine_vm":"eng2"}]' ]
}

@test "role engine or web must select the component that defines it: none is refused and asked again" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y engine \
        engine "" "" none "" "" "" "" "" y \
        y \
        web "" "" none "" "" "" y \
        n "" y
    [ "$status" -eq 0 ]
    [ "$(grep -c 'is defined by its engine' <<<"$stderr")" -eq 1 ]
    [ "$(grep -c 'is defined by its chat-interface' <<<"$stderr")" -eq 1 ]
}

@test "role custom: every type one at a time, Add a <type>?, nothing required, restarts if empty" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # the second VM, custom: decline every type (nothing yet, the walk restarts), then decline
    # proxy and engine again but accept chat-interface (which pulls proxy in as a dependency)
    ask "${VM1_ANSWERS[@]}" y engine \
        custom "" n n n n n y "" y "" "" y \
        n "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Add a proxy on vm-1? (y/n) [n]:"* ]]
    [[ "$stderr" == *"this VM has no component yet, choose again"* ]]
    [ "$(jq -r '[.components[] | select(.vm == "vm-1") | .type] | sort | join(",")' cfg.json)" = "chat-interface,proxy" ]
}

@test "role custom: y then the choice of the component, rank 1 preselected" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y engine \
        custom "" y "" n y "" "" "" y \
        n "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[] | select(.vm == "vm-1") | .name] | sort | join(",")' cfg.json)" = "chat,prox" ]
}

@test "models in every pass that has an engine, each with its vm and engine; m offered only there" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # VM2 (engine role, named eng2): proxy, engine, tls, server-name, port, a model, confirm
    ask "${VM1_ANSWERS[@]}" y engine \
        engine eng2 "" "" "" "" "" m2 y \
        y \
        web "" "" "" "" "" y \
        n "" y
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.models[] | [.name, .vm, .engine]]' cfg.json)" = '[["m1","engine","eng"],["m2","eng2","eng"]]' ]
}

@test "m is offered at the summary of an engine-role pass and not at a web-role one" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # VM2 (engine role): proxy, engine, tls, server-name, port, no model, m (redo models), no
    # model again, confirm. VM3 (web role): proxy, chat, tls, server-name, m (invalid), confirm
    ask "${VM1_ANSWERS[@]}" y engine \
        engine "" "" "" "" "" "" "" m "" y \
        y \
        web "" "" "" "" "" m y \
        n "" y
    [[ "$stderr" == *"redo a step: components (c), options (o), models (m)"* ]]
    [[ "$stderr" == *"redo a step: components (c), options (o)"* ]]
    [[ "$stderr" == *"'m' is not a valid answer"* ]]
}

@test "cancelling after a pass writes nothing" {
    GEN_ARGS=("${PKG[@]}" --output vm.sh)
    ask_script "${VM1_ANSWERS[@]}" y engine web "" "" "" "" "" n
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cancelled, nothing written"* ]]
    [ -z "$(ls vm*.sh 2>/dev/null)" ]
}

@test "the engine role proposes a proxy even with no model: refusing goes back to the components" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y engine \
        engine "" none "" "" "" n "" "" "" "" "" "" y \
        n
    [[ "$stderr" == *"Other VMs reach eng through a proxy (it listens on the loopback only). Add prox? (y/n) [y]:"* ]]
    [[ "$stderr" == *"other VMs could not reach eng without a proxy, choose the components again"* ]]
}

@test "no proxy is proposed for a protected engine, not even on an engine-role pass" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y engine \
        engine "" none prot "" y \
        n
    [[ "$stderr" != *"reaches prot through a proxy"* ]]
    [[ "$stderr" == *"engine prot"* ]]
}

@test "each pass is sized from its own components: a web-role pass has no model and no share of the engine's" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]/m1/}" y engine \
        web "" "" "" "" "" y \
        n "" y
    [ "$status" -eq 0 ]
    [ "$(grep -c 'no recommendation: this package ships no sizing component' <<<"$stderr")" -eq 2 ]
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
    [ "$(embedded vm-engine.sh | jq -c '[.components[] | .name]')" = '["prox","eng"]' ]
    [ "$(embedded vm-web.sh | jq -c '[.components[] | .name]')" = '["prox","chat"]' ]
    [ "$(embedded vm-engine.sh | jq -c '[.components[] | has("vm")] | any')" = "false" ]
    [ "$(embedded vm-engine.sh | jq -c '.models')" = '[{"name":"m1","force":true,"engine":"eng"}]' ]
    [ "$(embedded vm-web.sh | jq 'has("models")')" = "false" ]
    [ "$(embedded vm-engine.sh | jq 'has("links")')" = "false" ]
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
    [[ "$stderr" == *"would write out/vm-engine"*"would write out/vm-web"* ]]
    GEN_ARGS=("${PKG[@]}" --output out/vm)
    ask_script "${TWO_VM_SESSION[@]}"
    [ -x out/vm-engine ] && [ -x out/vm-web ]
}

@test "one script that cannot be written keeps none" {
    GEN_ARGS=("${PKG[@]}" --output nodir/vm.sh)
    ask_script "${TWO_VM_SESSION[@]}"
    [ "$status" -eq 1 ]
    [ ! -e nodir ] && [ -z "$(ls vm*.sh 2>/dev/null)" ]
}

@test "the session of a several-VM stack writes one file, with the vm fields and links" {
    GEN_ARGS=(); OUTFILE=only.json
    ask "${TWO_VM_SESSION[@]}"
    [ -s only.json ]
    [ "$(jq -r '[.components[].vm] | unique | join(",")' only.json)" = "engine,web" ]
    [ "$(jq -c '.links' only.json)" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
}

# --- the links question ---------------------------------------------------------------------------

@test "the links question: refused for an unknown VM, the web VM itself, a VM with no engine, a protected engine" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y engine \
        web "" "" "" "" "" y \
        n ghost web engine y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"no component is on VM"* ]]
    [[ "$stderr" == *"cannot link its own engine"* ]]
    [ "$(jq -c '.links' cfg.json)" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
}

@test "the links default is the other VMs with an engine, or none when the web VM has one of its own" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "${VM1_ANSWERS[@]}" y engine \
        custom "" y "" n y "" "" "" y \
        n "" y
    [[ "$stderr" == *"Which VMs hold the engines whose models vm-1 lists? (names separated by spaces, none) [engine]:"* ]]
}

# --- the proposal of a proxy for a linked engine VM with none ------------------------------------

@test "a linked engine VM with no proxy: the error blocks, nothing is written" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # engine (named "engine"), then chatvm (a chat interface, custom role), then bare (an engine
    # with no proxy, custom role); chatvm is explicitly linked to the unreachable "bare"
    ask "${VM1_ANSWERS[@]}" y engine \
        custom chatvm n n y "" y "" "" y \
        y \
        custom bare n y "" n "" "" y \
        n bare y
    [ "$status" -ne 0 ]
    [ ! -e cfg.json ]
}

# --- a file with vm ----------------------------------------------------------------------------

@test "script on a file with vm gives the scripts of the session and the same configuration" {
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
    [ "$(jq -r '.plan.vms | map(.vm) | join(",")' <<<"$output")" = "engine,web" ]
    [ "$(jq -c '.plan.links' <<<"$output")" = '[{"web_vm":"web","engine_vm":"engine"}]' ]
    jq 'del(.components[0].vm)' f.json >bad.json
    gen bad.json --json "${PKG[@]}" --output k.sh
    [ "$status" -eq 2 ]
    [ "$(jq -c '[.ok, .script, .scripts, .next_steps]' <<<"$output")" = '[false,null,[],[]]' ]
    [ ! -e k-engine.sh ]
}

@test "a model on an engine VM with no proxy is refused before any script is written" {
    two_vm_file f.json
    jq 'del(.components[0])' f.json >np.json
    gen np.json "${PKG[@]}" --output n.sh
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"needs a proxy"* ]]
    [ -z "$(ls n*.sh 2>/dev/null)" ]
}

# --- the next steps ----------------------------------------------------------------------------

@test "two VMs, an engine behind a proxy with a model: the four steps of the administrator, models filled in" {
    two_vm_file f.json
    jq '.models += [{"name": "m2", "force": true, "vm": "engine"}]' f.json >g.json
    gen g.json "${PKG[@]}" --output s.sh
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"What is left to do once the VMs are up:"* ]]
    [[ "$stderr" == *"1. Run each script as root on its VM, the engine VM first."* ]]
    [[ "$stderr" == *"2. On the engine VM, read the API key, the URL of each model and the names"* ]]
    [[ "$stderr" == *"sudo easy-cs-ai component proxy prox show-key"* && "$stderr" == *"easy-cs-ai component proxy prox list-upstreams"* ]]
    [[ "$stderr" == *"3. Let the web VM reach the engine VM on the HTTPS port of its proxy"* ]]
    [[ "$stderr" == *"4. On the web VM, link each model of the engine VM:"* ]]
    [[ "$stderr" == *"add-endpoint engine-m1"*"--model m1 --api-key-file <file>"*"add-endpoint engine-m2"*"--model m2 --api-key-file <file>"* ]]
    [[ "$stderr" == *"sudo easy-cs-ai install proxy prox <the options it was installed with>"* ]]
    [[ "$stderr" == *"Until step 4 is done, the model list of the chat interface stays empty."* ]]
    gen g.json --json "${PKG[@]}" --output s.sh
    [ "$(jq '.next_steps | length' <<<"$output")" -eq 4 ]
    [[ "$(jq -r '.next_steps | join(" ")' <<<"$output")" != *"s-engine.sh"* ]]
    [ "$(jq -r '.next_steps[0]' <<<"$output")" = "Run each script as root on its VM, the engine VM first." ]
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
    jq 'del(.models)' f.json >c1.json
    run --separate-stderr bash "$CLI" config validate c1.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    # no model and no proxy on the engine VM is engine_unreachable: no step at all
    jq 'del(.models) | del(.components[0])' f.json >c2.json
    run --separate-stderr bash "$CLI" config validate c2.json --target fresh --json
    [ "$status" -eq 2 ]
    [ "$(jq -c '.next_steps' <<<"$output")" = "[]" ]
    # a link to a protected engine is link_protected_engine, not a steps link: no step at all
    jq '(.components[] | select(.name == "eng") | .name) = "prot"' f.json | jq '.models[0].engine = "prot"' >c3.json
    run --separate-stderr bash "$CLI" config validate c3.json --target fresh --json
    [ "$status" -eq 2 ]
    [ "$(jq -c '.next_steps' <<<"$output")" = "[]" ]
    # a third VM, properly linked but irrelevant to the pair, changes nothing of its steps
    jq '.components += [{"type": "proxy", "name": "prox", "vm": "extra"}, {"type": "engine", "name": "eng", "vm": "extra"}]
      | .links += [{"web_vm": "web", "engine_vm": "extra"}]' f.json >c4.json
    run --separate-stderr bash "$CLI" config validate c4.json --target fresh --json
    [ "$status" -eq 0 ]
    [ "$(jq '.next_steps | length' <<<"$output")" -eq 4 ]
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false,"description":"certificate"}]' '{"actions":["install","status"]}'
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false,"description":"certificate"}]' '{"actions":["install","status","show-key","list-upstreams"]}'
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --vm engine --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "[]" ]
}

@test "a file with no vm has no next_steps and a one-VM file prints nothing after its script" {
    cat >one.json <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ] }
JSON
    gen one.json --json "${PKG[@]}" --output one.sh
    [ "$(jq 'has("next_steps")' <<<"$output")" = "false" ]
    [ "$(jq -r '.script.path' <<<"$output")" = "one.sh" ]
    [[ "$stderr" != *"What is left to do"* ]]
}

# --- the warnings and errors between the VMs ------------------------------------------------------

@test "engine_address_unknown: a self-signed proxy with no server name, a model, one chat interface VM" {
    two_vm_file f.json
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm]' <<<"$output")" = '["engine"]' ]
    [ "$status" -eq 0 ]
    jq '(.components[0].options) = {"server-name": "llm.example.org"}' f.json >w1.json
    jq '(.components[0].options) = {"tls": "letsencrypt"}' f.json >w2.json
    for f in w1 w2; do
        run --separate-stderr bash "$CLI" config validate $f.json --target fresh --json
        [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
    done
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --vm engine --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
}

@test "engine_unreachable: a linked engine with no proxy and no model" {
    two_vm_file f.json
    jq 'del(.models) | del(.components[0])' f.json >u.json
    run --separate-stderr bash "$CLI" config validate u.json --target fresh --json
    [ "$status" -eq 2 ]
    [ "$(jq -c '[.errors[] | select(.code == "engine_unreachable") | .vm]' <<<"$output")" = '["engine"]' ]
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
    run --separate-stderr bash "$CLI" config validate u.json --target fresh --vm engine --json
    [ "$(jq -c '[.errors[] | select(.code == "engine_unreachable")] | length' <<<"$output")" = 0 ]
    gen u.json "${PKG[@]}" --output u.sh
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"The engine listens on the loopback"* ]]
    [ -z "$(ls u*.sh 2>/dev/null)" ]
}

@test "models_not_checked is judged per VM and shown once, in the summary of the VM that holds the model" {
    two_vm_file f.json
    gen f.json "${PKG[@]}" --output m.sh
    [ "$(grep -c 'models not checked for fit on the VM' <<<"$stderr")" -eq 1 ]
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '[.warnings[] | select(.code == "models_not_checked") | .vm]' <<<"$output")" = '["engine"]' ]
}

@test "the guide names the commands of the next steps" {
    run bash "$CLI" guide
    [ "$status" -eq 0 ]
    for w in "proxy NAME show-key" "proxy NAME list-upstreams" "proxy NAME status" "add-endpoint" "install proxy NAME" "--server-name" '"vm"' "next_steps"; do
        [[ "$output" == *"$w"* ]] || { echo "the guide does not name: $w"; false; }
    done
}

# --- with the shipped scripts ---------------------------------------------------------------

@test "with the shipped scripts the next steps are the four, and name only actions and options that exist" {
    export EASY_CS_AI_HOME="$REAL"
    cat >real.json <<'JSON'
{
  "schema_version": 1,
  "components": [
    { "type": "proxy", "name": "nginx", "vm": "engine" },
    { "type": "engine", "name": "ollama", "vm": "engine" },
    { "type": "proxy", "name": "nginx", "vm": "web" },
    { "type": "chat-interface", "name": "librechat", "vm": "web" }
  ],
  "models": [ { "name": "llama3.2:3b", "force": true, "vm": "engine", "engine": "ollama" } ],
  "links": [ { "web_vm": "web", "engine_vm": "engine" } ]
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
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm]' <<<"$(bash "$CLI" config validate real.json --target fresh --json)")" = '["engine"]' ]
}

@test "the command of step 4 is on two lines: a backslash, then a real new line" {
    two_vm_file f.json
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    step4="$(jq -r '.next_steps[3]' <<<"$output")"
    [[ "$step4" != *'\n'* ]]
    grep -qxF '  sudo easy-cs-ai component chat-interface chat add-endpoint engine-m1 <url> \' <<<"$step4"
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
    # VM1 (plain, named "engine"): llmfit, proxy, engine, no chat-interface, hardware first, no
    # spec, no model. VM2 (engine role, "engine-2"): same, but 16 GB RAM, no GPU and 4 cores.
    # VM3 (web role): proxy and chat-interface, linked to both engine VMs (the default)
    ask "" "" "" none "" "" "" "" "" "" "" "" y \
        y engine \
        engine "" "" "" "" "" "" "" "" 16 "" 4 "" y \
        y \
        web "" "" "" "" "" y \
        n "" y
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
    ask "" "" "" none "" "" "" m "m1, m2" y \
        y engine \
        web "" "" "" "" "" y \
        n "" y
    [ "$status" -eq 0 ]
    grep -qx 'plan m1@eng m2@eng --component provisioning/llmfit --component proxy/prox --component engine/eng' "$CALLS"
    [ "$(jq -c '.models | map([.name, .vm, .engine])' cfg.json)" = '[["m1","engine","eng"],["m2","engine","eng"]]' ]
}

# --- a file that names one VM only ---------------------------------------------------------------

@test "a file that names one VM only takes the path of several: a script named after the VM, its header, scripts with one entry" {
    cat >one.json <<'JSON'
{ "schema_version": 1, "components": [ { "type": "proxy", "name": "prox", "vm": "a" }, { "type": "engine", "name": "eng", "vm": "a" } ] }
JSON
    gen one.json --json "${PKG[@]}" --output o.sh
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.script, (.scripts | map(.vm)), (.scripts | map(.path)), .next_steps]' <<<"$output")" = '[null,["a"],["o-a.sh"],[]]' ]
    grep -q '^# VM: a (1 of 1)$' o-a.sh
    [ ! -e o.sh ]
    [ "$(embedded o-a.sh | jq -c '[.components[] | has("vm")] | any')" = "false" ]
    run --separate-stderr bash "$CLI" config validate one.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "[]" ]
    run --separate-stderr bash "$CLI" apply one.json --dry-run
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"select one with --vm"* ]]
}

@test "the same file without its vm fields gives today's script, with no VM line" {
    cat >one.json <<'JSON'
{ "schema_version": 1, "components": [ { "type": "proxy", "name": "prox", "vm": "a" }, { "type": "engine", "name": "eng", "vm": "a" } ] }
JSON
    jq 'del(.components[].vm)' one.json >none.json
    gen none.json "${PKG[@]}" --output n.sh
    [ "$status" -eq 0 ]
    [ -x n.sh ]
    [ -z "$(grep '^# VM:' n.sh)" ]
    gen one.json "${PKG[@]}" --output o.sh
    diff <(embedded n.sh | jq -S .) <(embedded o-a.sh | jq -S .)
    diff <(grep -v '^# VM:\|^# easy-cs-ai VM' n.sh) <(grep -v '^# VM:\|^# easy-cs-ai VM' o-a.sh)
}

# --- engine_address_unknown, the cases that do not give it -------------------------------------

@test "engine_address_unknown is not given for a protected engine, for an unreached VM, or when no model is on the engine VM" {
    two_vm_file f.json
    jq '(.components[] | select(.name == "eng") | .name) = "prot" | .models[0].engine = "prot"' f.json >p.json
    run --separate-stderr bash "$CLI" config validate p.json --target fresh --json
    [ "$status" -eq 2 ]
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
    # an engine VM that no link targets (linked only as a web_vm elsewhere) is not checked either
    jq '.components += [{"type": "proxy", "name": "prox", "vm": "extra"}, {"type": "engine", "name": "eng", "vm": "extra"}]
      | .links += [{"web_vm": "extra", "engine_vm": "engine"}]' f.json >t.json
    run --separate-stderr bash "$CLI" config validate t.json --target fresh --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm] | sort' <<<"$output")" = '["engine"]' ]
    jq 'del(.models)' f.json >m.json
    run --separate-stderr bash "$CLI" config validate m.json --target fresh --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
}
