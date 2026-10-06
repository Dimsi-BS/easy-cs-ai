#!/usr/bin/env bash
@@HEADER@@
set -euo pipefail

PACKAGE_URL=@@URL@@
PACKAGE_VERSION=@@VERSION@@
PACKAGE_SHA256=@@SHA256@@
PACKAGE_FORMAT=@@FORMAT@@

log() { printf '[%s] %s\n' "$1" "$2" >&2; }
die() {
    local code="$1"
    shift
    log ERROR "$*"
    exit "$code"
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die 4 "this script must run as root"
command -v curl >/dev/null 2>&1 || die 4 "curl is required"

installed_version() {
    if command -v easy-cs-ai >/dev/null 2>&1; then
        easy-cs-ai --version 2>/dev/null || true
    fi
}

install_package() {
    local tmp file actual
    tmp="$(mktemp -d)"
    file="$tmp/package.$PACKAGE_FORMAT"
    log INFO "downloading $PACKAGE_URL"
    curl -fsSL --retry 3 --retry-delay 5 -o "$file" "$PACKAGE_URL" || die 5 "download failed: $PACKAGE_URL"
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    [[ "$actual" == "$PACKAGE_SHA256" ]] || die 5 "checksum mismatch, nothing installed"
    case "$PACKAGE_FORMAT" in
    deb) DEBIAN_FRONTEND=noninteractive apt-get install -y "$file" >&2 ;;
    rpm)
        if command -v dnf >/dev/null 2>&1; then dnf install -y "$file" >&2; else rpm -U --replacepkgs "$file" >&2; fi
        ;;
    tar.gz)
        if ! command -v jq >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then apt-get install -y jq >&2; else dnf install -y jq >&2; fi
        fi
        mkdir -p /opt/easy-cs-ai
        tar -xzf "$file" -C /opt/easy-cs-ai --strip-components=1
        ln -sf /opt/easy-cs-ai/bin/easy-cs-ai /usr/local/bin/easy-cs-ai
        ;;
    esac
    rm -rf "$tmp"
}

if [[ "$(installed_version)" == "$PACKAGE_VERSION" ]]; then
    log INFO "easy-cs-ai $PACKAGE_VERSION is already installed"
else
    install_package
fi

config="$(mktemp)"
trap 'rm -f "$config"' EXIT
chmod 600 "$config"
cat >"$config" <<'@@DELIMITER@@'
@@CONFIG@@
@@DELIMITER@@

rc=0
easy-cs-ai apply "$config" || rc=$?
exit "$rc"
