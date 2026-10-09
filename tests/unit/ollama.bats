#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../../install_scripts/engine/ollama.sh"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    SYS="$EASY_CS_AI_ROOT"
    STATE="$SYS/var/lib/easy-cs-ai"
    unset EASY_CS_AI_LOCK_HELD EASY_CS_AI_OLLAMA_PORT EASY_CS_AI_OLLAMA_BIND EASY_CS_AI_OLLAMA_VERSION
}

ollama() { run --separate-stderr bash "$SCRIPT" "$@"; }

# --- describe, help, usage -----------------------------------------------------

@test "describe prints valid metadata without root or state" {
    ollama describe
    [ "$status" -eq 0 ]
    run jq -r '.name, .type, .schema_version, .health_timeout, (.options | map(.name) | join(","))' <<<"$output"
    [ "${lines[0]}" = "ollama" ]
    [ "${lines[1]}" = "engine" ]
    [ "${lines[2]}" = "1" ]
    [ "${lines[3]}" = "60" ]
    [[ "${lines[4]}" == port,bind,version,* ]]
}

@test "describe lists every mandatory and engine action" {
    ollama describe
    run jq -r '.actions | join(" ")' <<<"$output"
    for a in install uninstall status describe add-model remove-model list-models; do
        [[ "$output" == *"$a"* ]]
    done
}

@test "--help and --version print on stdout and succeed" {
    ollama --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: ollama.sh"* ]]
    ollama install --version
    [ "$status" -eq 0 ]
    [ "$output" = "0.1.0" ]
}

@test "usage errors exit 2" {
    ollama
    [ "$status" -eq 2 ]
    ollama frobnicate
    [ "$status" -eq 2 ]
    ollama install --nope
    [ "$status" -eq 2 ]
    ollama install --port abc
    [ "$status" -eq 2 ]
    ollama install --port 70000
    [ "$status" -eq 2 ]
    ollama install --port
    [ "$status" -eq 2 ]
    ollama install --bind 'a b'
    [ "$status" -eq 2 ]
    ollama add-model
    [ "$status" -eq 2 ]
}

# --- install -----------------------------------------------------------------------

@test "install records the state, the unit and leaves no pending manifest" {
    ollama install
    [ "$status" -eq 0 ]
    [ -f "$SYS/etc/systemd/system/ollama.service" ]
    grep -q 'OLLAMA_HOST=127.0.0.1:11434' "$SYS/etc/systemd/system/ollama.service"
    run jq -r '.name, .type, .version, .default, .params.port, .params.bind, .endpoint.openai_base_url, .service.unit' \
        "$STATE/components/ollama.json"
    [ "${lines[0]}" = "ollama" ]
    [ "${lines[1]}" = "engine" ]
    [ "${lines[2]}" = "0.35.1" ]
    [ "${lines[3]}" = "true" ]
    [ "${lines[4]}" = "11434" ]
    [ "${lines[5]}" = "127.0.0.1" ]
    [ "${lines[6]}" = "http://127.0.0.1:11434/v1" ]
    [ "${lines[7]}" = "ollama.service" ]
    run jq -c '.files, .models' "$STATE/components/ollama.json"
    [[ "${lines[0]}" == *"/etc/systemd/system/ollama.service"* ]]
    [ "${lines[1]}" = "[]" ]
    [ ! -e "$STATE/pending/ollama.json" ]
}

@test "install writes to stdout nothing but logs go to stderr" {
    ollama install
    [ -z "$output" ]
    [[ "$stderr" == *"[INFO]"* ]]
}

@test "install journals start and end" {
    ollama install --port 11500
    [[ "$stderr" == *"ollama install start version=0.35.1 params=port=11500,bind=127.0.0.1"* ]]
    [[ "$stderr" == *"ollama install end exit=0"* ]]
}

@test "options come from the environment, the command line wins" {
    export EASY_CS_AI_OLLAMA_PORT=11600
    ollama install
    [ "$(jq -r .params.port "$STATE/components/ollama.json")" = "11600" ]
    ollama install --port 11700
    [ "$(jq -r .params.port "$STATE/components/ollama.json")" = "11700" ]
}

@test "--version <x> selects the Ollama version, --version=<x> too" {
    ollama install --version 0.36.0
    [ "$(jq -r .version "$STATE/components/ollama.json")" = "0.36.0" ]
    ollama install --version=0.36.1
    [ "$(jq -r .version "$STATE/components/ollama.json")" = "0.36.1" ]
}

@test "a second install with the same parameters changes nothing" {
    ollama install
    before="$(cat "$STATE/components/ollama.json")"
    ollama install
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"already installed"* ]]
    [ "$(cat "$STATE/components/ollama.json")" = "$before" ]
}

@test "install with another port re-renders the unit and updates the state" {
    ollama install
    ollama install --port 11500 --bind 0.0.0.0
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"already installed"* ]]
    grep -q 'OLLAMA_HOST=0.0.0.0:11500' "$SYS/etc/systemd/system/ollama.service"
    [ "$(jq -r .params.port "$STATE/components/ollama.json")" = "11500" ]
    [ "$(jq -r .endpoint.url "$STATE/components/ollama.json")" = "http://127.0.0.1:11500" ]
}

@test "reinstall keeps the recorded models" {
    ollama install
    jq '.models = [{"name":"llama3.2:3b"}]' "$STATE/components/ollama.json" >"$BATS_TEST_TMPDIR/s.json"
    cp "$BATS_TEST_TMPDIR/s.json" "$STATE/components/ollama.json"
    ollama install --port 11500
    [ "$(jq -r '.models[0].name' "$STATE/components/ollama.json")" = "llama3.2:3b" ]
}

@test "a reinstall that downloads nothing keeps the files and data directories recorded earlier, so uninstall still removes them" {
    ollama install
    jq '.files += ["/usr/local/bin/ollama", "/usr/local/lib/ollama"] | .data_dirs += ["/srv/models"]' "$STATE/components/ollama.json" >"$BATS_TEST_TMPDIR/s.json"
    cp "$BATS_TEST_TMPDIR/s.json" "$STATE/components/ollama.json"
    ollama install --port 11500
    [ "$status" -eq 0 ]
    run jq -c '[.files, .data_dirs]' "$STATE/components/ollama.json"
    [[ "$output" == *'"/usr/local/bin/ollama"'* && "$output" == *'"/usr/local/lib/ollama"'* ]]
    [[ "$output" == *'"/srv/models"'* && "$output" == *'"/usr/share/ollama/.ollama"'* ]]
    [[ "$output" == *'"/etc/systemd/system/ollama.service"'* ]]
}

@test "--default is applied only on request after the first install" {
    bash -c "source '${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh'; state_write vllm '{\"name\":\"vllm\",\"type\":\"engine\"}'"
    ollama install
    [ "$(jq -r .default "$STATE/components/ollama.json")" = "false" ]
    ollama install --default
    [ "$(jq -r .default "$STATE/components/ollama.json")" = "true" ]
    [ "$(jq -r .default "$STATE/components/vllm.json")" = "false" ]
}

@test "--dry-run changes nothing" {
    ollama install --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"dry run"* ]]
    [ ! -e "$STATE/components/ollama.json" ]
    [ ! -e "$SYS/etc/systemd/system/ollama.service" ]
}

@test "install fails at once when the component lock is held" {
    mkdir -p "$STATE/locks"
    (
        exec 8>>"$STATE/locks/engine-ollama.lock"
        flock 8
        sleep 5
    ) &
    holder=$!
    sleep 1
    ollama install
    kill "$holder" 2>/dev/null || true
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"another action is running on ollama"* ]]
}

# --- status ------------------------------------------------------------------------

@test "status of a missing component exits 4" {
    ollama status
    [ "$status" -eq 4 ]
    run jq -r '.installed, .running, .healthy, .version' <<<"$output"
    [ "${lines[0]}" = "false" ]
    [ "${lines[3]}" = "null" ]
}

@test "status of an installed component reports it and exits 6 without health in test mode" {
    ollama install
    ollama status
    [ "$status" -eq 6 ]
    run jq -r '.installed, .version' <<<"$output"
    [ "${lines[0]}" = "true" ]
    [ "${lines[1]}" = "0.35.1" ]
}

# --- uninstall ---------------------------------------------------------------------

@test "uninstall removes the unit, the state and the default" {
    ollama install
    ollama uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$SYS/etc/systemd/system/ollama.service" ]
    [ ! -e "$STATE/components/ollama.json" ]
    [ ! -e "$STATE/pending/ollama.json" ]
}

@test "uninstall keeps the data unless --purge" {
    ollama install
    mkdir -p "$SYS/usr/share/ollama/.ollama"
    ollama uninstall
    [ -d "$SYS/usr/share/ollama/.ollama" ]
    ollama install
    ollama uninstall --purge
    [ ! -d "$SYS/usr/share/ollama/.ollama" ]
}

@test "uninstall of a component that is not installed exits 4" {
    ollama uninstall
    [ "$status" -eq 4 ]
}

@test "uninstall cleans a failed install left as a pending manifest" {
    mkdir -p "$STATE/pending" "$SYS/etc/systemd/system"
    printf '{"name":"ollama","type":"engine","files":["/etc/systemd/system/ollama.service"],"units":[],"data_dirs":[]}\n' \
        >"$STATE/pending/ollama.json"
    : >"$SYS/etc/systemd/system/ollama.service"
    ollama uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$SYS/etc/systemd/system/ollama.service" ]
    [ ! -e "$STATE/pending/ollama.json" ]
}

@test "uninstall is refused while another component requires ollama, unless --force" {
    ollama install
    bash -c "source '${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh'; state_write librechat '{\"name\":\"librechat\",\"type\":\"chat-interface\",\"requires\":[\"ollama\"]}'"
    ollama uninstall
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"librechat requires ollama"* ]]
    [ -f "$STATE/components/ollama.json" ]
    ollama uninstall --force
    [ "$status" -eq 0 ]
    [ ! -f "$STATE/components/ollama.json" ]
}

# --- models ------------------------------------------------------------------------

@test "model actions need an installed engine" {
    ollama add-model llama3.2:3b
    [ "$status" -eq 4 ]
    ollama list-models
    [ "$status" -eq 4 ]
}

@test "add-model validates the model name" {
    ollama add-model 'bad name;rm'
    [ "$status" -eq 2 ]
    ollama remove-model -x
    [ "$status" -eq 2 ]
}

@test "add-model and remove-model --dry-run change nothing" {
    ollama install
    ollama add-model llama3.2:3b --dry-run
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"would pull llama3.2:3b"* ]]
    [ "$(jq -c .models "$STATE/components/ollama.json")" = "[]" ]
    ollama remove-model llama3.2:3b --dry-run
    [ "$status" -eq 0 ]
}

@test "add-model pulls with the native command and records the model; remove-model forgets it" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\necho "ollama $* host=$OLLAMA_HOST" >&2\n' >"$BATS_TEST_TMPDIR/bin/ollama"
    chmod +x "$BATS_TEST_TMPDIR/bin/ollama"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    ollama install --port 11500
    ollama add-model llama3.2:3b
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"ollama pull llama3.2:3b host=127.0.0.1:11500"* ]]
    [ "$(jq -r '.models[0].name' "$STATE/components/ollama.json")" = "llama3.2:3b" ]
    ollama add-model llama3.2:3b
    [ "$(jq '.models | length' "$STATE/components/ollama.json")" -eq 1 ]
    ollama remove-model llama3.2:3b
    [ "$status" -eq 0 ]
    [ "$(jq '.models | length' "$STATE/components/ollama.json")" -eq 0 ]
}
