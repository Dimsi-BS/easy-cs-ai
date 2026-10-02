#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
    unset EASY_CS_AI_ROOT EASY_CS_AI_STATE_DIR EASY_CS_AI_CONFIG_DIR
}

@test "is_test_root is false by default and for /" {
    run bash -c "source '$LIB'; is_test_root"
    [ "$status" -ne 0 ]
    run bash -c "export EASY_CS_AI_ROOT=/; source '$LIB'; is_test_root"
    [ "$status" -ne 0 ]
}

@test "is_test_root is true with a prefix" {
    run bash -c "export EASY_CS_AI_ROOT=/tmp/x; source '$LIB'; is_test_root"
    [ "$status" -eq 0 ]
}

@test "root_path leaves the path alone without a prefix" {
    run bash -c "source '$LIB'; root_path /etc/foo"
    [ "$output" = "/etc/foo" ]
}

@test "root_path applies the prefix, with or without trailing slash" {
    run bash -c "export EASY_CS_AI_ROOT=/tmp/x; source '$LIB'; root_path /etc/foo"
    [ "$output" = "/tmp/x/etc/foo" ]
    run bash -c "export EASY_CS_AI_ROOT=/tmp/x/; source '$LIB'; root_path /etc/foo"
    [ "$output" = "/tmp/x/etc/foo" ]
}

@test "root_path rejects a relative path" {
    run --separate-stderr bash -c "source '$LIB'; root_path etc/foo"
    [ "$status" -eq 1 ]
    [[ "$stderr" == "[ERROR] root_path: absolute path expected"* ]]
}

@test "state_dir and config_dir use defaults under the prefix" {
    run bash -c "export EASY_CS_AI_ROOT=/tmp/x; source '$LIB'; state_dir; config_dir"
    [ "${lines[0]}" = "/tmp/x/var/lib/easy-cs-ai" ]
    [ "${lines[1]}" = "/tmp/x/etc/easy-cs-ai" ]
}

@test "state_dir honours EASY_CS_AI_STATE_DIR" {
    run bash -c "export EASY_CS_AI_ROOT=/tmp/x EASY_CS_AI_STATE_DIR=/srv/s; source '$LIB'; state_dir"
    [ "$output" = "/tmp/x/srv/s" ]
}
