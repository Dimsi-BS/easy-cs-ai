#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    STATE="$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/components"
    unset EASY_CS_AI_STATE_DIR EASY_CS_AI_LOCK_HELD
}

# sh <code>: run bash code with the library loaded.
sh() { run bash -c "source '$LIB'; $1"; }

comp() { printf '{"name":"%s","type":"%s","version":"1.0"}' "$1" "$2"; }

# --- state_write / state_read -----------------------------------------------

@test "state_write creates the file with schema, dates and default" {
    sh "state_write ollama '$(comp ollama engine)'"
    [ "$status" -eq 0 ]
    [ -f "$STATE/ollama.json" ]
    run jq -r '.schema_version, .name, .default, .version' "$STATE/ollama.json"
    [ "${lines[0]}" = "1" ]
    [ "${lines[1]}" = "ollama" ]
    [ "${lines[2]}" = "true" ]
    [ "${lines[3]}" = "1.0" ]
    run jq -r '.installed_at, .updated_at' "$STATE/ollama.json"
    [[ "${lines[0]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
    [ "${lines[0]}" = "${lines[1]}" ]
}

@test "state files are mode 0644 and leave no temporary file" {
    sh "state_write ollama '$(comp ollama engine)'"
    [ "$(stat -c %a "$STATE/ollama.json")" = "644" ]
    [ "$(ls -A "$STATE" | wc -l)" -eq 1 ]
}

@test "state_read prints the state and returns 1 for an unknown component" {
    sh "state_write ollama '$(comp ollama engine)'; state_read ollama | jq -r .name"
    [ "$output" = "ollama" ]
    run bash -c "source '$LIB'; state_read nothing"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "state_write is a no-op when the content is unchanged, updated_at included" {
    sh "state_write ollama '$(comp ollama engine)'"
    before="$(cat "$STATE/ollama.json")"
    sleep 1
    sh "state_write ollama '$(comp ollama engine)'"
    [ "$(cat "$STATE/ollama.json")" = "$before" ]
}

@test "state_write changes updated_at, keeps installed_at when the content changes" {
    sh "state_write ollama '$(comp ollama engine)'"
    first_installed="$(jq -r .installed_at "$STATE/ollama.json")"
    sleep 1
    sh "state_write ollama '{\"name\":\"ollama\",\"type\":\"engine\",\"version\":\"2.0\"}'"
    [ "$(jq -r .version "$STATE/ollama.json")" = "2.0" ]
    [ "$(jq -r .installed_at "$STATE/ollama.json")" = "$first_installed" ]
    [ "$(jq -r .updated_at "$STATE/ollama.json")" != "$first_installed" ]
}

@test "state_write keeps the fields it does not know" {
    sh "state_write ollama '$(comp ollama engine)'"
    jq '.future_field = {"a": 1}' "$STATE/ollama.json" >"$BATS_TEST_TMPDIR/x" && mv "$BATS_TEST_TMPDIR/x" "$STATE/ollama.json"
    sh "state_write ollama '{\"name\":\"ollama\",\"type\":\"engine\",\"version\":\"3.0\"}'"
    [ "$(jq -c .future_field "$STATE/ollama.json")" = '{"a":1}' ]
    [ "$(jq -r .version "$STATE/ollama.json")" = "3.0" ]
}

@test "state_write rejects bad input without writing anything" {
    run --separate-stderr bash -c "source '$LIB'; state_write ollama 'not json'"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a JSON object"* ]]
    run --separate-stderr bash -c "source '$LIB'; state_write ollama '$(comp other engine)'"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'different or missing "name"'* ]]
    run --separate-stderr bash -c "source '$LIB'; state_write ollama '$(comp ollama nonsense)'"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'invalid or missing "type"'* ]]
    [ ! -e "$STATE/ollama.json" ]
}

@test "component names cannot be paths" {
    run --separate-stderr bash -c "source '$LIB'; state_write ../evil '$(comp ../evil engine)'"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"invalid component name"* ]]
    run bash -c "source '$LIB'; state_read 'a/b'"
    [ "$status" -eq 2 ]
}

@test "state_read refuses a newer schema and a damaged file" {
    mkdir -p "$STATE"
    echo '{"schema_version": 2, "name": "x"}' >"$STATE/x.json"
    run --separate-stderr bash -c "source '$LIB'; state_read x"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"schema_version 2, this version understands up to 1"* ]]
    echo 'garbage' >"$STATE/y.json"
    run --separate-stderr bash -c "source '$LIB'; state_read y"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not valid"* ]]
}

@test "state functions need jq (exit 4 when missing)" {
    run --separate-stderr bash -c "source '$LIB'; PATH=/nonexistent; state_read ollama"
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"jq is required"* ]]
}

# --- state_list -------------------------------------------------------------

@test "state_list lists names, optionally of one type" {
    sh "state_write ollama '$(comp ollama engine)'; state_write nginx '$(comp nginx proxy)'; state_write vllm '$(comp vllm engine)'; state_list"
    [ "$output" = $'nginx\nollama\nvllm' ]
    sh "state_list engine"
    [ "$output" = $'ollama\nvllm' ]
    sh "state_list chat-interface"
    [ -z "$output" ]
}

# --- defaults ---------------------------------------------------------------

@test "only the first component of a type becomes its default" {
    sh "state_write ollama '$(comp ollama engine)'; state_write vllm '$(comp vllm engine)'; \
        state_write nginx '$(comp nginx proxy)'"
    [ "$(jq .default "$STATE/ollama.json")" = "true" ]
    [ "$(jq .default "$STATE/vllm.json")" = "false" ]
    [ "$(jq .default "$STATE/nginx.json")" = "true" ]
}

@test "defaults_get prints the default of a type, returns 1 without one" {
    sh "state_write ollama '$(comp ollama engine)'; state_write vllm '$(comp vllm engine)'; defaults_get engine"
    [ "$output" = "ollama" ]
    run bash -c "source '$LIB'; defaults_get chat-interface"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "defaults_set moves the default, new flag first, others cleared" {
    sh "state_write ollama '$(comp ollama engine)'; state_write vllm '$(comp vllm engine)'; \
        defaults_set engine vllm; defaults_get engine"
    [ "$output" = "vllm" ]
    [ "$(jq .default "$STATE/ollama.json")" = "false" ]
}

@test "defaults_set refuses an unknown component or the wrong type, exit 4" {
    sh "state_write ollama '$(comp ollama engine)'; defaults_set engine ghost"
    [ "$status" -eq 4 ]
    sh "defaults_set proxy ollama"
    [ "$status" -eq 4 ]
}

@test "state_write with default true takes the default and clears the other" {
    sh "state_write ollama '$(comp ollama engine)'; \
        state_write vllm '{\"name\":\"vllm\",\"type\":\"engine\",\"default\":true}'; defaults_get engine"
    [ "$output" = "vllm" ]
    [ "$(jq .default "$STATE/ollama.json")" = "false" ]
}

@test "defaults_get re-reads once, then fails naming the candidates when there are two defaults" {
    sh "state_write ollama '$(comp ollama engine)'; state_write vllm '$(comp vllm engine)'"
    jq '.default = true' "$STATE/vllm.json" >"$BATS_TEST_TMPDIR/x" && mv "$BATS_TEST_TMPDIR/x" "$STATE/vllm.json"
    run --separate-stderr bash -c "source '$LIB'; defaults_get engine"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"several defaults for type engine (ollama vllm"* ]]
    # Repair: defaults_set clears all the others.
    sh "defaults_set engine ollama; defaults_get engine"
    [ "$output" = "ollama" ]
}

# --- state_remove -----------------------------------------------------------

@test "state_remove deletes the file and is a no-op when absent" {
    sh "state_write ollama '$(comp ollama engine)'; state_remove ollama; state_remove ollama"
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/ollama.json" ]
}

@test "removing the default promotes the only remaining component of the type" {
    sh "state_write ollama '$(comp ollama engine)'; state_write vllm '$(comp vllm engine)'; \
        state_remove ollama; defaults_get engine"
    [ "$output" = "vllm" ]
}

@test "removing the default with several left leaves the type without default" {
    sh "state_write ollama '$(comp ollama engine)'; state_write vllm '$(comp vllm engine)'; \
        state_write localai '$(comp localai engine)'; state_remove ollama"
    run bash -c "source '$LIB'; defaults_get engine"
    [ "$status" -eq 1 ]
}

@test "removing a non default component does not touch the default" {
    sh "state_write ollama '$(comp ollama engine)'; state_write vllm '$(comp vllm engine)'; \
        state_remove vllm; defaults_get engine"
    [ "$output" = "ollama" ]
}

# --- concurrency and locking ------------------------------------------------

@test "parallel writers never corrupt the state" {
    for i in 1 2 3 4 5 6; do
        bash -c "source '$LIB'; state_write c$i '$(comp "c$i" engine)'" &
    done
    wait
    run bash -c "source '$LIB'; state_list | wc -l"
    [ "$output" = "6" ]
    for i in 1 2 3 4 5 6; do
        jq empty "$STATE/c$i.json"
    done
    [ "$(cat "$STATE"/*.json | jq -s '[.[] | select(.default == true)] | length')" = "1" ]
}

@test "state helpers are not reentrant under the state lock" {
    run --separate-stderr bash -c "source '$LIB'; with_state_lock state_remove ollama"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"lock 'state' is already held"* ]]
}

@test "state_write works inside a component lock (component first, then state)" {
    sh "with_component_lock engine ollama install state_write ollama '$(comp ollama engine)'"
    [ "$status" -eq 0 ]
    [ -f "$STATE/ollama.json" ]
}
