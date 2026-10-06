#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Fake components, all installed in setup: engine eng (not protected), proxy
# prox, chat-interface chat, provisioning fit. Calls are logged in $CALLS;
# FAKE_FAIL lists "<name>-<action>" entries that fail with exit 5.

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
    make_fake engine eng
    make_fake proxy prox
    make_fake chat-interface chat
    make_fake provisioning fit
    : >"$CALLS"
    install_state eng engine '"endpoint":{"url":"http://127.0.0.1:1234","openai_base_url":"http://127.0.0.1:1234/v1","protected":false},"models":[]'
    install_state prox proxy '"upstreams":[]'
    install_state chat chat-interface '"endpoints":[]'
    install_state fit provisioning '"x":1'
}

install_state() {
    bash -c "source '$REAL/lib/common.sh'; state_write $1 '{\"name\":\"$1\",\"type\":\"$2\",$3}'"
}

make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
source "\$EASY_CS_AI_LIB/common.sh"
action="\$1"; shift
echo "$2 \$action \$*" >>"\$CALLS"
[[ " \${FAKE_FAIL:-} " == *" $2-\$action "* ]] && exit 5
case "\$action" in
describe) jq -n '{name: "$2", type: "$1", requires: []}' ;;
check) echo '{"fits": '"\${FAKE_FITS:-true}"', "reason": "needs 12 GB"}' ;;
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

calls() { cat "$CALLS"; }

# --- add ----------------------------------------------------------------------------------

@test "add checks the fit, adds, exposes, links and records the wiring" {
    cli add llama3.2:3b
    [ "$status" -eq 0 ]
    run calls
    [ "${lines[0]}" = "fit check llama3.2:3b" ]
    [ "${lines[1]}" = "eng add-model llama3.2:3b" ]
    [ "${lines[2]}" = "prox add-upstream eng-llama3.2-3b http://127.0.0.1:1234" ]
    [ "${lines[3]}" = "chat add-endpoint eng-llama3.2-3b https://host/eng-llama3.2-3b" ]
    run jq -r '.models[0] | [.exposed_via, (.linked_to | join(","))] | join(" ")' "$STATE/eng.json"
    [ "$output" = "prox chat" ]
}

@test "add is idempotent: a second run does nothing" {
    cli add m1
    : >"$CALLS"
    cli add m1
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"already added"* ]]
    ! grep -q 'add-model\|add-endpoint' "$CALLS"
}

@test "add of a protected engine skips the proxy and links the engine URL" {
    install_state eng engine '"endpoint":{"url":"http://127.0.0.1:1234","openai_base_url":"http://127.0.0.1:1234/v1","protected":true},"models":[]'
    cli add m1
    [ "$status" -eq 0 ]
    ! grep -q add-upstream "$CALLS"
    grep -q 'chat add-endpoint eng-m1 http://127.0.0.1:1234/v1' "$CALLS"
}

@test "add uses the per-model port of an engine with one instance per model" {
    install_state eng engine '"models":[{"name":"m1","port":8001,"exposed_via":null,"linked_to":[]}]'
    cli add m1
    grep -q 'prox add-upstream eng-m1 http://127.0.0.1:8001' "$CALLS"
}

@test "add --no-chat-interface and a missing chat interface skip the link" {
    cli add m1 --no-chat-interface
    [ "$status" -eq 0 ]
    ! grep -q add-endpoint "$CALLS"
    rm "$STATE/chat.json"
    cli add m2
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"no chat interface installed"* ]]
}

@test "add: a model that does not fit stops with exit 4 and the reason; --force bypasses" {
    FAKE_FITS=false cli add big
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"does not fit"*"needs 12 GB"* ]]
    ! grep -q add-model "$CALLS"
    FAKE_FITS=false cli add big --force
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"fit check skipped"* ]]
}

@test "add resolution errors are exit 4: no engine, unknown name" {
    cli add m --engine nope
    [ "$status" -eq 4 ]
    rm "$STATE/eng.json"
    cli add m
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"install an engine first"* ]]
}

@test "add with several engines and no default asks to choose" {
    install_state eng2 engine '"models":[],"default":false'
    jq '.default = false' "$STATE/eng.json" >"$BATS_TEST_TMPDIR/e"
    cp "$BATS_TEST_TMPDIR/e" "$STATE/eng.json"
    cli add m
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"several engines"* ]]
}

@test "add with a missing proxy or llmfit fails with the command, or installs with --defaults" {
    rm "$STATE/prox.json" "$STATE/fit.json"
    cli add m
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"easy-cs-ai install proxy prox"* ]]
    cli add m --defaults
    grep -q 'prox install' "$CALLS"
    grep -q 'fit install' "$CALLS"
}

@test "add --dry-run prints the plan and changes nothing" {
    cli --dry-run add m1
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plan: add m1 to eng, expose through prox, link to chat"* ]]
    [ ! -s "$CALLS" ]
}

@test "add usage errors" {
    cli add
    [ "$status" -eq 2 ]
    cli add a b
    [ "$status" -eq 2 ]
    cli add a --bogus
    [ "$status" -eq 2 ]
}

@test "add journals start and end" {
    cli add m1
    [[ "$stderr" == *"add start model=m1 engine=eng chat_interface=chat"* ]]
    [[ "$stderr" == *"add end exit=0"* ]]
}

# --- add rollback -------------------------------------------------------------------------

@test "rollback when the engine step fails: nothing to undo" {
    FAKE_FAIL=eng-add-model cli add m1
    [ "$status" -eq 5 ]
    ! grep -q 'remove' "$CALLS"
}

@test "rollback when the proxy step fails: the model is removed from the engine" {
    FAKE_FAIL=prox-add-upstream cli add m1
    [ "$status" -eq 5 ]
    grep -q 'eng remove-model m1' "$CALLS"
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 0 ]
}

@test "rollback when the chat step fails: upstream and model are removed, in that order" {
    FAKE_FAIL=chat-add-endpoint cli add m1
    [ "$status" -eq 5 ]
    run grep -n 'remove' "$CALLS"
    [[ "${lines[0]}" == *"prox remove-upstream eng-m1"* ]]
    [[ "${lines[1]}" == *"eng remove-model m1"* ]]
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 0 ]
}

@test "a re-run after a failure completes" {
    FAKE_FAIL=chat-add-endpoint cli add m1
    cli add m1
    [ "$status" -eq 0 ]
    [ "$(jq -r '.models[0].linked_to[0]' "$STATE/eng.json")" = "chat" ]
}

@test "a failed re-run does not remove a model that existed before" {
    cli add m1 --no-chat-interface
    : >"$CALLS"
    FAKE_FAIL=chat-add-endpoint cli add m1
    [ "$status" -eq 5 ]
    ! grep -q 'eng remove-model' "$CALLS"
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 1 ]
}

@test "an incomplete rollback exits 7 and lists what is left" {
    FAKE_FAIL="chat-add-endpoint prox-remove-upstream" cli add m1
    [ "$status" -eq 7 ]
    [[ "$stderr" == *"could not undo: proxy upstream eng-m1"* ]]
}

# --- remove -------------------------------------------------------------------------------

@test "remove unwires then deletes, and clears the wiring" {
    cli add m1
    : >"$CALLS"
    cli remove m1
    [ "$status" -eq 0 ]
    run calls
    [ "${lines[0]}" = "chat remove-endpoint eng-m1" ]
    [ "${lines[1]}" = "prox remove-upstream eng-m1" ]
    [ "${lines[2]}" = "eng remove-model m1" ]
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 0 ]
}

@test "remove of an unknown model is exit 4 listing the known ones" {
    cli add m1
    cli remove nope
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"known models: m1"* ]]
}

@test "remove with the model on two engines asks for --engine" {
    cli add m1
    make_fake engine eng2
    install_state eng2 engine '"models":[{"name":"m1","exposed_via":null,"linked_to":[]}],"default":false'
    cli remove m1
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"several engines"* ]]
    cli remove m1 --engine eng2
    [ "$status" -eq 0 ]
}

@test "remove stops at a failing step and a re-run resumes" {
    cli add m1
    FAKE_FAIL=prox-remove-upstream cli remove m1
    [ "$status" -eq 5 ]
    [ "$(jq -c '.models[0].linked_to' "$STATE/eng.json")" = "[]" ]
    [ "$(jq -r '.models[0].exposed_via' "$STATE/eng.json")" = "prox" ]
    cli remove m1
    [ "$status" -eq 0 ]
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 0 ]
}

@test "remove skips a component that is no longer installed, with a warning" {
    cli add m1
    rm "$STATE/chat.json"
    cli remove m1
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"chat is not installed, nothing to unlink"* ]]
}

@test "remove --all empties every engine; nothing to remove exits 0" {
    cli add m1
    cli add m2
    cli remove --all
    [ "$status" -eq 0 ]
    [ "$(jq '.models | length' "$STATE/eng.json")" -eq 0 ]
    cli remove --all
    [ "$status" -eq 0 ]
}

@test "remove --all --engine is limited to that engine" {
    make_fake engine eng2
    install_state eng2 engine '"models":[{"name":"x","exposed_via":null,"linked_to":[]}],"default":false'
    cli add m1
    cli remove --all --engine eng
    [ "$status" -eq 0 ]
    [ "$(jq '.models | length' "$STATE/eng2.json")" -eq 1 ]
}

@test "remove usage errors: --all with a model, --defaults, nothing" {
    cli remove m --all
    [ "$status" -eq 2 ]
    cli remove --all --defaults
    [ "$status" -eq 2 ]
    cli remove
    [ "$status" -eq 2 ]
}

@test "remove --dry-run changes nothing" {
    cli add m1
    : >"$CALLS"
    cli --dry-run remove m1
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}
