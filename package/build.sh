#!/usr/bin/env bash
# Builds the distributable tree and the tarball, see docs/decision-packaging.md.
#
#   package/build.sh [--version <v>] [--output <dir>]
#
# Produces, in <output> (default ./dist):
#   stage/                         the tree the packages install under /usr
#     bin/easy-cs-ai
#     lib/easy-cs-ai/{lib,engine,…,templates,ranks.conf,vm_script}
#   easy-cs-ai-<v>.tar.gz          the same tree under easy-cs-ai-<v>/
#   easy-cs-ai-<v>.tar.gz.sha256   "<hash>  <file>", the format the generator reads
# The .deb and .rpm are built from stage/ by nfpm (package/nfpm.yaml), in CI.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$PWD/dist"
version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --version) version="${2:?--version needs a value}"; shift 2 ;;
    --output) output="${2:?--output needs a value}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

cli_version="$(sed -n 's/^readonly CLI_VERSION=//p' "$root/package/bin/easy-cs-ai")"
version="${version:-$cli_version}"
if [[ "$version" != "$cli_version" ]]; then
    printf 'version %s differs from the CLI version %s: bump CLI_VERSION in package/bin/easy-cs-ai\n' "$version" "$cli_version" >&2
    exit 2
fi

stage="$output/stage"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/lib/easy-cs-ai"
install -m 0755 "$root/package/bin/easy-cs-ai" "$stage/bin/easy-cs-ai"

# The scripts tree: everything of install_scripts except the documentation.
cp -a "$root/install_scripts/." "$stage/lib/easy-cs-ai/"
mkdir -p "$stage/lib/easy-cs-ai/vm_script"
cp -a "$root/vm_script/." "$stage/lib/easy-cs-ai/vm_script/"
find "$stage" -name 'README.md' -delete

tarball="easy-cs-ai-$version.tar.gz"
# Reproducible: sorted names, fixed owner and time (the commit date when known).
mtime="$(git -C "$root" log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -a "$stage" "$tmp/easy-cs-ai-$version"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="$mtime" \
    -C "$tmp" -cf - "easy-cs-ai-$version" | gzip -n >"$output/$tarball"
(cd "$output" && sha256sum "$tarball" >"$tarball.sha256")
printf '%s\n' "$output/$tarball"
