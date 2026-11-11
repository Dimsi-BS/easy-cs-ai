#!/usr/bin/env bash
# Generator of the VM post-install scripts from a configuration, see docs/spec-vm-generator.md.
# Reached through `easy-cs-ai script <file>`. Never prompts.
set -euo pipefail

# shellcheck source=lib/generator.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/generator.sh"

usage() {
    cat <<'EOF'
Usage: script <file> [options]

Writes the VM post-install script (default ./easy-cs-ai-vm.sh) from a
configuration file, with no prompt at all. The file must be complete: create or
fix it with `easy-cs-ai config edit <file>`. When the file names several VMs, it writes
one script per VM, the VM inserted before the extension of the name
(easy-cs-ai-vm-engine.sh, easy-cs-ai-vm-web.sh), then prints what is left to do
once the VMs are up.

  --output <path>          where to write the script (for several VMs: the name the VM is inserted in)
  --package-url <url>      where the VM downloads the package (a mirror, for instance)
  --package-version <v>    pinned version (default: the version of the installed CLI)
  --package-format <f>     deb (default), rpm or tarball
  --package-sha256 <hex>   checksum the script verifies
  --package-file <path>    compute the checksum from a local copy of the package
  --dry-run                run everything, print the result on stderr, write nothing
  --json                   print one JSON document on stdout (validation, warnings, plan,
                           script written, or scripts and next steps for several VMs)
                           instead of the human output
  --help --version --verbose

Without --package-sha256 or --package-file, the checksum is read from <url>.sha256.
EOF
}

parse_args() {
    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
        --help) usage; exit 0 ;;
        --version) printf '%s\n' "$GENERATOR_VERSION"; exit 0 ;;
        --verbose) export EASY_CS_AI_VERBOSE=1 ;;
        --dry-run) DRY=1 ;;
        --json) _OPT_JSON=1 ;;
        --output | --package-url | --package-version | --package-format | --package-sha256 | --package-file)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$arg needs a value"
            case "$arg" in
            --output) OUTPUT="$1" ;;
            --package-url) PACKAGE_URL="$1" ;;
            --package-version) PACKAGE_VERSION="$1" ;;
            --package-format) PACKAGE_FORMAT="$1" ;;
            --package-sha256) PACKAGE_SHA256="$1" ;;
            --package-file) PACKAGE_FILE="$1" ;;
            esac
            shift
            ;;
        -*) die "$EXIT_USAGE" "unknown argument: $arg" ;;
        *)
            [[ -z "$CONFIG_FILE" ]] || die "$EXIT_USAGE" "one configuration file at a time"
            CONFIG_FILE="$arg"
            ;;
        esac
    done
    [[ -n "$CONFIG_FILE" ]] ||
        die "$EXIT_USAGE" "script needs a configuration file (easy-cs-ai script <file>; to create one: easy-cs-ai config new)"
    case "$PACKAGE_FORMAT" in deb | rpm | tarball) ;; *) die "$EXIT_USAGE" "unknown package format '$PACKAGE_FORMAT' (deb, rpm or tarball)" ;; esac
}

main() {
    parse_args "$@"
    _require_jq
    local out
    load_config
    resolve_package_source
    if apply_named "$SESSION_CONFIG"; then
        emit_vm_scripts "$SESSION_CONFIG"
        ((DRY)) || list_stale_scripts "$SESSION_CONFIG"
        if ((_OPT_JSON)); then
            json_result "$REPORT_DOC" null "$SCRIPTS_JSON"
        else
            print_vm_scripts_report "$SESSION_CONFIG"
        fi
        return 0
    fi
    out="${OUTPUT:-./easy-cs-ai-vm.sh}"
    emit_script "$SESSION_CONFIG" "$out"
    if ((_OPT_JSON)); then
        json_result "$REPORT_DOC" "$(jq -nc --arg p "$out" --argjson b "$SCRIPT_BYTES" --argjson w "$((DRY ? 0 : 1))" --arg v "$PACKAGE_VERSION" --arg f "$PACKAGE_FORMAT" \
            '{path: $p, bytes: $b, written: ($w == 1), package_version: $v, package_format: $f}')"
    fi
}

main "$@"
