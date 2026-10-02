#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    unset EASY_CS_AI_LOCK_HELD EASY_CS_AI_OLLAMA_LOCK_TIMEOUT
}

teardown() {
    if [[ -n "${HOLDER_PID:-}" ]]; then
        kill "$HOLDER_PID" 2>/dev/null || true
    fi
}

# hold_state_lock <seconds>: take the state lock in another process.
hold_state_lock() {
    bash -c "source '$LIB'; with_state_lock sleep $1" &
    HOLDER_PID=$!
    sleep 1
}

hold_component_lock() {
    bash -c "source '$LIB'; with_component_lock engine ollama install sleep $1" &
    HOLDER_PID=$!
    sleep 1
}

# --- state lock -------------------------------------------------------------

@test "with_state_lock runs the command and returns its status" {
    run bash -c "source '$LIB'; with_state_lock echo inside"
    [ "$status" -eq 0 ]
    [ "$output" = "inside" ]
    run bash -c "source '$LIB'; with_state_lock bash -c 'exit 7'"
    [ "$status" -eq 7 ]
}

@test "with_state_lock runs shell functions in the current shell" {
    run bash -c "source '$LIB'; f() { VALUE=set; }; with_state_lock f; echo \$VALUE"
    [ "$output" = "set" ]
}

@test "with_state_lock creates the lock file under the state directory" {
    run bash -c "source '$LIB'; with_state_lock true"
    [ -f "$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/.lock" ]
}

@test "with_state_lock times out with exit 1 when the lock is busy" {
    hold_state_lock 5
    run --separate-stderr bash -c "source '$LIB'; with_state_lock_timeout 1 true"
    [ "$status" -eq 1 ]
    [ "$stderr" = "[ERROR] could not take the state lock within 1s" ]
}

@test "with_state_lock waits for the lock to be released" {
    hold_state_lock 2
    run bash -c "source '$LIB'; with_state_lock_timeout 10 echo got-it"
    [ "$status" -eq 0 ]
    [ "$output" = "got-it" ]
}

@test "with_state_lock is released when the command ends" {
    run bash -c "source '$LIB'; with_state_lock_timeout 1 true; with_state_lock_timeout 1 true"
    [ "$status" -eq 0 ]
}

@test "a background child does not keep the state lock after the command ends" {
    run bash -c "source '$LIB'; with_state_lock bash -c 'sleep 5 &'; with_state_lock_timeout 1 echo free"
    [ "$status" -eq 0 ]
    [ "$output" = "free" ]
}

@test "with_state_lock is not reentrant: exit 1 instead of a hang" {
    run --separate-stderr bash -c "source '$LIB'; with_state_lock with_state_lock true"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"lock 'state' is already held"* ]]
}

@test "with_state_lock without a command, or with a bad timeout, is a usage error" {
    run bash -c "source '$LIB'; with_state_lock"
    [ "$status" -eq 2 ]
    run bash -c "source '$LIB'; with_state_lock_timeout soon true"
    [ "$status" -eq 2 ]
}

# --- component lock ---------------------------------------------------------

@test "with_component_lock runs the command and returns its status" {
    run bash -c "source '$LIB'; with_component_lock engine ollama test echo inside"
    [ "$status" -eq 0 ]
    [ "$output" = "inside" ]
    run bash -c "source '$LIB'; with_component_lock engine ollama test bash -c 'exit 5'"
    [ "$status" -eq 5 ]
}

@test "with_component_lock fails at once with exit 4 naming action and pid" {
    hold_component_lock 5
    run --separate-stderr bash -c "source '$LIB'; with_component_lock engine ollama test true"
    [ "$status" -eq 4 ]
    [[ "$stderr" =~ ^\[ERROR\]\ another\ action\ is\ running\ on\ ollama\ \(install,\ pid\ [0-9]+\)$ ]]
}

@test "with_component_lock waits when a lock timeout is given" {
    hold_component_lock 2
    export EASY_CS_AI_OLLAMA_LOCK_TIMEOUT=10
    run bash -c "source '$LIB'; with_component_lock engine ollama test echo got-it"
    [ "$status" -eq 0 ]
    [ "$output" = "got-it" ]
}

@test "locks of two different components do not block each other" {
    hold_component_lock 5
    run bash -c "source '$LIB'; with_component_lock proxy nginx test echo other"
    [ "$status" -eq 0 ]
    [ "$output" = "other" ]
}

@test "with_component_lock is not reentrant" {
    run --separate-stderr bash -c "source '$LIB'; with_component_lock engine ollama test with_component_lock engine ollama test true"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"lock 'component:engine-ollama' is already held"* ]]
}

@test "component lock then state lock is allowed, and the state lock is free after" {
    run bash -c "source '$LIB'; with_component_lock engine ollama test with_state_lock echo nested"
    [ "$status" -eq 0 ]
    [ "$output" = "nested" ]
}

@test "EASY_CS_AI_LOCK_HELD is restored after the command" {
    run bash -c "source '$LIB'; with_component_lock engine ollama test true; with_state_lock true; echo \"[\${EASY_CS_AI_LOCK_HELD}]\""
    [ "$output" = "[]" ]
}

@test "with_component_lock without a command is a usage error" {
    run bash -c "source '$LIB'; with_component_lock engine ollama test"
    [ "$status" -eq 2 ]
}

# --- robustness -------------------------------------------------------------

@test "with_component_lock rejects a non numeric lock timeout with exit 2" {
    export EASY_CS_AI_OLLAMA_LOCK_TIMEOUT=abc
    run --separate-stderr bash -c "source '$LIB'; with_component_lock engine ollama install echo ran"
    [ "$status" -eq 2 ]
    [ "$stderr" = "[ERROR] invalid lock timeout 'abc' for ollama: a number of seconds is expected" ]
}

@test "a relative state directory stops at once, without touching the filesystem, even without set -e" {
    export EASY_CS_AI_STATE_DIR=rel
    run --separate-stderr bash -c "source '$LIB'; with_state_lock echo ran-anyway"
    [ "$status" -eq 1 ]
    [ "$stderr" = "[ERROR] root_path: absolute path expected, got 'rel'" ]
    run --separate-stderr bash -c "source '$LIB'; with_component_lock engine ollama install echo ran-anyway"
    [ "$status" -eq 1 ]
    [ "$stderr" = "[ERROR] root_path: absolute path expected, got 'rel'" ]
}
