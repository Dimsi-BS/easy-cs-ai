#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Two VMs, the engine and the web interface apart (docs/spec-two-vm.md): the question of the
# session, a pass per VM, one script per VM, the next steps, the warnings between the VMs.
#
# Fake scripts shipped (only describe answers): proxy prox with the actions and the options of the
# real nginx that matter here (tls), engine eng (option port), protected engine prot, chat-interface
# chat (requires the type proxy) with the options of add-endpoint.

SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
    GEN="${BATS_TEST_DIRNAME}/../../vm_script/generate.sh"
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

gen() { run --separate-stderr bash "$GEN" "$@"; }
# ask <answers…>: the generator with one answer per line on stdin; the first one answers the VM question
ask() {
    ANSWERS="$(printf '%s\n' "$@")"
    export ANSWERS
    run --separate-stderr bash -c 'bash "$0" "${@:1}" <<<"$ANSWERS"' "$GEN" "${GEN_ARGS[@]}"
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
  "models": [ { "name": "m1", "force": true, "vm": "engine", "engine": "eng" } ]
}
JSON
}

# The answers of a split session, every one the default but the model: the engine VM (its proxy and
# the options of it, its engine and its port, a model, the confirmation) then the web VM (its proxy
# and its options, its interface, the confirmation).
ENGINE_PASS=("" "" "" "" "" m1 y)
ENGINE_NOMODEL=("" "" "" "" "" "" y)
WEB_PASS=("" "" "" "" y)

# --- the question and the passes ---------------------------------------------------------------

@test "the VM question is asked first, one VM is the default and the session runs as before" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask "" none eng none "" "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"One VM for everything (1), or the web interface on a second VM, apart from the inference engine (2)? [1]"* ]]
    [ "$(jq -c '.components' cfg.json)" = '[{"type":"engine","name":"eng"}]' ]
    ask 3 1 none eng none "" "" y
    [[ "$stderr" == *"'3' is not 1 or 2"* ]]
    [ "$status" -eq 0 ]
}

@test "the question is not asked when nothing can be split" {
    rm "$EASY_CS_AI_HOME/chat-interface/chat.sh"
    GEN_ARGS=(--config-only --output cfg.json)
    ask none eng "" "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"One VM for everything"* ]]
    [ "$(jq -c '.components | map(.name)' cfg.json)" = '["eng"]' ]
}

@test "answer 2 runs the steps twice and writes one configuration with the vm of each component" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.components[] | [.vm, .type, .name]]' cfg.json)" = '[["engine","proxy","prox"],["engine","engine","eng"],["web","proxy","prox"],["web","chat-interface","chat"]]' ]
    # the model is the engine VM's, with its engine
    [ "$(jq -c '.models' cfg.json)" = '[{"name":"m1","force":true,"vm":"engine","engine":"eng"}]' ]
    # a nginx on each VM
    [ "$(jq -r '[.components[] | select(.type == "proxy") | .vm] | join(",")' cfg.json)" = "engine,web" ]
    # one summary per pass
    [ "$(grep -c '^Summary' <<<"$stderr")" -eq 2 ]
    [[ "$stderr" == *"VM engine"*"VM web"* ]]
    bash "$CLI" config validate cfg.json --target fresh --json | jq -e '.ok'
}

@test "m is offered at the summary of the engine VM and not at the one of the web VM" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask 2 "${ENGINE_PASS[@]}" "" "" "" "" m y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"redo a step: components (c), options (o), models (m)"* ]]
    [[ "$stderr" == *"redo a step: components (c), options (o)"* ]]
    [[ "$stderr" == *"'m' is not a valid answer"* ]]
}

@test "cancelling after the first pass writes nothing" {
    GEN_ARGS=("${PKG[@]}" --output vm.sh)
    ask 2 "${ENGINE_PASS[@]}" "" "" "" "" n
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cancelled, nothing written"* ]]
    [ -z "$(ls vm*.sh 2>/dev/null)" ]
    ask 2 "" "" "" "" "" m1 n
    [ "$status" -eq 0 ]
    [ -z "$(ls vm*.sh 2>/dev/null)" ]
}

@test "a pass must select the component that defines its VM: none is refused and asked again" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask 2 "" none "" "" "" "" m1 y "" none "" "" "" y
    [ "$status" -eq 0 ]
    [ "$(grep -c 'is defined by its engine' <<<"$stderr")" -eq 1 ]
    [ "$(grep -c 'is defined by its chat-interface' <<<"$stderr")" -eq 1 ]
    [ "$(jq -r '[.components[] | .type] | join(",")' cfg.json)" = "proxy,engine,proxy,chat-interface" ]
}

@test "the engine VM needs a proxy even with no model: refusing it goes back to the components of that VM" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask 2 none "" "" "" n "" "" "" "" "" "" y "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"The web VM reaches eng through a proxy (it listens on the loopback only). Add prox? (y/n) [y]"* ]]
    [[ "$stderr" == *"the web VM could not reach eng without a proxy, choose the components again"* ]]
    [ "$(jq -r '[.components[] | select(.vm == "engine") | .type] | join(",")' cfg.json)" = "proxy,engine" ]
    # no engine_unreachable at the end of a session
    [[ "$stderr" != *"nothing exposes it"* ]]
    # accepting it adds nginx to the VM and asks its options
    ask 2 none "" "" "" y "" "" y "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.components[] | select(.vm == "engine") | .type] | join(",")' cfg.json)" = "proxy,engine" ]
}

@test "no proxy is proposed for a protected engine, not even on the engine VM" {
    make_fake engine eng '[]' '[{"name":"port","default":"11434","secret":false,"description":"Listening port"}]' '{"endpoint":{"protected":true}}'
    GEN_ARGS=(--config-only --output cfg.json)
    ask 2 none "" "" "" y "${WEB_PASS[@]}"
    [[ "$stderr" != *"reaches eng through a proxy"* ]]
    [ "$(jq -r '[.components[] | select(.vm == "engine") | .type] | join(",")' cfg.json)" = "engine" ]
}

@test "each pass is sized from its own components: the web VM has no model and no share of the engine's" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask 2 "${ENGINE_NOMODEL[@]}" "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    # no sizing component is shipped here: each VM with no model says so
    [ "$(grep -c 'no recommendation: this package ships no sizing component' <<<"$stderr")" -eq 2 ]
}

# --- one script per VM ---------------------------------------------------------------------------

@test "a session of two VMs writes one script per VM, named from --output, each with its slice and its header" {
    GEN_ARGS=("${PKG[@]}" --output vm.sh)
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    [ -x vm-engine.sh ] && [ -x vm-web.sh ]
    [ ! -e vm.sh ]
    grep -q '^# VM: engine (1 of 2)$' vm-engine.sh
    grep -q '^# VM: web (2 of 2)$' vm-web.sh
    [ "$(embedded vm-engine.sh | jq -c '[.components[] | .name]')" = '["prox","eng"]' ]
    [ "$(embedded vm-web.sh | jq -c '[.components[] | .name]')" = '["prox","chat"]' ]
    # a slice has no vm, models are with the engine VM with the engine filled in
    [ "$(embedded vm-engine.sh | jq -c '[.components[] | has("vm")] | any')" = "false" ]
    [ "$(embedded vm-engine.sh | jq -c '.models')" = '[{"name":"m1","force":true,"engine":"eng"}]' ]
    [ "$(embedded vm-web.sh | jq 'has("models")')" = "false" ]
    bash -n vm-engine.sh && bash -n vm-web.sh
    [[ "$stderr" == *"Two scripts written, one per VM:"*"vm-engine.sh   VM engine"*"vm-web.sh   VM web"* ]]
}

@test "without --output the scripts are ./easy-cs-ai-vm-engine.sh and ./easy-cs-ai-vm-web.sh" {
    GEN_ARGS=("${PKG[@]}")
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    [ -x easy-cs-ai-vm-engine.sh ] && [ -x easy-cs-ai-vm-web.sh ]
}

@test "--dry-run writes nothing and prints every script, --output with no extension appends the VM" {
    GEN_ARGS=("${PKG[@]}" --output out/vm --dry-run)
    mkdir out
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    [ -z "$(ls out)" ]
    [[ "$stderr" == *"would write out/vm-engine"*"would write out/vm-web"* ]]
    GEN_ARGS=("${PKG[@]}" --output out/vm)
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ -x out/vm-engine ] && [ -x out/vm-web ]
}

@test "one script that cannot be written keeps none" {
    GEN_ARGS=("${PKG[@]}" --output nodir/vm.sh)
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ "$status" -eq 1 ]
    [ ! -e nodir ] && [ -z "$(ls vm*.sh 2>/dev/null)" ]
}

@test "--config-only of a split stack writes one file, with the vm fields" {
    GEN_ARGS=(--config-only --output only.json)
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ -s only.json ]
    [ "$(jq -r '[.components[].vm] | unique | join(",")' only.json)" = "engine,web" ]
}

# --- a file with vm ----------------------------------------------------------------------------

@test "--config on a file with vm gives the scripts of the session and the same configuration" {
    two_vm_file f.json
    gen --config f.json "${PKG[@]}" --output file.sh
    [ "$status" -eq 0 ]
    file_err="$stderr"
    GEN_ARGS=("${PKG[@]}" --output ses.sh)
    ask 2 "${ENGINE_PASS[@]}" "${WEB_PASS[@]}"
    [ "$status" -eq 0 ]
    # the session of two VMs and the hand-written file give the same slices
    diff <(embedded file-engine.sh | jq -S .) <(embedded ses-engine.sh | jq -S .)
    diff <(embedded file-web.sh | jq -S .) <(embedded ses-web.sh | jq -S .)
    diff <(grep -v '^# easy-cs-ai VM' file-engine.sh) <(grep -v '^# easy-cs-ai VM' ses-engine.sh)
    # no prompt, a summary per VM on stderr
    [[ "$file_err" != *"Confirm ("* ]]
    [[ "$file_err" == *"VM engine"*"VM web"* ]]
}

@test "--config --json: script is null, scripts has one entry per VM, next_steps the instructions" {
    two_vm_file f.json
    gen --config f.json --json "${PKG[@]}" --output j.sh
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.ok, .script, (.scripts | map(.vm)), (.scripts | map(.path)), (.scripts | map(.written))]' <<<"$output")" = '[true,null,["engine","web"],["j-engine.sh","j-web.sh"],[true,true]]' ]
    [ "$(jq '.next_steps | length' <<<"$output")" -eq 4 ]
    [ "$(jq -r '.plan.vms | map(.vm) | join(",")' <<<"$output")" = "engine,web" ]
    # an invalid file: the errors, no script, no step
    jq 'del(.components[0].vm)' f.json >bad.json
    gen --config bad.json --json "${PKG[@]}" --output k.sh
    [ "$status" -eq 2 ]
    [ "$(jq -c '[.ok, .script, .scripts, .next_steps]' <<<"$output")" = '[false,null,[],[]]' ]
    [ ! -e k-engine.sh ]
}

@test "a model on an engine VM with no proxy is refused before any script is written" {
    two_vm_file f.json
    jq 'del(.components[0])' f.json >np.json
    gen --config np.json "${PKG[@]}" --output n.sh
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"needs a proxy"* ]]
    [ -z "$(ls n*.sh 2>/dev/null)" ]
}

# --- the next steps ----------------------------------------------------------------------------

@test "two VMs, an engine behind a proxy with a model: the four steps of the administrator, models filled in" {
    two_vm_file f.json
    jq '.models += [{"name": "m2", "force": true, "vm": "engine"}]' f.json >g.json
    gen --config g.json "${PKG[@]}" --output s.sh
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"What is left to do once the VMs are up:"* ]]
    [[ "$stderr" == *"1. Run each script as root on its VM, the engine VM first."* ]]
    [[ "$stderr" == *"2. On the engine VM, read the API key, the URL of each model and the names"* ]]
    [[ "$stderr" == *"sudo easy-cs-ai proxy prox show-key"* && "$stderr" == *"easy-cs-ai proxy prox list-upstreams"* ]]
    [[ "$stderr" == *"3. Let the web VM reach the engine VM on the HTTPS port of its proxy"* ]]
    [[ "$stderr" == *"4. On the web VM, link each model:"* ]]
    # one add-endpoint per model, with its name
    [[ "$stderr" == *"add-endpoint <name> <url> \\"*"--model m1 --api-key-file <file>"*"--model m2 --api-key-file <file>"* ]]
    [[ "$stderr" == *"sudo easy-cs-ai install proxy prox <the options it was installed with>"* ]]
    [[ "$stderr" == *"Until step 4 is done, the model list of the chat interface stays empty."* ]]
    # the strings of next_steps are the text, one per step, with no numbering and no script name
    gen --config g.json --json "${PKG[@]}" --output s.sh
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
    gen --config f.json --json "${PKG[@]}" --output t.sh
    [ "$(jq -c '.next_steps' <<<"$output")" = "$(jq -c '.next_steps' <<<"$doc")" ]
    run --separate-stderr bash "$CLI" config validate f.json --target fresh
    [[ "$stderr" == *"What is left to do once the VMs are up:"* ]]
}

@test "step 1 alone when a condition of the steps 2 to 4 is broken, one case per condition" {
    two_vm_file f.json
    one='["Run each script as root on its VM."]'
    # no model on the engine VM
    jq 'del(.models)' f.json >c1.json
    run --separate-stderr bash "$CLI" config validate c1.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    # no proxy on the engine VM (no model either: it is the engine_unreachable case)
    jq 'del(.models) | del(.components[0])' f.json >c2.json
    run --separate-stderr bash "$CLI" config validate c2.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    # a protected engine
    jq '(.components[] | select(.name == "eng") | .name) = "prot"' f.json | jq '.models[0].engine = "prot"' >c3.json
    run --separate-stderr bash "$CLI" config validate c3.json --target fresh --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    # a third VM, even one with neither
    jq '.components += [{"type": "proxy", "name": "prox", "vm": "extra"}]' f.json >c4.json
    run --separate-stderr bash "$CLI" config validate c4.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    # a package whose scripts do not declare the actions: never a command that fails
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false,"description":"certificate"}]' '{"actions":["install","status"]}'
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "$one" ]
    # a validation of one slice gives no step
    make_fake proxy prox '[]' '[{"name":"tls","default":"self-signed","secret":false,"description":"certificate"}]' '{"actions":["install","status","show-key","list-upstreams"]}'
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --vm engine --json
    [ "$(jq -c '.next_steps' <<<"$output")" = "[]" ]
}

@test "a file with no vm has no next_steps and a one-VM file prints nothing after its script" {
    cat >one.json <<'JSON'
{ "schema_version": 1, "components": [ { "type": "engine", "name": "eng" } ] }
JSON
    gen --config one.json --json "${PKG[@]}" --output one.sh
    [ "$(jq 'has("next_steps")' <<<"$output")" = "false" ]
    [ "$(jq -r '.script.path' <<<"$output")" = "one.sh" ]
    [[ "$stderr" != *"What is left to do"* ]]
}

# --- the warnings between the VMs ------------------------------------------------------------

@test "engine_address_unknown: a self-signed proxy with no server name, a model, one chat interface VM" {
    two_vm_file f.json
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm]' <<<"$output")" = '["engine"]' ]
    [ "$status" -eq 0 ]
    # a server name written, a tls that is not self-signed, a validation of one slice: no warning
    jq '(.components[0].options) = {"server-name": "llm.example.org"}' f.json >w1.json
    jq '(.components[0].options) = {"tls": "letsencrypt"}' f.json >w2.json
    for f in w1 w2; do
        run --separate-stderr bash "$CLI" config validate $f.json --target fresh --json
        [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
    done
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --vm engine --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
}

@test "engine_unreachable: an engine with no proxy, no model, and a chat interface on another VM" {
    two_vm_file f.json
    jq 'del(.models) | del(.components[0])' f.json >u.json
    run --separate-stderr bash "$CLI" config validate u.json --target fresh --json
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.warnings[] | select(.code == "engine_unreachable") | .vm]' <<<"$output")" = '["engine"]' ]
    # never both with engine_address_unknown, and it is not given for one slice
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown")] | length' <<<"$output")" = 0 ]
    run --separate-stderr bash "$CLI" config validate u.json --target fresh --vm engine --json
    [ "$(jq -c '[.warnings[] | select(.code == "engine_unreachable")] | length' <<<"$output")" = 0 ]
    # the last summary of a file lists them after its own
    gen --config u.json "${PKG[@]}" --output u.sh
    [[ "$stderr" == *"between the VMs"*"[VM engine] The engine listens on the loopback"* ]]
}

@test "models_not_checked is judged per VM and shown once, in the summary of the VM that holds the model" {
    two_vm_file f.json
    gen --config f.json "${PKG[@]}" --output m.sh
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
  "models": [ { "name": "llama3.2:3b", "force": true, "vm": "engine", "engine": "ollama" } ]
}
JSON
    run --separate-stderr bash "$CLI" config validate real.json --target fresh --json
    [ "$status" -eq 0 ]
    [ "$(jq '.next_steps | length' <<<"$output")" -eq 4 ]
    text="$(jq -r '.next_steps | join("\n")' <<<"$output")"
    [[ "$text" == *"easy-cs-ai proxy nginx list-upstreams"* && "$text" == *"chat-interface librechat add-endpoint"* ]]
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
    # and the address warning, since nothing says the name of the engine VM yet
    [ "$(jq -c '[.warnings[] | select(.code == "engine_address_unknown") | .vm]' <<<"$(bash "$CLI" config validate real.json --target fresh --json)")" = '["engine"]' ]
}

@test "the command of step 4 is on two lines: a backslash, then a real new line" {
    two_vm_file f.json
    run --separate-stderr bash "$CLI" config validate f.json --target fresh --json
    step4="$(jq -r '.next_steps[3]' <<<"$output")"
    # not the two characters \ and n
    [[ "$step4" != *'\n'* ]]
    grep -qxF '  sudo easy-cs-ai chat-interface chat add-endpoint <name> <url> \' <<<"$step4"
    grep -qx '    --model m1 --api-key-file <file>' <<<"$step4"
    grep -qx '    --server-name <name or address>' <<<"$step4"
}
