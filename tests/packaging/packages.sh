#!/usr/bin/env bash
# Builds the tarball, the .deb and the .rpm the way release.yml does and checks them, see
# tests/packaging/README.md.
#
#   packages.sh [--keep]
#
# Needs bash, curl, jq, tar, sha256sum. nfpm is taken from $ECSAI_NFPM, the PATH or the cache,
# else downloaded (pinned version, checked against the checksums of the same release). Docker is
# used to install the .deb on Ubuntu and the .rpm on Fedora; without it those steps are skipped.
# Exit 0 when every check passes. Leaves nothing behind, except the nfpm cache, unless --keep.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="${ECSAI_PKG_CACHE:-$HOME/.cache/easy-cs-ai-pkg}"
NFPM_VERSION="${ECSAI_NFPM_VERSION:-2.47.0}"
DEB_IMAGE="${ECSAI_DEB_IMAGE:-ubuntu:24.04}"
RPM_IMAGE="${ECSAI_RPM_IMAGE:-fedora:latest}"
KEEP=0
[[ "${1:-}" != --keep ]] || KEEP=1

PASS=0 FAIL=0 SKIP=0 FAILED=()
VERSION="$(sed -n 's/^readonly CLI_VERSION=//p' "$ROOT/package/bin/easy-cs-ai")"
TARBALL="easy-cs-ai-$VERSION.tar.gz"
DEB="easy-cs-ai_${VERSION}_all.deb"
RPM="easy-cs-ai-$VERSION-1.noarch.rpm"

WORK="$(mktemp -d)"
cleanup() {
    if [[ $KEEP -eq 1 ]]; then
        printf '\nkept: %s\n' "$WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

step() { printf '\n== %s ==\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# check <description> <command…>: the command succeeds
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$desc")
        printf '  FAIL  %s\n' "$desc"
    fi
}

expect() { # <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$1 (expected '$2', got '$3')")
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
    fi
}

for tool in curl jq tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
[[ -n "$VERSION" ]] || die "cannot read CLI_VERSION from package/bin/easy-cs-ai"

# --- nfpm ----------------------------------------------------------------------------------

find_nfpm() {
    if [[ -n "${ECSAI_NFPM:-}" ]]; then
        printf '%s\n' "$ECSAI_NFPM"
    elif command -v nfpm >/dev/null 2>&1; then
        command -v nfpm
    elif [[ -x "$CACHE/nfpm-$NFPM_VERSION/nfpm" ]]; then
        printf '%s\n' "$CACHE/nfpm-$NFPM_VERSION/nfpm"
    else
        local base="https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION"
        local archive="nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz" dir="$CACHE/nfpm-$NFPM_VERSION"
        mkdir -p "$dir" || return 1
        printf 'downloading nfpm %s\n' "$NFPM_VERSION" >&2
        curl -fsSL -o "$dir/$archive" "$base/$archive" || return 1
        curl -fsSL -o "$dir/checksums.txt" "$base/checksums.txt" || return 1
        (cd "$dir" && grep " $archive\$" checksums.txt | sha256sum -c - >&2) || { rm -rf "$dir"; return 1; }
        tar xzf "$dir/$archive" -C "$dir" nfpm || return 1
        printf '%s\n' "$dir/nfpm"
    fi
}

# --- the tarball -----------------------------------------------------------------------------

step "tarball"
DIST="$WORK/dist"
"$ROOT/package/build.sh" --output "$DIST" >/dev/null || die "package/build.sh failed"
check "the tarball and its checksum exist" test -f "$DIST/$TARBALL" -a -f "$DIST/$TARBALL.sha256"
check "the checksum matches" bash -c "cd '$DIST' && sha256sum -c '$TARBALL.sha256'"

mkdir "$WORK/x" && tar xzf "$DIST/$TARBALL" -C "$WORK/x"
TREE="$WORK/x/easy-cs-ai-$VERSION"
check "the tarball holds the CLI and the scripts tree" test -x "$TREE/bin/easy-cs-ai" -a -f "$TREE/lib/easy-cs-ai/vm_script/generate.sh" -a -f "$TREE/lib/easy-cs-ai/ranks.conf"
check "no documentation is shipped" bash -c "! find '$TREE' -name '*.md' | grep -q ."
check "no CRLF in the shipped files" bash -c "! grep -rlI \$'\\r' '$TREE' | grep -q ."
expect "the extracted CLI reports the version" "$VERSION" "$("$TREE/bin/easy-cs-ai" --version 2>/dev/null)"

# --- the deb and the rpm ---------------------------------------------------------------------

step "deb and rpm (nfpm $NFPM_VERSION)"
NFPM="$(find_nfpm)" || die "cannot get nfpm (set ECSAI_NFPM to a binary, or check the network)"
"$ROOT/package/build-native.sh" --nfpm "$NFPM" --output "$DIST" >"$WORK/nfpm.log" 2>&1 || { cat "$WORK/nfpm.log" >&2; die "package/build-native.sh failed"; }
check "the deb has the name the generated scripts download" test -f "$DIST/$DEB"
check "the rpm has the name the generated scripts download" test -f "$DIST/$RPM"
check "the checksum of the deb and of the rpm match" bash -c "cd '$DIST' && sha256sum -c '$DEB.sha256' '$RPM.sha256'"

# Same files in the three formats: the tree of the tarball, under /usr.
want="$(cd "$TREE" && find bin lib -type f | sed 's|^|/usr/|' | LC_ALL=C sort)"

if command -v dpkg-deb >/dev/null 2>&1; then
    expect "deb: package name" easy-cs-ai "$(dpkg-deb -f "$DIST/$DEB" Package)"
    expect "deb: version" "${VERSION/-/"~"}" "$(dpkg-deb -f "$DIST/$DEB" Version)"
    expect "deb: architecture" all "$(dpkg-deb -f "$DIST/$DEB" Architecture)"
    deps="$(dpkg-deb -f "$DIST/$DEB" Depends)"
    for d in bash curl coreutils jq util-linux gettext-base; do
        check "deb depends on $d" grep -qw "$d" <<<"$deps"
    done
    got="$(dpkg-deb -c "$DIST/$DEB" | awk '$1 ~ /^-/ {print $6}' | sed 's|^\./|/|' | LC_ALL=C sort)"
    expect "deb: same files as the tarball" "$want" "$got"
    check "deb: the CLI is executable" bash -c "dpkg-deb -c '$DIST/$DEB' | grep -E '^-rwxr-xr-x .* \./usr/bin/easy-cs-ai\$'"
    check "deb: no maintainer script" bash -c "! dpkg-deb -I '$DIST/$DEB' | grep -Eq '(postinst|preinst|prerm|postrm)'"
else
    skip "deb inspection (no dpkg-deb)"
fi


# --- a pre-release -----------------------------------------------------------------------------

# A tag v<v>-rc1 gives a pre-release: nfpm writes the version in the package manager's form
# (0.1.0~rc1) in the file name, and the generated scripts look for the name with the version of
# the tag, so build-native.sh renames the files. The metadata keep the tilde (sorts before <v>).
PREV="${VERSION%%-*}-rc1"
step "pre-release version ($PREV)"
PRE="$WORK/pre"
mkdir -p "$PRE"
cp -a "$ROOT/package" "$ROOT/install_scripts" "$ROOT/vm_script" "$PRE/"
sed -i "s/^readonly CLI_VERSION=.*/readonly CLI_VERSION=$PREV/" "$PRE/package/bin/easy-cs-ai"
if "$PRE/package/build.sh" --output "$PRE/dist" >/dev/null 2>&1 && "$PRE/package/build-native.sh" --nfpm "$NFPM" --output "$PRE/dist" >/dev/null 2>"$WORK/pre.log"; then
    check "the files are named after the version of the tag" test -f "$PRE/dist/easy-cs-ai-$PREV.tar.gz" -a -f "$PRE/dist/easy-cs-ai_${PREV}_all.deb" -a -f "$PRE/dist/easy-cs-ai-$PREV-1.noarch.rpm"
    if command -v dpkg-deb >/dev/null 2>&1; then
        expect "the deb metadata carry the tilde form" "${PREV/-/"~"}" "$(dpkg-deb -f "$PRE/dist/easy-cs-ai_${PREV}_all.deb" Version)"
    fi
    echo '{"schema_version":1,"components":[{"type":"engine","name":"ollama"}]}' >"$PRE/config.json"
    for f in deb:easy-cs-ai_${PREV}_all.deb rpm:easy-cs-ai-$PREV-1.noarch.rpm; do
        EASY_CS_AI_CLI_VERSION="$PREV" bash "$PRE/vm_script/generate.sh" --config "$PRE/config.json" --package-format "${f%%:*}" \
            --package-version "$PREV" --package-file "$PRE/dist/${f#*:}" --output "$PRE/vm-${f%%:*}.sh" >/dev/null 2>&1
        check "the script generated for the ${f%%:*} downloads ${f#*:} from the release of the tag" \
            grep -q "releases/download/v$PREV/${f#*:}" "$PRE/vm-${f%%:*}.sh"
    done
else
    cat "$WORK/pre.log" >&2
    check "a pre-release builds" false
fi

# --- installs in containers ------------------------------------------------------------------

# The same checks after an install: the CLI runs, the generator turns a configuration into a
# script that pins this very package, the removal leaves nothing.
in_container() { # <description> <image> <package> <format> <install command> <remove command>
    local desc="$1" image="$2" pkg="$3" format="$4" install="$5" remove="$6"
    local log="$WORK/container-$format.log"
    cat >"$WORK/container-$format.sh" <<EOF
set -eux
$install
easy-cs-ai --version
easy-cs-ai status
echo '{"schema_version":1,"components":[{"type":"engine","name":"ollama","default":true}]}' >/tmp/config.json
easy-cs-ai generate --config /tmp/config.json --package-file "/pkgs/$pkg" --package-format $format --output /tmp/vm.sh
bash -n /tmp/vm.sh
grep -q "\$(sha256sum "/pkgs/$pkg" | cut -d' ' -f1)" /tmp/vm.sh
test -f /usr/lib/easy-cs-ai/engine/ollama.sh
$remove
test ! -e /usr/bin/easy-cs-ai
test ! -e /usr/lib/easy-cs-ai
EOF
    if docker run --rm -v "$DIST:/pkgs:ro" -v "$WORK/container-$format.sh:/check.sh:ro" "$image" bash /check.sh >"$log" 2>&1; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$desc")
        printf '  FAIL  %s, last lines of its log:\n' "$desc"
        tail -n 15 "$log" | sed 's/^/        /'
    fi
}

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    step "install on $DEB_IMAGE"
    in_container "the deb installs with its dependencies, works and is removed cleanly" "$DEB_IMAGE" "$DEB" deb \
        "apt-get update -qq && apt-get install -y -qq /pkgs/$DEB >/dev/null" \
        "apt-get remove -y -qq easy-cs-ai >/dev/null"

    step "install on $RPM_IMAGE"
    in_container "the rpm installs with its dependencies, works and is removed cleanly" "$RPM_IMAGE" "$RPM" rpm \
        "dnf install -y -q /pkgs/$RPM >/dev/null" \
        "dnf remove -y -q easy-cs-ai >/dev/null"
else
    step "install in containers"
    skip "deb on Ubuntu and rpm on Fedora (no working docker)"
fi

# --- result ----------------------------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [[ $FAIL -gt 0 ]]; then
    printf 'failed:\n'
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
