#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Fake components: engine/eng, engine/eng2, proxy/prox, chat-interface/chat
# (chat requires the type proxy, prox requires nothing). Every call is logged
# in $CALLS; state is written with the real helpers.

setup() {
    CLI="${BATS_TEST_DIRNAME}/../../package/bin/easy-cs-ai"
    REAL="${BATS_TEST_DIRNAME}/../../install_scripts"
    export EASY_CS_AI_HOME="$BATS_TEST_TMPDIR/home"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    export CALLS="$BATS_TEST_TMPDIR/calls"
    STATE="$EASY_CS_AI_ROOT/var/lib/easy-cs-ai"
    unset EASY_CS_AI_LOCK_HELD FAKE_FAIL FAKE_HEALTHY
    mkdir -p "$EASY_CS_AI_HOME"/{engine,proxy,chat-interface,provisioning}
    ln -s "$REAL/lib" "$EASY_CS_AI_HOME/lib"
    printf 'engine eng\nengine eng2\nproxy prox\nchat-interface chat\n' >"$EASY_CS_AI_HOME/ranks.conf"
    make_fake engine eng '[]'
    make_fake engine eng2 '[]'
    make_fake proxy prox '[]'
    make_fake chat-interface chat '["proxy"]'
    : >"$CALLS"
}

# make_fake <type> <name> <requires-json>
make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<EOF
#!/usr/bin/env bash
source "\$EASY_CS_AI_LIB/common.sh"
action="\$1"; shift
echo "$2 \$action \$*" >>"\$CALLS"
case "\$action" in
describe) jq -n '{name: "$2", type: "$1", requires: $3, actions: ["install", "uninstall", "status", "describe", "add-model", "list-models", "check", "size", "add-upstream", "remove-upstream", "add-endpoint", "remove-endpoint"], native: {command: "echo", env: {FAKE_HOST: "{bind}:{port}"}}}' ;;
install)
    [[ "\${FAKE_FAIL:-}" == "$2" ]] && exit 5
    state_write $2 '{"name":"$2","type":"$1","version":"1.0","requires":$3,"params":{"bind":"127.0.0.1","port":"1234"},"models":[]}' ;;
uninstall)
    if [[ " \$* " != *" --force "* ]]; then
        for o in \$(state_list); do
            [[ "\$o" != "$2" ]] && state_read "\$o" | jq -e '(.requires // []) | any(. == "$2" or . == "$1")' >/dev/null && exit 4
        done
    fi
    state_remove $2 ;;
status)
    h=true; [[ "\${FAKE_HEALTHY:-}" == "$2" ]] && h=false
    jq -n --argjson h \$h '{name: "$2", installed: true, running: true, healthy: \$h}'; [[ \$h == true ]] || exit 6 ;;
add-model)
    [[ "\${FAKE_FAIL:-}" == "$2-add-model" ]] && exit 5
    state_write $2 "\$(state_read $2 | jq --arg m "\$1" '{name, type, models: ((.models // []) + [{name: \$m}])}')" ;;
check) echo '{"fits": true}' ;;
add-endpoint|add-upstream) echo '{"url": "http://x"}' ;;
remove-upstream|remove-endpoint) ;;
esac
EOF
}

cli() { run --separate-stderr bash "$CLI" "$@"; }

installed() { [ -f "$STATE/components/$1.json" ]; }

# --- basics ---------------------------------------------------------------------------

@test "no argument prints the usage and exits 2; help and version succeed" {
    cli
    [ "$status" -eq 2 ]
    cli help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: easy-cs-ai"* ]]
    cli --version
    [ "$output" = "0.1.0-rc1" ]
}

@test "unknown command and unknown type are usage errors" {
    cli frobnicate
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown command 'frobnicate'"* ]]
    cli install plugin x
    [ "$status" -eq 2 ]
}

@test "a type alone lists its shipped components" {
    cli engine
    [ "$status" -eq 0 ]
    [[ "$output" == *$'eng\tnot installed'* ]]
    cli install engine eng
    cli engine
    [[ "$output" == *$'eng\tinstalled'* ]]
}

# --- install --------------------------------------------------------------------------

@test "install runs the script with its options and passes the exit code" {
    cli install engine eng --port 99
    [ "$status" -eq 0 ]
    installed eng
    grep -q 'eng install --port 99' "$CALLS"
    FAKE_FAIL=eng2 cli install engine eng2
    [ "$status" -eq 5 ]
}

@test "install without a name, or without --defaults, is a usage error" {
    cli install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--defaults"* ]]
    cli install engine
    [ "$status" -eq 2 ]
}

@test "install fails with exit 4 and the command to run when a requirement is missing" {
    cli install chat-interface chat
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"prox is required by chat"* ]]
    [[ "$stderr" == *"easy-cs-ai install proxy prox"* ]]
    ! installed chat
}

@test "install --defaults installs the requirement first" {
    cli install chat-interface chat --defaults
    [ "$status" -eq 0 ]
    installed prox
    installed chat
    [[ "$stderr" == *"installing prox (required by chat)"* ]]
    [ "$(grep -n 'install' "$CALLS" | head -1 | grep -c prox)" -eq 1 ]
}

@test "install <type> --defaults installs the rank 1 component" {
    cli install engine --defaults
    [ "$status" -eq 0 ]
    installed eng
    ! installed eng2
}

@test "install --defaults installs the default stack and converges" {
    cli install --defaults
    [ "$status" -eq 0 ]
    installed eng
    installed prox
    installed chat
    : >"$CALLS"
    cli install --defaults
    [ "$status" -eq 0 ]
    ! grep -q ' install' "$CALLS"
}

# with_fit_stack: the default model is added with `add --defaults`, which needs llmfit.
with_fit_stack() {
    make_fake provisioning fit '[]'
    printf 'provisioning fit\n' >>"$EASY_CS_AI_HOME/ranks.conf"
    printf 'eng llama-test\n' >"$EASY_CS_AI_HOME/default-models.conf"
}

@test "install --defaults adds the default model of the engine it installed, once" {
    with_fit_stack
    cli install --defaults
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"default model llama-test to eng"* ]]
    grep -q '^eng add-model llama-test' "$CALLS"
    : >"$CALLS"
    cli install --defaults
    [ "$status" -eq 0 ]
    run ! grep -q 'add-model' "$CALLS"
}

@test "install --defaults only warns when the default model cannot be added" {
    with_fit_stack
    export FAKE_FAIL=eng-add-model
    cli install --defaults
    [ "$status" -eq 0 ]
    installed chat
    [[ "$stderr" == *"default model llama-test not added to eng"* ]]
}

@test "install --defaults without a default model for the engine adds none" {
    cli install --defaults
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"no default model known for eng"* ]]
}

@test "install --dry-run --defaults announces the default model" {
    printf 'eng llama-test\n' >"$EASY_CS_AI_HOME/default-models.conf"
    cli --dry-run install --defaults
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"would add llama-test to eng"* ]]
}

@test "install --dry-run installs nothing" {
    cli --dry-run install chat-interface chat --defaults
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"would install chat-interface chat"* ]]
    ! installed chat
    ! installed prox
}

# --- status ---------------------------------------------------------------------------

@test "status of an empty machine prints the header, a hint and exits 0" {
    cli status
    [ "$status" -eq 0 ]
    [[ "$output" == COMPONENT* ]]
    [[ "$stderr" == *"nothing installed"* ]]
}

@test "status lists components and exits 6 when one is unhealthy" {
    cli install --defaults
    cli status
    [ "$status" -eq 0 ]
    [[ "$output" == *"eng"*"engine"*"1.0"*"yes"* ]]
    FAKE_HEALTHY=prox cli status
    [ "$status" -eq 6 ]
}

@test "status --json is an array sorted by type then name" {
    cli install --defaults
    cli --json status
    run jq -r 'map(.name) | join(",")' <<<"$output"
    [ "$output" = "chat,eng,prox" ]
}

@test "status shows an unreadable state with ? and exits 1" {
    cli install engine eng
    echo '{broken' >"$STATE/components/eng.json"
    cli status
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"cannot be read"* ]]
    [[ "$output" == *"?"* ]]
}

@test "status warns about a failed install left as a manifest" {
    mkdir -p "$STATE/pending"
    echo '{"name":"eng","type":"engine"}' >"$STATE/pending/eng.json"
    cli status
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"eng: failed install pending, run: easy-cs-ai uninstall engine eng"* ]]
}

# --- uninstall ------------------------------------------------------------------------

@test "uninstall runs the script; refusal lists the dependents" {
    cli install chat-interface chat --defaults
    cli uninstall proxy prox
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"required by: chat"* ]]
    installed prox
    cli uninstall chat-interface chat
    [ "$status" -eq 0 ]
    ! installed chat
}

@test "uninstall without a name, with --defaults, or --all plus a name is a usage error" {
    cli uninstall
    [ "$status" -eq 2 ]
    cli uninstall engine
    [ "$status" -eq 2 ]
    cli uninstall engine --defaults
    [ "$status" -eq 2 ]
    cli uninstall engine eng --all
    [ "$status" -eq 2 ]
}

@test "uninstall --all removes dependents first and everything" {
    cli install --defaults
    : >"$CALLS"
    cli uninstall --all
    [ "$status" -eq 0 ]
    ! installed eng
    ! installed prox
    ! installed chat
    run grep -n uninstall "$CALLS"
    chat_line="$(grep -n 'chat uninstall' "$CALLS" | cut -d: -f1)"
    prox_line="$(grep -n 'prox uninstall' "$CALLS" | cut -d: -f1)"
    [ "$chat_line" -lt "$prox_line" ]
}

@test "uninstall <type> --all is limited to the type; nothing to remove exits 0" {
    cli install --defaults
    cli uninstall engine --all
    [ "$status" -eq 0 ]
    ! installed eng
    installed prox
    cli uninstall engine --all
    [ "$status" -eq 0 ]
}

@test "uninstall --all --dry-run lists the order and removes nothing" {
    cli install --defaults
    cli --dry-run uninstall --all
    [ "$status" -eq 0 ]
    [[ "$stderr" == "[INFO] plan: uninstall chat-interface chat"* ]]
    installed eng
}

@test "uninstall --all cleans a failed install left as a manifest, last" {
    cli install engine eng
    mkdir -p "$STATE/pending"
    echo '{"name":"eng2","type":"engine"}' >"$STATE/pending/eng2.json"
    : >"$CALLS"
    cli uninstall --all
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$CALLS")" = "eng2 uninstall " ]
}

@test "uninstalling an engine unwires its models, best effort" {
    cli install engine eng
    cli install proxy prox
    jq '.models = [{"name":"Llama3.2:3b","exposed_via":"prox","linked_to":[]}]' "$STATE/components/eng.json" >"$BATS_TEST_TMPDIR/e.json"
    cp "$BATS_TEST_TMPDIR/e.json" "$STATE/components/eng.json"
    cli uninstall engine eng
    [ "$status" -eq 0 ]
    grep -q 'prox remove-upstream eng-llama3.2-3b' "$CALLS"
}

@test "uninstalling a proxy clears it from the engine models" {
    cli install engine eng
    cli install proxy prox
    jq '.models = [{"name":"m","exposed_via":"prox","linked_to":[]}]' "$STATE/components/eng.json" >"$BATS_TEST_TMPDIR/e.json"
    cp "$BATS_TEST_TMPDIR/e.json" "$STATE/components/eng.json"
    cli uninstall proxy prox
    [ "$(jq -r '.models[0].exposed_via' "$STATE/components/eng.json")" = "null" ]
}

# --- component commands ---------------------------------------------------------------

@test "a contract action is forwarded with its arguments" {
    cli install engine eng
    cli engine eng list-models --json
    [ "$status" -eq 0 ]
    grep -q 'eng list-models --json' "$CALLS"
}

@test "size is a contract action: forwarded to the script, not to the component's own program" {
    cli install engine eng
    cli engine eng size m1
    [ "$status" -eq 0 ]
    grep -q 'eng size m1' "$CALLS"
    # the native program of the fake is `echo`: it would have printed the arguments
    [ "$output" != "size m1" ]
}

@test "global options are forwarded to the script" {
    cli --verbose install engine eng
    grep -q 'eng install --verbose' "$CALLS"
}

@test "exec runs the component's program with its arguments untouched and the recorded environment" {
    cli install engine eng
    cli exec engine eng hello world
    [ "$status" -eq 0 ]
    [ "$output" = "hello world" ]
    cli exec engine eng status
    [ "$output" = "status" ]
    cli exec engine eng -t
    [ "$output" = "-t" ]
}

@test "exec exports describe.native.env" {
    cli install engine eng
    sed -i 's/command: "echo"/command: "printenv"/' "$EASY_CS_AI_HOME/engine/eng.sh"
    cli exec engine eng FAKE_HOST
    [ "$output" = "127.0.0.1:1234" ]
}

@test "exec shows the resolved command with --verbose and plans it with --dry-run" {
    cli install engine eng
    cli --verbose exec engine eng hello
    [ "$output" = "hello" ]
    [[ "$stderr" == *"exec: FAKE_HOST=127.0.0.1:1234 echo hello"* ]]
    cli --dry-run exec engine eng hello
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"plan: exec FAKE_HOST=127.0.0.1:1234 echo hello"* ]]
}

@test "exec refusals: usage errors exit 2, a missing install or program exits 4" {
    cli exec
    [ "$status" -eq 2 ]
    cli exec engine
    [ "$status" -eq 2 ]
    cli exec engine eng
    [ "$status" -eq 2 ]
    cli exec plugin eng ps
    [ "$status" -eq 2 ]
    cli exec engine nope ps
    [ "$status" -eq 2 ]
    cli exec engine eng hello
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"not installed"* ]]
    cli install engine eng
    cli --json exec engine eng hello
    [ "$status" -eq 2 ]
    sed -i 's/command: "echo"/command: "no-such-program"/' "$EASY_CS_AI_HOME/engine/eng.sh"
    cli exec engine eng hello
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"no-such-program is not found"* ]]
    sed -i "s/, native: .*}}}'/}'/" "$EASY_CS_AI_HOME/engine/eng.sh"
    cli exec engine eng hello
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no program of its own"* ]]
}

@test "a word that is no action is a usage error pointing to exec, with or without --" {
    cli install engine eng
    cli engine eng hello world
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown action 'hello'"* && "$stderr" == *"actions: install uninstall"* && "$stderr" == *"exec engine eng hello"* ]]
    cli engine eng -- status
    [ "$status" -eq 2 ]
    cli engine eng -t
    [ "$status" -eq 2 ]
}

@test "an action added to describe is accepted without a change of the CLI" {
    cli install engine eng
    sed -i 's/"size",/"size", "brand-new",/' "$EASY_CS_AI_HOME/engine/eng.sh"
    cli engine eng brand-new x
    [ "$status" -eq 0 ]
    grep -q 'eng brand-new x' "$CALLS"
}

@test "an unknown component name is a usage error listing the choices" {
    cli engine nope list-models
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"available: eng eng2"* ]]
}

@test "install --defaults reads CRLF data files without a stray CR in the model name" {
    with_fit_stack
    printf 'eng llama-test\r\n' >"$EASY_CS_AI_HOME/default-models.conf"
    cli install --defaults
    [ "$status" -eq 0 ]
    grep -qx 'eng add-model llama-test.*' "$CALLS"
    run ! grep -q $'\r' "$CALLS"
}
