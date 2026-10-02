#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
    unset EASY_CS_AI_ROOT
}

teardown() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
}

start_server() {
    SERVER_DIR="$BATS_TEST_TMPDIR/www"
    mkdir -p "$SERVER_DIR"
    echo ok >"$SERVER_DIR/health"
    python3 -m http.server "$1" --bind 127.0.0.1 --directory "$SERVER_DIR" >/dev/null 2>&1 &
    SERVER_PID=$!
}

# --- require_root -----------------------------------------------------------

@test "require_root is skipped in test mode" {
    run bash -c "export EASY_CS_AI_ROOT=/tmp/x; source '$LIB'; require_root"
    [ "$status" -eq 0 ]
}

@test "require_root fails with exit 4 for a non-root user" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    run --separate-stderr bash -c "source '$LIB'; require_root"
    [ "$status" -eq 4 ]
    [ "$stderr" = "[ERROR] this action must run as root" ]
}

# --- log_event --------------------------------------------------------------

@test "log_event goes to stderr in test mode, as an INFO line flagged as test" {
    run --separate-stderr bash -c "export EASY_CS_AI_ROOT=/tmp/x; source '$LIB'; log_event ollama install start"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" = "[INFO] (journal, test mode) ollama install start" ]
}

@test "log_event uses logger with the easy-cs-ai tag outside test mode" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho "$@" >"%s/logger.out"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/logger"
    chmod +x "$BATS_TEST_TMPDIR/bin/logger"
    run bash -c "export PATH='$BATS_TEST_TMPDIR/bin':\$PATH; source '$LIB'; log_event ollama install end exit=0"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/logger.out")" = "-t easy-cs-ai -- ollama install end exit=0" ]
}

# --- wait_for_http ----------------------------------------------------------

@test "wait_for_http succeeds when the URL answers" {
    start_server 18741
    sleep 1
    run bash -c "source '$LIB'; wait_for_http http://127.0.0.1:18741/health 10 '' 1"
    [ "$status" -eq 0 ]
}

@test "wait_for_http succeeds when the server comes up during the wait" {
    (sleep 2; exec python3 -m http.server 18742 --bind 127.0.0.1 --directory "$BATS_TEST_TMPDIR") >/dev/null 2>&1 &
    SERVER_PID=$!
    echo ok >"$BATS_TEST_TMPDIR/health"
    run bash -c "source '$LIB'; wait_for_http http://127.0.0.1:18742/health 15 '' 1"
    [ "$status" -eq 0 ]
}

@test "wait_for_http returns 6 on timeout and reports the last probe" {
    run --separate-stderr bash -c "source '$LIB'; wait_for_http http://127.0.0.1:18799/health 2 '' 1"
    [ "$status" -eq 6 ]
    [[ "$stderr" == *"[ERROR] health check timed out after 2s on http://127.0.0.1:18799/health"* ]]
}

@test "wait_for_http returns 6 on an HTTP error status" {
    start_server 18743
    sleep 1
    run bash -c "source '$LIB'; wait_for_http http://127.0.0.1:18743/missing 2 '' 1"
    [ "$status" -eq 6 ]
}

@test "wait_for_http rejects bad arguments with exit 2" {
    run bash -c "source '$LIB'; wait_for_http http://x abc"
    [ "$status" -eq 2 ]
    run bash -c "source '$LIB'; wait_for_http http://x 5 '' soon"
    [ "$status" -eq 2 ]
}
