#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    PENDING="$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/pending/ollama.json"
    unset EASY_CS_AI_STATE_DIR EASY_CS_AI_LOCK_HELD
}

sh() { run bash -c "source '$LIB'; $1"; }

# --- platform and components --------------------------------------------------

@test "require_platform is skipped in test mode" {
    sh "require_platform"
    [ "$status" -eq 0 ]
}

@test "require_component exits 4 when the component is not installed" {
    sh "require_component ollama"
    [ "$status" -eq 4 ]
    [[ "$output" == *"ollama is not installed"* ]]
}

@test "require_component succeeds when the component has a state" {
    sh "state_write ollama '{\"name\":\"ollama\",\"type\":\"engine\"}'; require_component ollama"
    [ "$status" -eq 0 ]
}

# --- pending manifest ---------------------------------------------------------

@test "pending_begin creates the manifest and track_* record without duplicates" {
    sh "pending_begin engine ollama; track_file /usr/local/bin/ollama; track_file /usr/local/bin/ollama; track_unit ollama.service; track_data_dir /usr/share/ollama"
    [ "$status" -eq 0 ]
    run jq -c '[.name, .type, .files, .units, .data_dirs]' "$PENDING"
    [ "$output" = '["ollama","engine",["/usr/local/bin/ollama"],["ollama.service"],["/usr/share/ollama"]]' ]
}

@test "pending_begin reuses an existing manifest" {
    sh "pending_begin engine ollama; track_file /a"
    sh "pending_begin engine ollama; track_file /b"
    run jq -c '.files' "$PENDING"
    [ "$output" = '["/a","/b"]' ]
}

@test "track_file without pending_begin is an error" {
    sh "track_file /a"
    [ "$status" -eq 1 ]
}

@test "pending_read and pending_remove" {
    sh "pending_read ollama"
    [ "$status" -eq 1 ]
    sh "pending_begin engine ollama; pending_read ollama | jq -r .name; pending_remove ollama; pending_read ollama"
    [ "${lines[0]}" = "ollama" ]
    [ ! -e "$PENDING" ]
}

# --- render_template ----------------------------------------------------------

@test "render_template renders, then reports unchanged with 10" {
    printf 'port=${PORT}\n' >"$BATS_TEST_TMPDIR/t.tpl"
    sh "export PORT=1234; render_template '$BATS_TEST_TMPDIR/t.tpl' /etc/easy-cs-ai/x.conf 0640 root"
    [ "$status" -eq 0 ]
    [ "$(cat "$EASY_CS_AI_ROOT/etc/easy-cs-ai/x.conf")" = "port=1234" ]
    [ "$(stat -c %a "$EASY_CS_AI_ROOT/etc/easy-cs-ai/x.conf")" = "640" ]
    sh "export PORT=1234; render_template '$BATS_TEST_TMPDIR/t.tpl' /etc/easy-cs-ai/x.conf 0640 root"
    [ "$status" -eq 10 ]
    sh "export PORT=99; render_template '$BATS_TEST_TMPDIR/t.tpl' /etc/easy-cs-ai/x.conf 0640 root"
    [ "$status" -eq 0 ]
    [ "$(cat "$EASY_CS_AI_ROOT/etc/easy-cs-ai/x.conf")" = "port=99" ]
}

@test "render_template tracks the file during an install and leaves no temporary file" {
    printf 'a\n' >"$BATS_TEST_TMPDIR/t.tpl"
    sh "pending_begin engine ollama; render_template '$BATS_TEST_TMPDIR/t.tpl' /etc/easy-cs-ai/x.conf 0644 root"
    run jq -c '.files' "$PENDING"
    [ "$output" = '["/etc/easy-cs-ai/x.conf"]' ]
    [ "$(ls -A "$EASY_CS_AI_ROOT/etc/easy-cs-ai" | wc -l)" -eq 1 ]
}

@test "render_template fails on a missing template" {
    sh "render_template /nonexistent /etc/x 0644 root"
    [ "$status" -eq 1 ]
}

# --- packages and services (test mode only logs) ------------------------------

@test "apt_install and systemd functions only log in test mode and track units" {
    sh "pending_begin engine ollama; apt_install curl; systemd_enable_now ollama.service; systemd_restart ollama.service; systemd_disable_now ollama.service"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would install packages: curl"* ]]
    [[ "$output" == *"systemctl enable --now ollama.service"* ]]
    run jq -c '.units' "$PENDING"
    [ "$output" = '["ollama.service"]' ]
}
