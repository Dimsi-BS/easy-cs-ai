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
