#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Fake scripts shipped: proxy prox; engine eng (options port, secret api-key);
# chat-interface chat (requires the type proxy). Only describe is needed.

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
    printf 'engine eng\nproxy prox\nchat-interface chat\n' >"$EASY_CS_AI_HOME/ranks.conf"
    make_fake proxy prox '[]' '[]'
    make_fake engine eng '[]' '[{"name":"port","default":"11434","secret":false,"description":"Listening port"},{"name":"api-key","default":"","secret":true,"description":"Key"}]'
    make_fake chat-interface chat '["proxy"]' '[]'
    cd "$BATS_TEST_TMPDIR"
    PKG=(--package-version 0.1.0 --package-sha256 "$SHA")
}

make_fake() {
    cat >"$EASY_CS_AI_HOME/$1/$2.sh" <<FAKE
#!/usr/bin/env bash
jq -n '{name: "$2", type: "$1", component_version: "9.9", requires: $3, platforms: ["debian","ubuntu"], options: $4}'
FAKE
}

gen() { run --separate-stderr bash "$SCRIPT" "$@"; }
# session <answers…>: run the generator with one answer per line on stdin.
session() {
    local answers
    answers="$(printf '%s\n' "$@")"
    # the last question of the session is the file to write (default ./easy-cs-ai.json), and the
    # confirmation of an overwrite when the file exists already
    if [[ -n "$OUTFILE" ]]; then
        ANSWERS+="$OUTFILE"$'\n'
        [[ ! -e "$OUTFILE" ]] || ANSWERS+=$'y\n'
    fi
    export ANSWERS
    run --separate-stderr bash -c 'bash "$0" new "${@:1}" <<<"$ANSWERS"' "$GEN" "${GEN_ARGS[@]}"
}
ANSWERS=""
# _join_lines <answers…>: one line per answer, a trailing empty one kept (unlike "$(printf …)",
# which strips it): an empty default answer at the end must still reach the session.
_join_lines() {
    local a
    REPLY_LINES=""
    for a in "$@"; do REPLY_LINES+="$a"$'\n'; done
}
# _expand <answers…>: the answers of a one-VM session, written as the types of the pass were chosen
# before (a component name, "" for the default, none), in the questions of the session: the role and
# the name of the VM (defaults), then for each type the package ships "Add a <type> on vm-1? (y/n)"
# and the choice, the other answers unchanged (docs/spec-multi-vm.md#creating).
_expand() {
    local n=0 t a i=0
    for t in provisioning proxy engine chat-interface; do
        compgen -G "$EASY_CS_AI_HOME/$t/*.sh" >/dev/null && n=$((n + 1))
    done
    REPLY_LINES=$'\n\n'
    for a in "$@"; do
        if ((i < n)); then
            if [[ "$a" == none ]]; then REPLY_LINES+=$'n\n'; else REPLY_LINES+="y"$'\n'"$a"$'\n'; fi
        else
            REPLY_LINES+="$a"$'\n'
        fi
        i=$((i + 1))
    done
}
# ask <answers…>: the one-VM session, then the question of another VM left to its default, the
# questions of where each model is shown left to theirs (more empty answers than there are questions
# are refused by the editor, harmlessly), and `y` to write (docs/spec-multi-vm.md#creating).
ask() { _expand "$@"; ANSWERS="$REPLY_LINES"$'\n\n\n\ny\n'; export ANSWERS; session; }
# ask_new <answers…>: the answers as the session asks them (the role and the name of the VM left to
# their defaults), then the tail of `ask`.
ask_new() {
    local a
    REPLY_LINES=$'

'
    for a in "$@"; do REPLY_LINES+="$a"$'
'; done
    ANSWERS="$REPLY_LINES"$'



y
'
    export ANSWERS
    session
}
# ask_raw <answers…>: the same, with nothing added after the answers.
ask_raw() { _expand "$@"; ANSWERS="$REPLY_LINES"; export ANSWERS; session; }

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

# --- usage -------------------------------------------------------------------------------

@test "--help and --version succeed; usage errors exit 2" {
    gen --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: script"* ]]
    gen --version
    [ "$status" -eq 0 ]
    gen </dev/null
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"easy-cs-ai config new"* ]]
    gen a.json b.json
    [ "$status" -eq 2 ]
    gen --bogus
    [ "$status" -eq 2 ]
    gen --package-format zip x.json
    [ "$status" -eq 2 ]
    gen --output
    [ "$status" -eq 2 ]
}

# --- interactive session ------------------------------------------------------------------

@test "a session picks components, proposes the dependency, asks options and models" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none "" chat y 9999 "m1, m2" y
    [ "$status" -eq 0 ]
    run jq -c '.vms[0].components | map(.component)' cfg.json
    [ "$output" = '["proxy/prox","engine/eng","chat-interface/chat"]' ]
    [ "$(jq -r '.vms[0].components[1].options.port' cfg.json)" = "9999" ]
    [ "$(jq -r '.vms[0].components[1].options["api-key"] // "none"' cfg.json)" = "none" ]
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m1","m2"]' ]
    [[ "$stderr" == *"api-key is a secret, it is generated at run time"* ]]
    [[ "$stderr" == *"chat requires proxy: add proxy prox?"* ]]
}

@test "options left at their default are not written" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" "" y
    [ "$status" -eq 0 ]
    [ "$(jq -c '.vms[0].components' cfg.json)" = '[{"component":"engine/eng"}]' ]
}

@test "an invalid answer asks again instead of aborting" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask_new n y zzz eng n "" "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"'zzz' is not one of"* ]]
    [ "$(jq -r '.vms[0].components[0].component' cfg.json)" = "engine/eng" ]
}

@test "refusing a dependency goes back to the component choice, which can be changed" {
    GEN_ARGS=(); OUTFILE=cfg.json
    # proxy n, engine n, chat y chat, the proxy it requires refused; again: no component (asked again), then the engine
    ask_new n n y chat n  n n n  n y eng n "" "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"chat cannot work without proxy"* ]]
    [[ "$stderr" == *"this VM has no component yet, choose again"* ]]
    [ "$(jq -c '.vms[0].components | map(.component)' cfg.json)" = '["engine/eng"]' ]
}

@test "the summary can be redone from a step, or cancelled" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" m1 y m m2 y
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m2"]' ]
    rm cfg.json
    ask none eng none "" m1 y n
    [ "$status" -eq 0 ]
    [ ! -e cfg.json ]
    [[ "$stderr" == *"cancelled"* ]]
}

@test "end of input cancels without writing" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng
    [ "$status" -eq 0 ]
    [ ! -e cfg.json ]
}

@test "--dry-run runs the session and writes nothing" {
    GEN_ARGS=(--dry-run)
    ask none eng none "" "" y
    [ "$status" -eq 0 ]
    [ ! -e cfg.json ]
    [[ "$stderr" == *'"component": "engine/eng"'* ]]
}

# --- warnings of the options -----------------------------------------------------------------

# a chat interface whose option allow-registration warns when it is true, like LibreChat's
make_warning_chat() {
    make_fake chat-interface chat '["proxy"]' '[{"name":"allow-registration","default":"true","secret":false,"description":"open","warn":{"when":"true","message":"registration is open"}}]'
}

@test "the summary of a session shows the warning of an option left at its default" {
    make_warning_chat
    GEN_ARGS=(); OUTFILE=cfg.json
    ask prox none chat "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"[WARN] to read before creating the VM"* ]]
    [[ "$stderr" == *"chat --allow-registration=true: registration is open"* ]]
}

@test "script shows the warning of a default, and of an explicit value that matches" {
    make_warning_chat
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"chat-interface/chat"}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"chat --allow-registration=true: registration is open"* ]]
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"chat-interface/chat","options":{"allow-registration":"true"}}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [[ "$stderr" == *"chat --allow-registration=true: registration is open"* ]]
}

@test "no warning when the option has another value, whatever its type" {
    make_warning_chat
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"chat-interface/chat","options":{"allow-registration":"false"}}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"to read before creating the VM"* ]]
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"chat-interface/chat","options":{"allow-registration":false}}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [[ "$stderr" != *"to read before creating the VM"* ]]
}

@test "no warning section for components without a warning" {
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"engine/eng"},{"component":"chat-interface/chat"}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"to read before creating the VM"* ]]
}

@test "the real LibreChat script makes the generator warn about its open registration" {
    rm -f "$EASY_CS_AI_HOME/chat-interface/chat.sh"
    cp "$REAL/chat-interface/librechat.sh" "$EASY_CS_AI_HOME/chat-interface/librechat.sh"
    cp "$REAL/proxy/nginx.sh" "$EASY_CS_AI_HOME/proxy/nginx.sh"
    ln -s "$REAL/templates" "$EASY_CS_AI_HOME/templates"
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/nginx"},{"component":"chat-interface/librechat"}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"librechat --allow-registration=true: registration is open: the first account created becomes the administrator"* ]]
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/nginx"},{"component":"chat-interface/librechat","options":{"allow-registration":"false"}}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [[ "$stderr" != *"registration is open"* ]]
}

# --- --config ---------------------------------------------------------------------------------

valid_config() {
    cat >cfg.json <<'JSON'
{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"engine/eng","options":{"port":"9"},"models":[{"model":"m1","force":true}]},{"component":"chat-interface/chat"}]}]}
JSON
}

@test "script: no prompt, summary on stderr, script written" {
    valid_config
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"components, in install order"* ]]
    [ -x vm.sh ]
}

@test "script: each validation problem exits 2 with its path, an incomplete file too" {
    echo '{"schema_version":2,"vms":[{"components":[{"component":"engine/nope"}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *'$.vms[0].components[0].component: unknown engine "nope"'* ]]
    echo '{"schema_version":2,"vms":[{"components":[{"component":"chat-interface/chat"}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"proxy is required by chat"* ]]
    echo '{nope' >cfg.json
    gen cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
    gen missing.json "${PKG[@]}"
    [ "$status" -eq 2 ]
}

@test "script ignores what is installed on the generator machine" {
    mkdir -p "$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/components"
    echo '{"name":"prox","type":"proxy"}' >"$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/components/prox.json"
    echo '{"schema_version":2,"vms":[{"components":[{"component":"chat-interface/chat"}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
}

@test "a configuration written by the session gives the same script as the session" {
    GEN_ARGS=("${PKG[@]}" --output a.sh)
    ask_script none eng none "" "m1" y y
    [ "$status" -eq 0 ]
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" "m1" y y
    gen cfg.json "${PKG[@]}" --output b.sh
    [ "$status" -eq 0 ]
    diff <(grep -v '^# easy-cs-ai VM' a.sh) <(grep -v '^# easy-cs-ai VM' b.sh)
}

# --- the file written by the session ---------------------------------------------------------------

@test "the session asks the file to write, default ./easy-cs-ai.json, and writes no script" {
    GEN_ARGS=()
    ask_raw none eng none "" "m1" y y "" y ""
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"File to write (overwritten, or created if it does not exist) [./easy-cs-ai.json]:"* ]]
    [ -s easy-cs-ai.json ]
    [ -z "$(ls easy-cs-ai-vm*.sh 2>/dev/null)" ]
    [[ "$stderr" == *"to generate the scripts: easy-cs-ai script ./easy-cs-ai.json"* ]]
}

@test "the session asks again for another name when the file exists and the overwrite is refused" {
    GEN_ARGS=()
    echo '{"keep":1}' >easy-cs-ai.json
    ask_raw none eng none "" "m1" y y "" y "" n mine.json
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"./easy-cs-ai.json exists. Overwrite? (y/n) [n]:"* ]]
    [ "$(cat easy-cs-ai.json)" = '{"keep":1}' ]
    [ -s mine.json ]
}

@test "the session overwrites an existing file once it is confirmed" {
    GEN_ARGS=()
    echo '{"keep":1}' >easy-cs-ai.json
    ask_raw none eng none "" "m1" y y "" y "" y
    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema_version' easy-cs-ai.json)" = 2 ]
}

@test "the end of input at the question of the file writes nothing" {
    GEN_ARGS=()
    # the here-string adds a last empty line, which answers the question of another VM
    ask_raw none eng none "" "m1" y y
    [ "$status" -eq 0 ]
    [ ! -e easy-cs-ai.json ]
}

@test "--dry-run asks no file and writes nothing" {
    GEN_ARGS=(--dry-run)
    ask none eng none "" "m1" y y
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"File to write"* ]]
    [ ! -e easy-cs-ai.json ]
}

# --- generated script ---------------------------------------------------------------------------

embedded_config() { sed -n "/<<'EASY_CS_AI_CONFIG'/,/^EASY_CS_AI_CONFIG\$/p" "$1" | sed '1d;$d'; }

@test "the script pins the package, records the build and embeds the configuration untouched" {
    valid_config
    gen cfg.json "${PKG[@]}" --output vm.sh
    bash -n vm.sh
    grep -q "^PACKAGE_VERSION='0.1.0'" vm.sh
    grep -q "^PACKAGE_SHA256='$SHA'" vm.sh
    grep -q "^PACKAGE_URL='https://github.com/Dimsi-BS/easy-cs-ai/releases/download/v0.1.0/easy-cs-ai_0.1.0_all.deb'" vm.sh
    grep -q '^# component: engine eng 9.9 --port=9' vm.sh
    grep -q '^# package: easy-cs-ai 0.1.0 (deb)' vm.sh
    diff <(embedded_config vm.sh) <(jq . cfg.json)
}

@test "nothing in the configuration is expanded" {
    printf '%s' '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng","options":{"port":"$(touch pwned) `id` & \\ $HOME"}}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh
    diff <(embedded_config vm.sh) <(jq . cfg.json)
}

@test "package formats and options set the URL and the file type" {
    valid_config
    gen cfg.json "${PKG[@]}" --package-format rpm --output vm.sh
    grep -q "easy-cs-ai-0.1.0-1.noarch.rpm'" vm.sh
    grep -q "^PACKAGE_FORMAT='rpm'" vm.sh
    gen cfg.json "${PKG[@]}" --package-format tarball --package-url https://mirror.local/x.tgz --output vm.sh
    grep -q "^PACKAGE_URL='https://mirror.local/x.tgz'" vm.sh
    grep -q "^PACKAGE_FORMAT='tar.gz'" vm.sh
}

@test "the checksum comes from a local file, else it is an error (exit 5), never omitted" {
    valid_config
    printf 'pkg' >pkg.deb
    gen cfg.json --package-version 0.1.0 --package-file pkg.deb --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_SHA256='$(sha256sum pkg.deb | cut -d' ' -f1)'" vm.sh
    gen cfg.json --package-version 0.1.0 --package-url file:///nonexistent/x.deb --output vm2.sh
    [ "$status" -eq 5 ]
    [ ! -e vm2.sh ]
    gen cfg.json --package-version 0.1.0 --package-sha256 zz --output vm2.sh
    [ "$status" -eq 5 ]
}

@test "the checksum is read from <url>.sha256 when it exists" {
    valid_config
    printf '%s  x.deb\n' "$SHA" >x.deb.sha256
    gen cfg.json --package-version 0.1.0 --package-url "file://$PWD/x.deb" --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_SHA256='$SHA'" vm.sh
}

@test "the package version is required when the CLI does not give it" {
    valid_config
    gen cfg.json --package-sha256 "$SHA"
    [ "$status" -eq 2 ]
    EASY_CS_AI_CLI_VERSION=0.3.0 gen cfg.json --package-sha256 "$SHA" --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_VERSION='0.3.0'" vm.sh
}

@test "the generated script is shellcheck clean" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    valid_config
    gen cfg.json "${PKG[@]}" --output vm.sh
    shellcheck vm.sh
}

@test "the generated script refuses to run as a normal user, and stays small" {
    valid_config
    gen cfg.json "${PKG[@]}" --output vm.sh
    [ "$(wc -c <vm.sh)" -lt 8192 ]
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    run bash vm.sh
    [ "$status" -eq 4 ]
}

@test "--dry-run prints the script and writes nothing" {
    valid_config
    gen cfg.json "${PKG[@]}" --output vm.sh --dry-run
    [ "$status" -eq 0 ]
    [ ! -e vm.sh ]
    [[ "$stderr" == *"PACKAGE_VERSION='0.1.0'"* ]]
}

# --- through the CLI ------------------------------------------------------------------------------

@test "easy-cs-ai script hands over to the generator with the CLI version" {
    ln -s "${BATS_TEST_DIRNAME}/../../vm_script" "$BATS_TEST_TMPDIR/vm_script"
    valid_config
    run --separate-stderr bash "$CLI" script cfg.json --package-sha256 "$SHA" --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_VERSION='$(sed -n 's/^readonly CLI_VERSION=//p' "$CLI")'" vm.sh
    run --separate-stderr bash "$CLI" --dry-run script cfg.json --package-sha256 "$SHA" --output vm2.sh
    [ ! -e vm2.sh ]
}

@test "easy-cs-ai script with no file is exit 2 and points to config new" {
    ln -s "${BATS_TEST_DIRNAME}/../../vm_script" "$BATS_TEST_TMPDIR/vm_script"
    run --separate-stderr bash "$CLI" script </dev/null
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"easy-cs-ai config new"* ]]
}

@test "easy-cs-ai generate is no longer a command: exit 2, the hint names config new, config edit and script" {
    run --separate-stderr bash "$CLI" generate --config x.json
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown command 'generate'"* ]]
    [[ "$stderr" == *"easy-cs-ai config new"* && "$stderr" == *"easy-cs-ai config edit"* && "$stderr" == *"easy-cs-ai script"* ]]
}

@test "easy-cs-ai config new and config edit hand over to the session; config alone lists its subcommands" {
    ln -s "${BATS_TEST_DIRNAME}/../../vm_script" "$BATS_TEST_TMPDIR/vm_script"
    run --separate-stderr bash "$CLI" config new --json
    [ "$status" -eq 2 ]
    run --separate-stderr bash "$CLI" config
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"config new"*"config edit"*"config validate"*"config schema"* ]]
    printf '{"schema_version":2,"vms":[{"components":[{"component":"engine/eng"}]}]}' >cfg.json
    run --separate-stderr bash "$CLI" config edit cfg.json <<<"q"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"cancelled, nothing written"* ]]
}

# --- --json (docs/spec-capabilities.md) ---------------------------------------------------

@test "--json is refused by the session: it is interactive" {
    run --separate-stderr bash "$GEN" new --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "script --json: the validation document extended with the script, one document on stdout" {
    valid_config
    gen cfg.json --json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [ "$(jq -s 'length' <<<"$output")" = 1 ]
    run jq -c '[.ok, .target, .errors, .script.path, .script.written, .script.package_version, .script.package_format, (.script.bytes > 0), (.plan.vms[0].components | length > 0)]' <<<"$output"
    [ "$output" = '[true,"fresh",[],"vm.sh",true,"0.1.0","deb",true,true]' ]
    [ -x vm.sh ]
}

@test "script --json --dry-run writes nothing and says so" {
    valid_config
    gen cfg.json --json --dry-run "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [ "$(jq -r '.script.written' <<<"$output")" = "false" ]
    [ ! -e vm.sh ]
}

@test "script --json of an invalid or incomplete file: the document with its errors, exit 2, no script" {
    echo '{"schema_version":2,"vms":[{"components":[{"component":"chat-interface/chat"}]}]}' >cfg.json
    gen cfg.json --json "${PKG[@]}" --output vm.sh
    [ "$status" -eq 2 ]
    run jq -c '[.ok, .errors[0].code, .script, .plan]' <<<"$output"
    [ "$output" = '[false,"missing_requirement",null,null]' ]
    [ ! -e vm.sh ]
    echo '{nope' >cfg.json
    gen cfg.json --json "${PKG[@]}"
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0].code' <<<"$output")" = "not_json" ]
}

@test "easy-cs-ai script forwards --json, before or after the command" {
    valid_config
    ln -s "${BATS_TEST_DIRNAME}/../../vm_script" "$BATS_TEST_TMPDIR/vm_script"
    run --separate-stderr bash "$CLI" --json script cfg.json --dry-run "${PKG[@]}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ok' <<<"$output")" = "true" ]
    run --separate-stderr bash "$CLI" script cfg.json --json --dry-run "${PKG[@]}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.script.written' <<<"$output")" = "false" ]
}

# --- models: llmfit is optional ------------------------------------------------------------------

# a shipped llmfit (rank 1 of its type) whose suggest, check and plan are logged in $CALLS; it
# reports itself installed unless FAKE_LLMFIT=missing
make_llmfit() {
    mkdir -p "$EASY_CS_AI_HOME/provisioning"
    printf 'provisioning llmfit\n' >>"$EASY_CS_AI_HOME/ranks.conf"
    cat >"$EASY_CS_AI_HOME/provisioning/llmfit.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$1" in
describe) jq -n '{name: "llmfit", type: "provisioning", component_version: "9.9", requires: [], platforms: ["debian","ubuntu"], options: []}' ;;
status)
    if [[ "${FAKE_LLMFIT:-}" == missing && ! -e "$CALLS.installed" ]]; then echo '{"installed":false,"running":false,"healthy":false}'; exit 4; fi
    echo '{"installed":true,"running":true,"healthy":true}' ;;
install)
    [[ "${FAKE_LLMFIT_INSTALL:-}" != fail ]] || { echo "fake install failed" >&2; exit 5; }
    touch "$CALLS.installed" ;;
# what suggest prints is what the generator shows, in that order, with nothing filtered or
# re-ranked on its side (the Too Tight one and the untagged one are the action's business); it
# only reads the number and the name at the start of the lines
suggest)
    printf '   1) llama3.2:3b                  Good, needs 2.4 GB\n   2) small:1b                     Perfect, needs 1.2 GB\n' ;;
# what plan prints is what the generator shows, as it is: the text is the fake's own, and the
# generator must not compute or format anything of it
plan)
    shift
    chat=no cores=none names=()
    while (($#)); do
        case "$1" in
        --component) [[ "$2" == chat-interface/* ]] && chat=yes; shift ;;
        --target-cpu-cores) cores="$2"; shift ;;
        *) names+=("${1%%@*}") ;;
        esac
        shift
    done
    echo "fake: sizing ${names[*]}" >&2
    printf '\nFAKE RECOMMENDATION for %s (chat interface: %s, vcpu: %s)\n  with a margin that is the fake'"'"'s own\n' "${names[*]}" "$chat" "$cores" ;;
check)
    case "$2" in
    big) echo '{"fits":false,"reason":"big: fit Too Tight, needs 40 GB of 16 GB available"}' ;;
    unknown) exit 1 ;;
    *) echo '{"fits":true,"reason":"ok"}' ;;
    esac ;;
esac
FAKE
    chmod +x "$EASY_CS_AI_HOME/provisioning/llmfit.sh"
    make_fake engine ollama '[]' '[]'
    export CALLS="$BATS_TEST_TMPDIR/llmfit-calls"
    : >"$CALLS"
}

@test "with llmfit the models step asks the specs of the VM, suggests models and keeps a bad verdict as a warning" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    # llmfit, proxy, engine, chat; specs (RAM, GPU, cores); models: the first suggestion, then two typed names
    ask "" none ollama none "" 16 "" 4 "1, big, unknown" y y
    [ "$status" -eq 0 ]
    # best score first, only the Ollama tags, nothing that is Too Tight
    [[ "$stderr" == *" 1) llama3.2:3b"*" 2) small:1b"* ]]
    [[ "$stderr" != *"huge:70b"* ]]
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["llama3.2:3b","big","unknown"]' ]
    grep -qx 'suggest --target-ram 16 --target-cpu-cores 4' "$CALLS"
    grep -qx 'check big --target-ram 16 --target-cpu-cores 4' "$CALLS"
    grep -qx 'check unknown --target-ram 16 --target-cpu-cores 4' "$CALLS"
    # the step says what it is doing before each slow llmfit call
    [[ "$stderr" == *"checking whether llmfit is available"*"asking llmfit for the models that fit"*"checking big with llmfit"* ]]
    # the suggestion was sized already
    ! grep -q 'check llama3.2:3b' "$CALLS"
    [[ "$stderr" == *"may not fit the VM, big: big: fit Too Tight"* ]]
    [[ "$stderr" == *"may not fit the VM, unknown: not known to llmfit"* ]]
    # llmfit is in the stack: no force, no warning about it
    [ "$(jq '[.vms[0].components[].models[]? | has("force")] | any' cfg.json)" = "false" ]
    [[ "$stderr" != *"not checked for fit"* ]]
}

@test "the specs are optional, and without any there is no suggestion and no check" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none "" "" "" "" m1 y y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"no spec given"* ]]
    ! grep -q -e suggest -e check -e plan "$CALLS"
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m1"]' ]
}

@test "a spec that is not a positive whole number is asked again" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none "" abc 0 8 "" "" "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"'abc' is not a positive whole number"* ]]
    [[ "$stderr" == *"'0' is not a positive whole number"* ]]
    grep -qx 'suggest --target-ram 8' "$CALLS"
}

@test "redoing the models offers the specs given before as defaults" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none "" 16 "" 4 "" m "" "" "" "" m1 y y
    [ "$status" -eq 0 ]
    [ "$(grep -c '^suggest --target-ram 16 --target-cpu-cores 4$' "$CALLS")" -eq 2 ]
    [[ "$stderr" == *"RAM of the VM in GB [16]"* ]]
}

@test "llmfit shipped but not installed here: it is offered, declined by default, then typed names" {
    make_llmfit
    export FAKE_LLMFIT=missing
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none "" m1 y y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"llmfit is not installed here: install it now"*"(y/n) [n]"* ]]
    [[ "$stderr" == *"sudo easy-cs-ai install provisioning llmfit"* ]]
    ! grep -q -e suggest -e check -e install "$CALLS"
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m1"]' ]
    # a redo of the step does not ask again
    ask "" none ollama none n m1 y m m2 y
    [ "$(grep -o 'install it now' <<<"$stderr" | wc -l)" -eq 1 ]
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m2"]' ]
}

@test "llmfit installed on the spot: the session goes on with the specs and the suggestions" {
    make_llmfit
    export FAKE_LLMFIT=missing
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none y "" 16 "" "" 1 y y
    [ "$status" -eq 0 ]
    grep -qx install "$CALLS"
    grep -qx 'suggest --target-ram 16' "$CALLS"
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["llama3.2:3b"]' ]
}

@test "llmfit that cannot be installed: a warning, then typed names" {
    make_llmfit
    export FAKE_LLMFIT=missing FAKE_LLMFIT_INSTALL=fail
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none y m1 y y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"llmfit could not be installed, type the model names"* ]]
    [[ "$stderr" != *"Recommended VM"* ]]
    ! grep -q -e suggest -e plan "$CALLS"
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m1"]' ]
}

@test "a package that ships no llmfit offers nothing to install" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" m1 y y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"this package ships no llmfit"* ]]
    [[ "$stderr" != *"install it now"* ]]
}

@test "declining llmfit in the stack writes the models with force and the summary warns" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    # llmfit is installed on this machine whatever the stack: the specs are still asked
    ask none none ollama none "" "" "" "" m1 y y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"with none, the models are added unchecked"* ]]
    [ "$(jq -c '.vms[0].components[] | select(.component == "engine/ollama") | .models' cfg.json)" = '[{"model":"m1","force":true}]' ]
    [[ "$stderr" == *"[WARN] to read before creating the VM"* ]]
    [[ "$stderr" == *"models not checked for fit on the VM: llmfit is not part of the stack"* ]]
}

@test "no llmfit in the stack and no model: no force, no warning" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none none ollama none "" "" "" "" "" y
    [ "$status" -eq 0 ]
    [ "$(jq '[.vms[0].components[] | has("models")] | any' cfg.json)" = "false" ]
    [[ "$stderr" != *"not checked for fit"* ]]
}

@test "the order is asked first, hardware first by default, and a wrong answer is asked again" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none x "" "" "" "" m1 y y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"'x' is not h or m"* ]]
    [[ "$stderr" == *"Order, hardware first (h) or models first (m) [h]"* ]]
    [[ "$stderr" == *"RAM of the VM in GB"* ]]
    [[ "$stderr" != *"Recommended VM"* ]]
}

@test "models first: the plan of llmfit is shown as it is, once, in the summary, and nothing is stored in the configuration" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none m m1 y y
    [ "$status" -eq 0 ]
    # no specs asked, no suggestion, no fit check: the models are sized instead
    [[ "$stderr" != *"RAM of the VM in GB"* ]]
    grep -qx 'plan m1@ollama --component provisioning/llmfit --component proxy/prox --component engine/ollama' "$CALLS"
    ! grep -q -e suggest -e check "$CALLS"
    # the text of the action, with the progress it announced while llmfit was slow
    [[ "$stderr" == *"fake: sizing m1"* ]]
    [[ "$stderr" == *"FAKE RECOMMENDATION for m1 (chat interface: no, vcpu: none)"* ]]
    [[ "$stderr" == *"with a margin that is the fake's own"* ]]
    # printed once, in the summary, not at the end of the step
    [ "$(grep -o 'FAKE RECOMMENDATION' <<<"$stderr" | wc -l)" -eq 1 ]
    [[ "${stderr##*Summary}" == *"FAKE RECOMMENDATION"* ]]
    # the configuration is valid for any VM: models only
    [ "$(jq -c 'keys' cfg.json)" = '["schema_version","vms"]' ]
    [ "$(jq -c '.vms[0].components[] | select(.component == "engine/ollama") | .models' cfg.json)" = '[{"model":"m1"}]' ]
}

@test "models first: all the models are given to the plan, in one call" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none m "m1, m2" y y
    [ "$status" -eq 0 ]
    grep -qx 'plan m1@ollama m2@ollama --component provisioning/llmfit --component proxy/prox --component engine/ollama' "$CALLS"
    [ "$(grep -c '^plan' "$CALLS")" -eq 1 ]
    [[ "$stderr" == *"FAKE RECOMMENDATION for m1 m2"* ]]
}

@test "models first: a chat interface in the stack is passed to the plan" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" "" ollama chat m m1 y
    [ "$status" -eq 0 ]
    grep -qx 'plan m1@ollama --component provisioning/llmfit --component proxy/prox --component engine/ollama --component chat-interface/chat' "$CALLS"
    [[ "$stderr" == *"(chat interface: yes, vcpu: none)"* ]]
}

@test "models first: the cores given before are passed to the plan as the vCPU" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none "" "" "" 4 "" m m "m1, unknown" y y
    [ "$status" -eq 0 ]
    grep -qx 'plan m1@ollama unknown@ollama --component provisioning/llmfit --component proxy/prox --component engine/ollama --target-cpu-cores 4' "$CALLS"
    [[ "$stderr" == *"vcpu: 4"* ]]
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m1","unknown"]' ]
}

@test "models first: no model, the stack is sized from its components alone" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none m "" y
    [ "$status" -eq 0 ]
    # a VM with no model is sized from its components, with no model and no proxy asked for
    grep -qx 'plan --component provisioning/llmfit --component engine/ollama' "$CALLS"
    [ "$(grep -c '^plan' "$CALLS")" -eq 1 ]
    [[ "${stderr##*Summary}" == *"FAKE RECOMMENDATION"* ]]
}

@test "models first: the order is offered again when the step is redone, and the recommendation follows the models" {
    make_llmfit
    GEN_ARGS=(); OUTFILE=cfg.json
    ask "" none ollama none m m1 y m "" m2 y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Order, hardware first (h) or models first (m) [m]"* ]]
    grep -qx 'plan m1@ollama --component provisioning/llmfit --component proxy/prox --component engine/ollama' "$CALLS"
    grep -qx 'plan m2@ollama --component provisioning/llmfit --component proxy/prox --component engine/ollama' "$CALLS"
    # the summary shows the second one only
    [[ "${stderr##*Summary}" == *"FAKE RECOMMENDATION for m2 "* ]]
    [[ "${stderr##*Summary}" != *"FAKE RECOMMENDATION for m1 "* ]]
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m2"]' ]
}

@test "script: no session, so no recommendation" {
    make_llmfit
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"engine/ollama","models":[{"model":"m1"}]},{"component":"provisioning/llmfit"}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"Recommended VM"* ]]
    ! grep -q '^plan' "$CALLS"
}

@test "script: the warning follows a model with force and no llmfit, and nothing else changes" {
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"engine/eng","models":[{"model":"m1","force":true}]}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"models not checked for fit on the VM: llmfit is not part of the stack"* ]]
    # without force, a model needs a provisioning component: the file is refused, not warned about
    rm -f vm.sh
    echo '{"schema_version":2,"vms":[{"components":[{"component":"proxy/prox"},{"component":"engine/eng","models":[{"model":"m1"}]}]}]}' >cfg.json
    gen cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"needs a provisioning component"* ]]
    [ ! -e vm.sh ]
}

# --- the proxy a model needs ----------------------------------------------------------------

@test "a model on an engine that is not protected proposes a proxy: yes adds it and asks its options" {
    make_fake proxy prox '[]' '[{"name":"server-name","default":"","secret":false,"description":"Name"}]'
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" m1 y llm.example.org y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"m1 needs a proxy to be reached from outside the VM (the engine listens on the loopback only). Add prox? (y/n) [y]"* ]]
    [ "$(jq -c '.vms[0].components | map(.component)' cfg.json)" = '["proxy/prox","engine/eng"]' ]
    [ "$(jq -c '.vms[0].components[0].options' cfg.json)" = '{"server-name":"llm.example.org"}' ]
    [ "$(jq -c '[.vms[0].components[].models[]?.model]' cfg.json)" = '["m1"]' ]
}

@test "refusing the proxy takes the models out of the list, with a message" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" "m1, m2" n y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"m1, m2 needs a proxy"* ]]
    [[ "$stderr" == *"without a proxy the models cannot be reached from outside the VM: none is added"* ]]
    [ "$(jq -c '.vms[0].components | map(.component)' cfg.json)" = '["engine/eng"]' ]
    [ "$(jq '[.vms[0].components[] | has("models")] | any' cfg.json)" = "false" ]
}

@test "no proxy is proposed for a protected engine, with no model, or by a package that ships none" {
    cat >"$EASY_CS_AI_HOME/engine/eng.sh" <<'FAKE'
#!/usr/bin/env bash
jq -n '{name: "eng", type: "engine", component_version: "9.9", requires: [], platforms: ["debian","ubuntu"], endpoint: {protected: true}, options: []}'
FAKE
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none m1 y
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"needs a proxy"* ]]
    [ "$(jq -c '.vms[0].components | map(.component)' cfg.json)" = '["engine/eng"]' ]
    make_fake engine eng '[]' '[]'
    ask none eng none "" y
    [[ "$stderr" != *"needs a proxy"* ]]
    rm "$EASY_CS_AI_HOME/proxy/prox.sh"
    ask eng none "" m1 y
    [[ "$stderr" != *"needs a proxy"* ]]
    [[ "$stderr" == *"m1"* ]]
}

# --- the VM with no model ---------------------------------------------------------------------

@test "a package that ships no sizing component says so for a VM with no model, and still ends well" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"no recommendation: this package ships no sizing component"* ]]
    [ -s cfg.json ]
}

@test "a session with a model does not size the stack with no model" {
    GEN_ARGS=(); OUTFILE=cfg.json
    ask none eng none "" m1 y y
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"no recommendation"* ]]
}

@test "a package that ships no proxy to propose: the summary shows the error, and it is not confirmed" {
    rm "$EASY_CS_AI_HOME/proxy/prox.sh"
    GEN_ARGS=(); OUTFILE=cfg.json
    # engine, no model on the first try, then a model, a confirmation that is refused, and a cancel
    ask eng none "" m1 y n
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"[ERROR] to fix before this can be confirmed:"*"model m1 needs a proxy to be reached from outside the VM"* ]]
    [[ "$stderr" == *"this configuration cannot finish, redo a step or cancel"* ]]
    [ ! -e cfg.json ]
    # without the model the same package is fine
    ask eng none "" "" y
    [ "$status" -eq 0 ]
    [ -s cfg.json ]
    [[ "$stderr" != *"[ERROR]"* ]]
}
