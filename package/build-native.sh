#!/usr/bin/env bash
# Builds the .deb and the .rpm from the tree staged by package/build.sh, see
# docs/decision-packaging.md.
#
#   package/build-native.sh [--nfpm <binary>] [--output <dir>]
#
# <output> (default ./dist) must already hold stage/ (package/build.sh --output <dir>). Adds to it
#   easy-cs-ai_<v>_all.deb      easy-cs-ai-<v>-1.noarch.rpm      each with its .sha256
# the names the generated VM scripts download (docs/spec-vm-generator.md#package-source). nfpm
# turns a pre-release version into the package manager's own form (0.1.0-rc1 becomes 0.1.0~rc1,
# which sorts before 0.1.0) and puts it in the file name: the files are renamed after the version
# of the CLI, the metadata inside keep the package manager's form.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$PWD/dist"
nfpm="nfpm"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --nfpm) nfpm="${2:?--nfpm needs a value}"; shift 2 ;;
    --output) output="${2:?--output needs a value}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -d "$output/stage" ]] || { printf 'no %s/stage: run package/build.sh --output %s first\n' "$output" "$output" >&2; exit 2; }
output="$(cd "$output" && pwd)"
version="$(sed -n 's/^readonly CLI_VERSION=//p' "$root/package/bin/easy-cs-ai")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for packager in deb rpm; do
    STAGE="$output/stage" VERSION="$version" "$nfpm" package --config "$root/package/nfpm.yaml" --packager "$packager" --target "$tmp/" >&2
done

shopt -s nullglob
for built in "$tmp"/*.deb "$tmp"/*.rpm; do
    case "$built" in
    *.deb) final="easy-cs-ai_${version}_all.deb" ;;
    *.rpm) final="easy-cs-ai-${version}-1.noarch.rpm" ;;
    esac
    mv "$built" "$output/$final"
    (cd "$output" && sha256sum "$final" >"$final.sha256")
    printf '%s\n' "$output/$final"
done
