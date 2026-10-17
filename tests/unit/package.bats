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
    [ -f "$DIST/stage/lib/easy-cs-ai/guide.txt" ]
    [ ! -e "$DIST/stage/lib/easy-cs-ai/README.md" ]
    [ "$output" = "$DIST/easy-cs-ai-$VERSION.tar.gz" ]
    (cd "$DIST" && sha256sum -c "easy-cs-ai-$VERSION.tar.gz.sha256")
}

@test "the stage has the short name ecsai, a link that runs the same CLI" {
    build >/dev/null
    [ -L "$DIST/stage/bin/ecsai" ]
    [ "$(readlink "$DIST/stage/bin/ecsai")" = easy-cs-ai ]
    run --separate-stderr bash "$DIST/stage/bin/ecsai" --version
    [ "$status" -eq 0 ]
    [ "$output" = "$VERSION" ]
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
    run --separate-stderr bash "$CLI" component engine
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
    grep -q 'dst: /usr/bin/ecsai' "$ROOT/package/nfpm.yaml"
    grep -q 'dst: /usr/lib/easy-cs-ai' "$ROOT/package/nfpm.yaml"
}

@test "the component scripts and the generator are executable in the stage, whatever the checkout" {
    tree="$BATS_TEST_TMPDIR/tree"
    mkdir "$tree"
    cp -a "$ROOT/package" "$ROOT/install_scripts" "$ROOT/vm_script" "$tree/"
    find "$tree" -name '*.sh' -exec chmod 0644 {} +
    bash "$tree/package/build.sh" --output "$DIST" >/dev/null
    [ -x "$DIST/stage/lib/easy-cs-ai/engine/ollama.sh" ]
    [ -x "$DIST/stage/lib/easy-cs-ai/proxy/nginx.sh" ]
    [ -x "$DIST/stage/lib/easy-cs-ai/chat-interface/librechat.sh" ]
    [ -x "$DIST/stage/lib/easy-cs-ai/provisioning/llmfit.sh" ]
    [ -x "$DIST/stage/lib/easy-cs-ai/vm_script/generate.sh" ]
}

# A stand-in for nfpm: records where and how it was run, then writes the package it was asked for
fake_nfpm() {
    FAKE_NFPM="$BATS_TEST_TMPDIR/bin/nfpm"
    NFPM_LOG="$BATS_TEST_TMPDIR/nfpm.log"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$FAKE_NFPM" <<'FAKE'
#!/usr/bin/env bash
packager="" target="" config=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    package) shift ;;
    --config) config="$2"; shift 2 ;;
    --packager) packager="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    *) exit 64 ;;
    esac
done
printf '%s|%s|%s|%s|%s\n' "$packager" "$VERSION" "$config" "$(test -x dist/stage/bin/easy-cs-ai && echo stage-seen)" "$(basename "$PWD" | sed 's/.*/cwd/')" >>"$NFPM_LOG"
printf 'fake %s\n' "$packager" >"${target}easy-cs-ai-fake.$packager"
FAKE
    chmod +x "$FAKE_NFPM"
    export NFPM_LOG
}

build_native() { bash "$ROOT/package/build-native.sh" --output "$DIST" "$@"; }

@test "build-native refuses an output without a stage" {
    mkdir -p "$DIST"
    run --separate-stderr build_native --nfpm /bin/true
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"package/build.sh --output"* ]]
}

@test "build-native refuses an unknown argument" {
    run --separate-stderr build_native --bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown argument: --bogus"* ]]
}

@test "build-native builds the deb and the rpm, named after the CLI version, with their checksums" {
    fake_nfpm
    build >/dev/null
    run --separate-stderr build_native --nfpm "$FAKE_NFPM"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$DIST/easy-cs-ai_${VERSION}_all.deb" ]
    [ "${lines[1]}" = "$DIST/easy-cs-ai-${VERSION}-1.noarch.rpm" ]
    [ "${#lines[@]}" -eq 2 ]
    (cd "$DIST" && sha256sum -c "easy-cs-ai_${VERSION}_all.deb.sha256" "easy-cs-ai-${VERSION}-1.noarch.rpm.sha256")
    grep -q '^fake deb$' "$DIST/easy-cs-ai_${VERSION}_all.deb"
    grep -q '^fake rpm$' "$DIST/easy-cs-ai-${VERSION}-1.noarch.rpm"
}

@test "build-native runs nfpm once per packager, with VERSION, nfpm.yaml and dist/stage visible" {
    fake_nfpm
    build >/dev/null
    run --separate-stderr build_native --nfpm "$FAKE_NFPM"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$NFPM_LOG")" -eq 2 ]
    grep -q "^deb|$VERSION|.*/package/nfpm.yaml|stage-seen|" "$NFPM_LOG"
    grep -q "^rpm|$VERSION|.*/package/nfpm.yaml|stage-seen|" "$NFPM_LOG"
}

@test "build-native leaves nothing but the packages and the stage in the output" {
    fake_nfpm
    build >/dev/null
    build_native --nfpm "$FAKE_NFPM" >/dev/null
    run ls "$DIST"
    [ "$output" = "easy-cs-ai-$VERSION-1.noarch.rpm
easy-cs-ai-$VERSION-1.noarch.rpm.sha256
easy-cs-ai-$VERSION.tar.gz
easy-cs-ai-$VERSION.tar.gz.sha256
easy-cs-ai_${VERSION}_all.deb
easy-cs-ai_${VERSION}_all.deb.sha256
stage" ]
}

@test "build-native accepts a relative path to nfpm" {
    fake_nfpm
    build >/dev/null
    cd "$BATS_TEST_TMPDIR"
    run --separate-stderr build_native --nfpm bin/nfpm
    [ "$status" -eq 0 ]
    [ -f "$DIST/easy-cs-ai_${VERSION}_all.deb" ]
}

@test "build-native refuses an nfpm path that is not an executable" {
    build >/dev/null
    run --separate-stderr build_native --nfpm "$BATS_TEST_TMPDIR/bin/missing"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"nfpm not found or not executable"* ]]
    [ ! -e "$DIST/easy-cs-ai_${VERSION}_all.deb" ]
}

@test "build-native looks a bare nfpm name up in PATH" {
    fake_nfpm
    build >/dev/null
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr bash "$ROOT/package/build-native.sh" --output "$DIST"
    [ "$status" -eq 0 ]
    [ -f "$DIST/easy-cs-ai-${VERSION}-1.noarch.rpm" ]
}
