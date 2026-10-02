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
