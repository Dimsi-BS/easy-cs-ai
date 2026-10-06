#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    export EASY_CS_AI_ROOT="$BATS_TEST_TMPDIR/root"
    unset EASY_CS_AI_HOME
    DIST="$BATS_TEST_TMPDIR/dist"
    VERSION="$(sed -n 's/^readonly CLI_VERSION=//p' "$ROOT/package/bin/easy-cs-ai")"
}

build() { bash "$ROOT/package/build.sh" --output "$DIST" "$@"; }

@test "build produces the stage, the tarball and its checksum" {
    run --separate-stderr build
    [ "$status" -eq 0 ]
    [ -x "$DIST/stage/bin/easy-cs-ai" ]
    [ -f "$DIST/stage/lib/easy-cs-ai/lib/common.sh" ]
    [ -f "$DIST/stage/lib/easy-cs-ai/vm_script/generate.sh" ]
    [ -f "$DIST/stage/lib/easy-cs-ai/engine/ollama.sh" ]
    [ -f "$DIST/stage/lib/easy-cs-ai/templates/ollama/ollama.service" ]
    [ -f "$DIST/stage/lib/easy-cs-ai/ranks.conf" ]
    [ ! -e "$DIST/stage/lib/easy-cs-ai/README.md" ]
    [ "$output" = "$DIST/easy-cs-ai-$VERSION.tar.gz" ]
    (cd "$DIST" && sha256sum -c "easy-cs-ai-$VERSION.tar.gz.sha256")
}

@test "build refuses a version that differs from the CLI's" {
    run --separate-stderr build --version 9.9.9
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"bump CLI_VERSION"* ]]
}

@test "the tarball is reproducible" {
    build >/dev/null
    first="$(sha256sum "$DIST/easy-cs-ai-$VERSION.tar.gz" | cut -d' ' -f1)"
    build >/dev/null
    [ "$(sha256sum "$DIST/easy-cs-ai-$VERSION.tar.gz" | cut -d' ' -f1)" = "$first" ]
}

@test "the unpacked tarball works through a symlink, as the generated VM script installs it" {
    build >/dev/null
    mkdir -p "$BATS_TEST_TMPDIR/opt" "$BATS_TEST_TMPDIR/usr-local-bin"
    tar -xzf "$DIST/easy-cs-ai-$VERSION.tar.gz" -C "$BATS_TEST_TMPDIR/opt" --strip-components=1
    ln -s "$BATS_TEST_TMPDIR/opt/bin/easy-cs-ai" "$BATS_TEST_TMPDIR/usr-local-bin/easy-cs-ai"
    CLI="$BATS_TEST_TMPDIR/usr-local-bin/easy-cs-ai"
    run --separate-stderr bash "$CLI" --version
    [ "$output" = "$VERSION" ]
    run --separate-stderr bash "$CLI" engine
    [ "$status" -eq 0 ]
    [[ "$output" == *"ollama"* ]]
    run --separate-stderr bash "$CLI" status
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$CLI" install engine ollama --dry-run
    [ "$status" -eq 0 ]
}

@test "the unpacked tarball carries a working generator" {
    build >/dev/null
    mkdir -p "$BATS_TEST_TMPDIR/opt"
    tar -xzf "$DIST/easy-cs-ai-$VERSION.tar.gz" -C "$BATS_TEST_TMPDIR/opt" --strip-components=1
    cd "$BATS_TEST_TMPDIR"
    printf '{"schema_version":1,"components":[{"type":"engine","name":"ollama"}]}' >cfg.json
    run --separate-stderr bash "$BATS_TEST_TMPDIR/opt/bin/easy-cs-ai" generate --config cfg.json \
        --package-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef --output vm.sh
    [ "$status" -eq 0 ]
    grep -q "^PACKAGE_VERSION='$VERSION'" vm.sh
    grep -q '^# component: engine ollama' vm.sh
}

@test "nfpm.yaml names the same layout as the stage" {
    grep -q 'src: dist/stage/bin/easy-cs-ai' "$ROOT/package/nfpm.yaml"
    grep -q 'dst: /usr/bin/easy-cs-ai' "$ROOT/package/nfpm.yaml"
    grep -q 'dst: /usr/lib/easy-cs-ai' "$ROOT/package/nfpm.yaml"
}
