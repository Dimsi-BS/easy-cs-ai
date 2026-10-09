#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../install_scripts/lib/common.sh"
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    LIST="$EASY_CS_AI_ROOT/etc/apt/sources.list.d/docker.list"
    unset EASY_CS_AI_STATE_DIR EASY_CS_AI_LOCK_HELD
    # a docker that does not exist, so a Docker installed on the test machine never counts
    export EASY_CS_AI_DOCKER="$BATS_TEST_TMPDIR/no-such-docker"
    mkdir -p "$EASY_CS_AI_ROOT/etc"
}

sh() { run bash -c "source '$LIB'; $1"; }

os_release() { printf '%s\n' "$@" >"$EASY_CS_AI_ROOT/etc/os-release"; }

fake_docker() {
    printf '#!/bin/sh\n[ "$1" = compose ] && echo "Docker Compose version v2.29.0"\nexit 0\n' >"$BATS_TEST_TMPDIR/docker"
    chmod +x "$BATS_TEST_TMPDIR/docker"
    export EASY_CS_AI_DOCKER="$BATS_TEST_TMPDIR/docker"
}

@test "docker_ready is false without Docker and true with Docker and Compose" {
    sh "docker_ready"
    [ "$status" -eq 1 ]
    fake_docker
    sh "docker_ready"
    [ "$status" -eq 0 ]
}

@test "docker_ready is false when Compose v2 is missing" {
    printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/docker"
    chmod +x "$BATS_TEST_TMPDIR/docker"
    export EASY_CS_AI_DOCKER="$BATS_TEST_TMPDIR/docker"
    sh "docker_ready"
    [ "$status" -eq 1 ]
}

@test "ensure_docker keeps an existing Docker: nothing installed, no source written" {
    fake_docker
    os_release 'ID=ubuntu' 'VERSION_CODENAME=noble'
    sh "ensure_docker"
    [ "$status" -eq 0 ]
    [[ "$output" != *"installing Docker"* ]]
    [[ "$output" != *"would install packages"* ]]
    [ ! -e "$LIST" ]
}

@test "ensure_docker on Ubuntu writes Docker's Ubuntu repository and installs the four packages" {
    os_release 'ID=ubuntu' 'VERSION_CODENAME=noble' 'UBUNTU_CODENAME=noble'
    sh "ensure_docker"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installing Docker from its apt repository (ubuntu noble"* ]]
    [[ "$output" == *"would install packages: ca-certificates curl gnupg"* ]]
    [[ "$output" == *"would install packages: docker-ce docker-ce-cli containerd.io docker-compose-plugin"* ]]
    [[ "$output" == *"systemctl enable --now docker.service"* ]]
    run cat "$LIST"
    [[ "$output" =~ ^deb\ \[arch=(amd64|arm64)\ signed-by=/etc/apt/keyrings/docker.asc\]\ https://download.docker.com/linux/ubuntu\ noble\ stable$ ]]
}

@test "ensure_docker on Debian uses the Debian repository and its codename" {
    os_release 'ID=debian' 'VERSION_CODENAME=bookworm'
    sh "ensure_docker"
    [ "$status" -eq 0 ]
    run cat "$LIST"
    [[ "$output" == *"https://download.docker.com/linux/debian bookworm stable" ]]
}

@test "ensure_docker follows the parent of a derivative: Ubuntu codename, not the derivative's" {
    os_release 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' 'VERSION_CODENAME=wilma' 'UBUNTU_CODENAME=noble'
    sh "ensure_docker"
    [ "$status" -eq 0 ]
    run cat "$LIST"
    [[ "$output" == *"https://download.docker.com/linux/ubuntu noble stable" ]]
}

@test "ensure_docker refuses another distribution with exit 3" {
    os_release 'ID=fedora' 'VERSION_CODENAME='
    sh "ensure_docker"
    [ "$status" -eq 3 ]
    [[ "$output" == *"unsupported distribution 'fedora'"* ]]
    [ ! -e "$LIST" ]
}

@test "ensure_docker refuses a release without a codename (testing, unstable) with exit 3" {
    os_release 'ID=debian'
    sh "ensure_docker"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no release codename"* ]]
}

@test "ensure_docker refuses an unsupported architecture with exit 3" {
    os_release 'ID=ubuntu' 'VERSION_CODENAME=noble'
    sh "uname() { echo riscv64; }; ensure_docker"
    [ "$status" -eq 3 ]
    [[ "$output" == *"unsupported architecture 'riscv64'"* ]]
}

@test "ensure_docker run twice leaves the source untouched" {
    os_release 'ID=ubuntu' 'VERSION_CODENAME=noble'
    sh "ensure_docker"
    first="$(stat -c %Y "$LIST")"
    sleep 1
    sh "ensure_docker"
    [ "$status" -eq 0 ]
    [ "$(stat -c %Y "$LIST")" = "$first" ]
}

@test "ensure_docker records nothing in the pending manifest: Docker is shared and stays" {
    os_release 'ID=ubuntu' 'VERSION_CODENAME=noble'
    sh "pending_begin chat-interface librechat; ensure_docker; pending_read librechat"
    [ "$status" -eq 0 ]
    run jq -c '[.files, .units, .data_dirs]' "$EASY_CS_AI_ROOT/var/lib/easy-cs-ai/pending/librechat.json"
    [ "$output" = '[[],[],[]]' ]
}
