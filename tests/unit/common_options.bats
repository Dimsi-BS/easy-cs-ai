#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
    unset EASY_CS_AI_OLLAMA_PORT EASY_CS_AI_VERBOSE
}

# --- option variables -------------------------------------------------------

@test "option_var builds the upper snake case name" {
    run bash -c "source '$LIB'; option_var ollama health-timeout"
    [ "$output" = "EASY_CS_AI_OLLAMA_HEALTH_TIMEOUT" ]
}

@test "default applies when nothing else is set" {
    run bash -c "source '$LIB'; set_option_default ollama port 11434; get_option ollama port"
    [ "$output" = "11434" ]
}

@test "environment beats the default" {
    run bash -c "export EASY_CS_AI_OLLAMA_PORT=9000; source '$LIB'; set_option_default ollama port 11434; get_option ollama port"
    [ "$output" = "9000" ]
}

@test "command line beats environment and default" {
    run bash -c "export EASY_CS_AI_OLLAMA_PORT=9000; source '$LIB'; set_option ollama port 8000; set_option_default ollama port 11434; get_option ollama port"
    [ "$output" = "8000" ]
}

@test "options are exported to child processes" {
    run bash -c "source '$LIB'; set_option ollama port 8000; bash -c 'echo \$EASY_CS_AI_OLLAMA_PORT'"
    [ "$output" = "8000" ]
}

# --- parse_common_options ---------------------------------------------------

@test "parse_common_options sets the flags and keeps the rest in order" {
    run bash -c "source '$LIB'; parse_common_options --port 80 --verbose --dry-run --json --help --version name; \
        wants_help && wants_version && is_dry_run && wants_json && echo all-set; \
        echo \"\${COMMON_REST[*]}\""
    [ "${lines[0]}" = "all-set" ]
    [ "${lines[1]}" = "--port 80 name" ]
}

@test "the flags are all off by default" {
    run bash -c "source '$LIB'; wants_help || wants_version || is_dry_run || wants_json || echo none"
    [ "$output" = "none" ]
}

@test "a call to parse_common_options resets the flags of the previous one" {
    run bash -c "source '$LIB'; parse_common_options --json; parse_common_options x; wants_json || echo reset"
    [ "$output" = "reset" ]
}

@test "the flags are not read from nor exported to the environment" {
    run bash -c "export EASY_CS_AI_DRY_RUN=1 EASY_CS_AI_JSON=1 _OPT_JSON=1; source '$LIB'; is_dry_run || wants_json || echo ignored"
    [ "$output" = "ignored" ]
    run bash -c "source '$LIB'; parse_common_options --dry-run --json; env | grep -c 'DRY_RUN\|_OPT_\|JSON' || true"
    [ "$output" = "0" ]
}

@test "parse_common_options keeps arguments with spaces intact" {
    run bash -c "source '$LIB'; parse_common_options 'a b' --json c; echo \${#COMMON_REST[@]}"
    [ "$output" = "2" ]
}

@test "--verbose is exported so child scripts get debug logging too" {
    run bash -c "source '$LIB'; parse_common_options --verbose; bash -c 'echo \$EASY_CS_AI_VERBOSE'"
    [ "$output" = "1" ]
}

@test "--verbose turns debug logging on" {
    run --separate-stderr bash -c "source '$LIB'; parse_common_options --verbose; log_debug hi"
    [ "$stderr" = "[DEBUG] hi" ]
}

@test "reject_unknown_options exits 2 on a leftover option" {
    run --separate-stderr bash -c "source '$LIB'; reject_unknown_options model --bogus"
    [ "$status" -eq 2 ]
    [ "$stderr" = "[ERROR] unknown option: --bogus" ]
}

@test "reject_unknown_options accepts plain arguments and a lone dash" {
    run bash -c "source '$LIB'; reject_unknown_options model - other"
    [ "$status" -eq 0 ]
}

# --- secrets ----------------------------------------------------------------

@test "read_secret reads a 0600 file" {
    f="$BATS_TEST_TMPDIR/key"
    printf 's3cret\n' >"$f"
    chmod 600 "$f"
    run bash -c "source '$LIB'; read_secret '$f'"
    [ "$status" -eq 0 ]
    [ "$output" = "s3cret" ]
}

@test "read_secret refuses a file readable by others, exit 2, without leaking it" {
    f="$BATS_TEST_TMPDIR/key"
    printf 's3cret\n' >"$f"
    chmod 644 "$f"
    run --separate-stderr bash -c "source '$LIB'; read_secret '$f'"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"mode 644, 600 or stricter required"* ]]
    [[ "$stderr" != *s3cret* ]]
}

@test "read_secret accepts 0400" {
    f="$BATS_TEST_TMPDIR/key"
    printf 's3cret\n' >"$f"
    chmod 400 "$f"
    run bash -c "source '$LIB'; read_secret '$f'"
    [ "$output" = "s3cret" ]
}

@test "read_secret reads stdin with -" {
    run bash -c "source '$LIB'; echo piped | read_secret -"
    [ "$output" = "piped" ]
}

@test "read_secret fails on a missing file and on an empty secret" {
    run bash -c "source '$LIB'; read_secret '$BATS_TEST_TMPDIR/nope'"
    [ "$status" -eq 2 ]
    f="$BATS_TEST_TMPDIR/empty"
    : >"$f"
    chmod 600 "$f"
    run bash -c "source '$LIB'; read_secret '$f'"
    [ "$status" -eq 2 ]
}

@test "generate_secret gives 43 base64url characters, different each time" {
    run bash -c "source '$LIB'; generate_secret; generate_secret"
    [[ "${lines[0]}" =~ ^[A-Za-z0-9_-]{43}$ ]]
    [ "${lines[0]}" != "${lines[1]}" ]
}
