#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
}

@test "log_info writes [INFO] to stderr and nothing to stdout" {
    run --separate-stderr bash -c "source '$LIB'; log_info hello world"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = "[INFO] hello world" ]
}

@test "log_warn and log_error use their level" {
    run --separate-stderr bash -c "source '$LIB'; log_warn a; log_error b"
    [ "${stderr_lines[0]}" = "[WARN] a" ]
    [ "${stderr_lines[1]}" = "[ERROR] b" ]
}

@test "log_debug is silent by default" {
    run --separate-stderr bash -c "source '$LIB'; log_debug hidden"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "log_debug prints when EASY_CS_AI_VERBOSE=1" {
    run --separate-stderr bash -c "export EASY_CS_AI_VERBOSE=1; source '$LIB'; log_debug shown"
    [ "$stderr" = "[DEBUG] shown" ]
}

@test "die logs the message and exits with the given code" {
    run --separate-stderr bash -c "source '$LIB'; die 4 'not root'"
    [ "$status" -eq 4 ]
    [ "$stderr" = "[ERROR] not root" ]
}

@test "die defaults to exit code 1" {
    run bash -c "source '$LIB'; die"
    [ "$status" -eq 1 ]
}

@test "sourcing twice is harmless" {
    run bash -c "source '$LIB'; source '$LIB'; log_info ok"
    [ "$status" -eq 0 ]
}

@test "logs are plain when stderr is not a terminal" {
    run --separate-stderr bash -c "source '$LIB'; log_error b"
    [ "$stderr" = "[ERROR] b" ]
}

@test "EASY_CS_AI_COLOR=always colors errors and warnings on the whole line" {
    run --separate-stderr bash -c "export EASY_CS_AI_COLOR=always; source '$LIB'; log_error b; log_warn c"
    [ "${stderr_lines[0]}" = $'\033[1;31m[ERROR] b\033[0m' ]
    [ "${stderr_lines[1]}" = $'\033[1;33m[WARN] c\033[0m' ]
}

@test "EASY_CS_AI_COLOR=always colors only the tag of an info line, and dims a debug line" {
    run --separate-stderr bash -c "export EASY_CS_AI_COLOR=always EASY_CS_AI_VERBOSE=1; source '$LIB'; log_info a; log_debug d"
    [ "${stderr_lines[0]}" = $'[\033[32mINFO\033[0m] a' ]
    [ "${stderr_lines[1]}" = $'\033[2m[DEBUG] d\033[0m' ]
}

@test "NO_COLOR and EASY_CS_AI_COLOR=never turn the colors off" {
    run --separate-stderr bash -c "export NO_COLOR=1; source '$LIB'; log_warn a"
    [ "$stderr" = "[WARN] a" ]
    run --separate-stderr bash -c "export EASY_CS_AI_COLOR=never; source '$LIB'; log_warn a"
    [ "$stderr" = "[WARN] a" ]
}

# --- the appearance of the text for a person (docs/spec-rendering.md#appearance) ----------

@test "style adds the colour of its role only when colour is on, and never anywhere else" {
    run bash -c "export EASY_CS_AI_COLOR=never; source '$LIB'; style ok done; style bogus x"
    [ "$output" = "donex" ]
    run bash -c "export EASY_CS_AI_COLOR=always; source '$LIB'; style ok done"
    [ "$output" = $'\033[32mdone\033[0m' ]
    run bash -c "export NO_COLOR=1 EASY_CS_AI_COLOR=auto; source '$LIB'; style error bad"
    [ "$output" = "bad" ]
}

@test "sym draws a glyph in Unicode and a word in ASCII, so no meaning rests on a glyph or a colour" {
    run bash -c "export EASY_CS_AI_COLOR=never EASY_CS_AI_CHARSET=unicode; source '$LIB'; sym ok; sym warn; sym error"
    [ "$output" = "✓!✗" ]
    run bash -c "export EASY_CS_AI_COLOR=never EASY_CS_AI_CHARSET=ascii; source '$LIB'; sym ok; sym warn; sym error"
    [ "$output" = "ok[WARN][ERROR]" ]
}

@test "rule is a titled rule of the width of the terminal, at most 100, in ASCII or Unicode" {
    run bash -c "export EASY_CS_AI_COLOR=never EASY_CS_AI_CHARSET=ascii COLUMNS=30; source '$LIB'; rule 'VM 1 of 2 · web'"
    [ "$output" = "== VM 1 of 2 · web -----------" ]
    run bash -c "export EASY_CS_AI_COLOR=never EASY_CS_AI_CHARSET=unicode COLUMNS=20; source '$LIB'; rule web"
    [ "$output" = "━━ web ─────────────" ]
    run bash -c "export EASY_CS_AI_COLOR=never EASY_CS_AI_CHARSET=ascii COLUMNS=300; source '$LIB'; rule x"
    [ "${#output}" -eq 100 ]
}

@test "wrap breaks at the width, indents every line and never cuts a word" {
    run bash -c "export COLUMNS=24; source '$LIB'; wrap 2 'one two three four five six seven'"
    [ "${lines[0]}" = "  one two three four" ]
    [ "${lines[1]}" = "  five six seven" ]
    [ "${#lines[@]}" -eq 2 ]
}
