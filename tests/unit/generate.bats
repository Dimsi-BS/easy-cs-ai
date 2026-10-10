#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Fake scripts shipped: proxy prox; engine eng (options port, secret api-key);
# chat-interface chat (requires the type proxy). Only describe is needed.

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

gen() { run --separate-stderr bash "$GEN" "$@"; }
# session <answers…>: run the generator with one answer per line on stdin.
session() {
    local answers
    answers="$(printf '%s\n' "$@")"
    run --separate-stderr bash -c 'bash "$0" "${@:1}" <<<"$ANSWERS"' "$GEN" "${GEN_ARGS[@]}"
}
ANSWERS=""
ask() { ANSWERS="$(printf '%s\n' "$@")"; export ANSWERS; session; }

# --- usage -------------------------------------------------------------------------------

@test "--help and --version succeed; usage errors exit 2" {
    gen --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: generate"* ]]
    gen --version
    [ "$status" -eq 0 ]
    gen --config x.json --config-only
    [ "$status" -eq 2 ]
    gen --bogus
    [ "$status" -eq 2 ]
    gen --package-format zip --config x.json
    [ "$status" -eq 2 ]
    gen --output
    [ "$status" -eq 2 ]
}

# --- interactive session ------------------------------------------------------------------

@test "a session picks components, proposes the dependency, asks options and models" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask none "" chat y 9999 "m1, m2" y
    [ "$status" -eq 0 ]
    run jq -c '.components | map(.type + ":" + .name)' cfg.json
    [ "$output" = '["proxy:prox","engine:eng","chat-interface:chat"]' ]
    [ "$(jq -r '.components[1].options.port' cfg.json)" = "9999" ]
    [ "$(jq -r '.components[1].options["api-key"] // "none"' cfg.json)" = "none" ]
    [ "$(jq -c '[.models[].name]' cfg.json)" = '["m1","m2"]' ]
    [[ "$stderr" == *"api-key is a secret, it is generated at run time"* ]]
    [[ "$stderr" == *"chat requires proxy: add proxy prox?"* ]]
}

@test "options left at their default are not written" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask none eng none "" "" y
    [ "$status" -eq 0 ]
    [ "$(jq -c '.components' cfg.json)" = '[{"type":"engine","name":"eng"}]' ]
    [ "$(jq 'has("models")' cfg.json)" = "false" ]
}

@test "an invalid answer asks again instead of aborting" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask none zzz eng none "" "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"'zzz' is not one of"* ]]
    [ "$(jq -r '.components[0].name' cfg.json)" = "eng" ]
}

@test "refusing a dependency goes back to the component choice" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask none none chat n none none none y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"chat cannot work without proxy"* ]]
    [ "$(jq -c '.components' cfg.json)" = '[]' ]
}

@test "the summary can be redone from a step, or cancelled" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask none eng none "" m1 4 m2 y
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.models[].name]' cfg.json)" = '["m2"]' ]
    rm cfg.json
    ask none eng none "" m1 n
    [ "$status" -eq 0 ]
    [ ! -e cfg.json ]
    [[ "$stderr" == *"cancelled"* ]]
}

@test "end of input cancels without writing" {
    GEN_ARGS=(--config-only --output cfg.json)
    ask none eng
    [ "$status" -eq 0 ]
    [ ! -e cfg.json ]
}

@test "--dry-run runs the session and writes nothing" {
    GEN_ARGS=(--config-only --output cfg.json --dry-run)
    ask none eng none "" "" y
    [ "$status" -eq 0 ]
    [ ! -e cfg.json ]
    [[ "$stderr" == *'"name": "eng"'* ]]
}

# --- warnings of the options -----------------------------------------------------------------

# a chat interface whose option allow-registration warns when it is true, like LibreChat's
make_warning_chat() {
    make_fake chat-interface chat '["proxy"]' '[{"name":"allow-registration","default":"true","secret":false,"description":"open","warn":{"when":"true","message":"registration is open"}}]'
}

@test "the summary of a session shows the warning of an option left at its default" {
    make_warning_chat
    GEN_ARGS=(--config-only --output cfg.json)
    ask prox none chat "" y
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"[WARN] to read before creating the VM"* ]]
    [[ "$stderr" == *"chat --allow-registration=true: registration is open"* ]]
}

@test "--config shows the warning of a default, and of an explicit value that matches" {
    make_warning_chat
    echo '{"schema_version":1,"components":[{"type":"proxy","name":"prox"},{"type":"chat-interface","name":"chat"}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"chat --allow-registration=true: registration is open"* ]]
    echo '{"schema_version":1,"components":[{"type":"proxy","name":"prox"},{"type":"chat-interface","name":"chat","options":{"allow-registration":"true"}}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [[ "$stderr" == *"chat --allow-registration=true: registration is open"* ]]
}

@test "no warning when the option has another value, whatever its type" {
    make_warning_chat
    echo '{"schema_version":1,"components":[{"type":"proxy","name":"prox"},{"type":"chat-interface","name":"chat","options":{"allow-registration":"false"}}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"to read before creating the VM"* ]]
    echo '{"schema_version":1,"components":[{"type":"proxy","name":"prox"},{"type":"chat-interface","name":"chat","options":{"allow-registration":false}}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [[ "$stderr" != *"to read before creating the VM"* ]]
}

@test "no warning section for components without a warning" {
    valid_config
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"to read before creating the VM"* ]]
}

@test "the real LibreChat script makes the generator warn about its open registration" {
    rm -f "$EASY_CS_AI_HOME/chat-interface/chat.sh"
    cp "$REAL/chat-interface/librechat.sh" "$EASY_CS_AI_HOME/chat-interface/librechat.sh"
    cp "$REAL/proxy/nginx.sh" "$EASY_CS_AI_HOME/proxy/nginx.sh"
    ln -s "$REAL/templates" "$EASY_CS_AI_HOME/templates"
    echo '{"schema_version":1,"components":[{"type":"proxy","name":"nginx"},{"type":"chat-interface","name":"librechat"}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"librechat --allow-registration=true: registration is open: the first account created becomes the administrator"* ]]
    echo '{"schema_version":1,"components":[{"type":"proxy","name":"nginx"},{"type":"chat-interface","name":"librechat","options":{"allow-registration":"false"}}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [[ "$stderr" != *"registration is open"* ]]
}

# --- --config ---------------------------------------------------------------------------------

valid_config() {
    cat >cfg.json <<'JSON'
{"schema_version":1,"components":[{"type":"proxy","name":"prox"},{"type":"engine","name":"eng","options":{"port":"9"}},{"type":"chat-interface","name":"chat"}],"models":[{"name":"m1"}]}
JSON
}

@test "--config: no prompt, summary on stderr, script written" {
    valid_config
    gen --config cfg.json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"components, in install order"* ]]
    [ -x vm.sh ]
}

@test "--config: each validation problem exits 2 with its path, an incomplete file too" {
    echo '{"schema_version":1,"components":[{"type":"engine","name":"nope"}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *'$.components[0].name: unknown engine "nope"'* ]]
    echo '{"schema_version":1,"components":[{"type":"chat-interface","name":"chat"}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"proxy is required by chat"* ]]
    echo '{nope' >cfg.json
    gen --config cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
    gen --config missing.json "${PKG[@]}"
    [ "$status" -eq 2 ]
}

@test "--config ignores what is installed on the generator machine" {
    mkdir -p "$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/components"
    echo '{"name":"prox","type":"proxy"}' >"$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/components/prox.json"
    echo '{"schema_version":1,"components":[{"type":"chat-interface","name":"chat"}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}"
    [ "$status" -eq 2 ]
}

@test "a configuration written by --config-only gives the same script as the session" {
    GEN_ARGS=("${PKG[@]}" --output a.sh)
    ask none eng none "" "m1" y
    [ "$status" -eq 0 ]
    GEN_ARGS=(--config-only --output cfg.json)
    ask none eng none "" "m1" y
    gen --config cfg.json "${PKG[@]}" --output b.sh
    [ "$status" -eq 0 ]
    diff <(grep -v '^# easy-cs-ai VM' a.sh) <(grep -v '^# easy-cs-ai VM' b.sh)
}

# --- generated script ---------------------------------------------------------------------------

embedded_config() { sed -n "/<<'EASY_CS_AI_CONFIG'/,/^EASY_CS_AI_CONFIG\$/p" "$1" | sed '1d;$d'; }

@test "the script pins the package, records the build and embeds the configuration untouched" {
    valid_config
    gen --config cfg.json "${PKG[@]}" --output vm.sh
    bash -n vm.sh
    grep -q "^PACKAGE_VERSION='0.1.0'" vm.sh
    grep -q "^PACKAGE_SHA256='$SHA'" vm.sh
    grep -q "^PACKAGE_URL='https://github.com/Dimsi-BS/easy-cs-ai/releases/download/v0.1.0/easy-cs-ai_0.1.0_all.deb'" vm.sh
    grep -q '^# component: engine eng 9.9 --port=9' vm.sh
    grep -q '^# package: easy-cs-ai 0.1.0 (deb)' vm.sh
    diff <(embedded_config vm.sh) <(jq . cfg.json)
}

@test "nothing in the configuration is expanded" {
    printf '%s' '{"schema_version":1,"components":[{"type":"engine","name":"eng","options":{"port":"$(touch pwned) `id` & \\ $HOME"}}]}' >cfg.json
    gen --config cfg.json "${PKG[@]}" --output vm.sh
    diff <(embedded_config vm.sh) <(jq . cfg.json)
}

@test "package formats and options set the URL and the file type" {
    valid_config
    gen --config cfg.json "${PKG[@]}" --package-format rpm --output vm.sh
    grep -q "easy-cs-ai-0.1.0-1.noarch.rpm'" vm.sh
    grep -q "^PACKAGE_FORMAT='rpm'" vm.sh
    gen --config cfg.json "${PKG[@]}" --package-format tarball --package-url https://mirror.local/x.tgz --output vm.sh
    grep -q "^PACKAGE_URL='https://mirror.local/x.tgz'" vm.sh
    grep -q "^PACKAGE_FORMAT='tar.gz'" vm.sh
}

@test "the checksum comes from a local file, else it is an error (exit 5), never omitted" {
    valid_config
    printf 'pkg' >pkg.deb
    gen --config cfg.json --package-version 0.1.0 --package-file pkg.deb --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_SHA256='$(sha256sum pkg.deb | cut -d' ' -f1)'" vm.sh
    gen --config cfg.json --package-version 0.1.0 --package-url file:///nonexistent/x.deb --output vm2.sh
    [ "$status" -eq 5 ]
    [ ! -e vm2.sh ]
    gen --config cfg.json --package-version 0.1.0 --package-sha256 zz --output vm2.sh
    [ "$status" -eq 5 ]
}

@test "the checksum is read from <url>.sha256 when it exists" {
    valid_config
    printf '%s  x.deb\n' "$SHA" >x.deb.sha256
    gen --config cfg.json --package-version 0.1.0 --package-url "file://$PWD/x.deb" --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_SHA256='$SHA'" vm.sh
}

@test "the package version is required when the CLI does not give it" {
    valid_config
    gen --config cfg.json --package-sha256 "$SHA"
    [ "$status" -eq 2 ]
    EASY_CS_AI_CLI_VERSION=0.3.0 gen --config cfg.json --package-sha256 "$SHA" --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_VERSION='0.3.0'" vm.sh
}

@test "the generated script is shellcheck clean" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    valid_config
    gen --config cfg.json "${PKG[@]}" --output vm.sh
    shellcheck vm.sh
}

@test "the generated script refuses to run as a normal user, and stays small" {
    valid_config
    gen --config cfg.json "${PKG[@]}" --output vm.sh
    [ "$(wc -c <vm.sh)" -lt 8192 ]
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    run bash vm.sh
    [ "$status" -eq 4 ]
}

@test "--dry-run prints the script and writes nothing" {
    valid_config
    gen --config cfg.json "${PKG[@]}" --output vm.sh --dry-run
    [ "$status" -eq 0 ]
    [ ! -e vm.sh ]
    [[ "$stderr" == *"PACKAGE_VERSION='0.1.0'"* ]]
}

# --- through the CLI ------------------------------------------------------------------------------

@test "easy-cs-ai generate hands over to the generator with the CLI version" {
    ln -s "${BATS_TEST_DIRNAME}/../../vm_script" "$BATS_TEST_TMPDIR/vm_script"
    valid_config
    run --separate-stderr bash "$CLI" generate --config cfg.json --package-sha256 "$SHA" --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_VERSION='$(sed -n 's/^readonly CLI_VERSION=//p' "$CLI")'" vm.sh
    run --separate-stderr bash "$CLI" --dry-run generate --config cfg.json --package-sha256 "$SHA" --output vm2.sh
    [ ! -e vm2.sh ]
}

# --- --json (docs/spec-ai-interface.md) ---------------------------------------------------

@test "--json needs --config: a session is interactive" {
    gen --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "--config --json: the validation document extended with the script, one document on stdout" {
    valid_config
    gen --config cfg.json --json "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [ "$(jq -s 'length' <<<"$output")" = 1 ]
    run jq -c '[.ok, .target, .errors, .script.path, .script.written, .script.package_version, .script.package_format, (.script.bytes > 0), (.plan.components | length > 0)]' <<<"$output"
    [ "$output" = '[true,"fresh",[],"vm.sh",true,"0.1.0","deb",true,true]' ]
    [ -x vm.sh ]
}

@test "--config --json --dry-run writes nothing and says so" {
    valid_config
    gen --config cfg.json --json --dry-run "${PKG[@]}" --output vm.sh </dev/null
    [ "$status" -eq 0 ]
    [ "$(jq -r '.script.written' <<<"$output")" = "false" ]
    [ ! -e vm.sh ]
}

@test "--config --json of an invalid or incomplete file: the document with its errors, exit 2, no script" {
    echo '{"schema_version":1,"components":[{"type":"chat-interface","name":"chat"}]}' >cfg.json
    gen --config cfg.json --json "${PKG[@]}" --output vm.sh
    [ "$status" -eq 2 ]
    run jq -c '[.ok, .errors[0].code, .script, .plan]' <<<"$output"
    [ "$output" = '[false,"missing_requirement",null,null]' ]
    [ ! -e vm.sh ]
    echo '{nope' >cfg.json
    gen --config cfg.json --json "${PKG[@]}"
    [ "$status" -eq 2 ]
    [ "$(jq -r '.errors[0].code' <<<"$output")" = "not_json" ]
}

@test "easy-cs-ai generate forwards --json, before or after the command" {
    valid_config
    ln -s "${BATS_TEST_DIRNAME}/../../vm_script" "$BATS_TEST_TMPDIR/vm_script"
    run --separate-stderr bash "$CLI" --json generate --config cfg.json --dry-run "${PKG[@]}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ok' <<<"$output")" = "true" ]
    run --separate-stderr bash "$CLI" generate --config cfg.json --json --dry-run "${PKG[@]}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.script.written' <<<"$output")" = "false" ]
}
