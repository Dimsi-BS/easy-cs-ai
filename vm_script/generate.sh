#!/usr/bin/env bash
# Generator of the VM post-install script, see docs/spec-vm-generator.md.
# Reached through `easy-cs-ai generate`. Interactive unless given --config.
set -euo pipefail

readonly GENERATOR_VERSION=0.1.0
readonly DEFAULT_RELEASE_BASE=https://github.com/Dimsi-BS/easy-cs-ai/releases/download
readonly SCRIPT_SIZE_LIMIT=32768

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly HERE

find_home() {
    local candidate
    for candidate in "${EASY_CS_AI_HOME:-}" "$HERE/.." "$HERE/../install_scripts"; do
        if [[ -n "$candidate" && -r "$candidate/lib/common.sh" ]]; then
            (cd "$candidate" && pwd)
            return 0
        fi
    done
    printf '[ERROR] cannot find the easy-cs-ai scripts (set EASY_CS_AI_HOME)\n' >&2
    exit 1
}
HOME_DIR="$(find_home)"
readonly HOME_DIR
export EASY_CS_AI_LIB="$HOME_DIR/lib"
# The generator plans for another machine: what is installed here is irrelevant.
export EASY_CS_AI_ASSUME_EMPTY=1
export APPLY_ORDER_FAIL_CODE=2

# shellcheck source=../install_scripts/lib/common.sh
source "$EASY_CS_AI_LIB/common.sh"
# shellcheck source=../install_scripts/lib/cli-base.sh
source "$EASY_CS_AI_LIB/cli-base.sh"
# shellcheck source=../install_scripts/lib/cli-apply.sh
source "$EASY_CS_AI_LIB/cli-apply.sh"
# shellcheck source=../install_scripts/lib/cli-ai.sh
source "$EASY_CS_AI_LIB/cli-ai.sh"
# shellcheck source=lib/questions.sh
source "$HERE/lib/questions.sh"

DRY=0
CONFIG_FILE="" CONFIG_ONLY=0 OUTPUT=""
REPORT_DOC="" SCRIPT_BYTES=0
PACKAGE_URL="" PACKAGE_VERSION="" PACKAGE_FORMAT=deb PACKAGE_SHA256="" PACKAGE_FILE="" PACKAGE_EXT=deb

usage() {
    cat <<'EOF'
Usage: generate [options]

Writes the VM post-install script (default ./easy-cs-ai-vm.sh), after an
interactive session or from a configuration file.

  --config <file>          configuration to turn into a script, no prompt at all
  --config-only            write only the configuration (default ./easy-cs-ai.json)
  --output <path>          where to write the result
  --package-url <url>      where the VM downloads the package (a mirror, for instance)
  --package-version <v>    pinned version (default: the version of the installed CLI)
  --package-format <f>     deb (default), rpm or tarball
  --package-sha256 <hex>   checksum the script verifies
  --package-file <path>    compute the checksum from a local copy of the package
  --dry-run                run everything, print the result on stderr, write nothing
  --json                   with --config: print one JSON document on stdout (validation,
                           warnings, plan, script written) instead of the human output
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
        --config-only) CONFIG_ONLY=1 ;;
        --config | --output | --package-url | --package-version | --package-format | --package-sha256 | --package-file)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$arg needs a value"
            case "$arg" in
            --config) CONFIG_FILE="$1" ;;
            --output) OUTPUT="$1" ;;
            --package-url) PACKAGE_URL="$1" ;;
            --package-version) PACKAGE_VERSION="$1" ;;
            --package-format) PACKAGE_FORMAT="$1" ;;
            --package-sha256) PACKAGE_SHA256="$1" ;;
            --package-file) PACKAGE_FILE="$1" ;;
            esac
            shift
            ;;
        *) die "$EXIT_USAGE" "unknown argument: $arg" ;;
        esac
    done
    if [[ -n "$CONFIG_FILE" ]] && ((CONFIG_ONLY)); then
        die "$EXIT_USAGE" "--config and --config-only cannot be combined"
    fi
    if ((_OPT_JSON)) && [[ -z "$CONFIG_FILE" ]]; then
        die "$EXIT_USAGE" "--json needs --config: a session is interactive"
    fi
    case "$PACKAGE_FORMAT" in deb | rpm | tarball) ;; *) die "$EXIT_USAGE" "unknown package format '$PACKAGE_FORMAT' (deb, rpm or tarball)" ;; esac
}

# --- Package source -------------------------------------------------------------------

resolve_package_source() {
    local file ext
    PACKAGE_VERSION="${PACKAGE_VERSION:-${EASY_CS_AI_CLI_VERSION:-}}"
    [[ -n "$PACKAGE_VERSION" ]] || die "$EXIT_USAGE" "the package version is unknown, give --package-version"
    case "$PACKAGE_FORMAT" in
    deb) file="easy-cs-ai_${PACKAGE_VERSION}_all.deb" ;;
    rpm) file="easy-cs-ai-${PACKAGE_VERSION}-1.noarch.rpm" ;;
    tarball) file="easy-cs-ai-${PACKAGE_VERSION}.tar.gz" ;;
    esac
    PACKAGE_URL="${PACKAGE_URL:-$DEFAULT_RELEASE_BASE/v$PACKAGE_VERSION/$file}"
    if [[ -z "$PACKAGE_SHA256" ]]; then
        if [[ -n "$PACKAGE_FILE" ]]; then
            [[ -r "$PACKAGE_FILE" ]] || die "$EXIT_NETWORK" "cannot read $PACKAGE_FILE"
            PACKAGE_SHA256="$(sha256sum "$PACKAGE_FILE" | cut -d' ' -f1)"
        else
            PACKAGE_SHA256="$(curl -fsSL --max-time 30 "$PACKAGE_URL.sha256" | awk 'NR == 1 {print $1}')" || true
        fi
    fi
    [[ "$PACKAGE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
        die "$EXIT_NETWORK" "no valid sha256 for the package: give --package-sha256 or --package-file, or publish $PACKAGE_URL.sha256"
    PACKAGE_SHA256="${PACKAGE_SHA256,,}"
    ext="$PACKAGE_FORMAT"
    [[ "$ext" != tarball ]] || ext=tar.gz
    PACKAGE_EXT="$ext"
}

# --- Emission --------------------------------------------------------------------------

# sq <text>: shell single-quoted.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# header <config>: comment block recording what the script was built from.
header() {
    local config="$1" desc order type name version
    desc="$(apply_describes "$config")"
    order="$(apply_order "$config" "$desc")"
    printf '# easy-cs-ai VM post-install script, generated by easy-cs-ai generate %s on %s\n' "$GENERATOR_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# package: easy-cs-ai %s (%s)\n' "$PACKAGE_VERSION" "$PACKAGE_FORMAT"
    while read -r type name; do
        [[ -n "$name" ]] || continue
        version="$(jq -r --arg k "$type/$name" '.[$k].component_version // "?"' <<<"$desc")"
        printf '# component: %s %s %s %s\n' "$type" "$name" "$version" \
            "$(jq -r --arg t "$type" --arg n "$name" '(.components[] | select(.type == $t and .name == $n) | .options // {}) | to_entries | map("--\(.key)=\(.value)") | join(" ")' <<<"$config")"
    done <<<"$order"
}

# emit_script <config> <path>
emit_script() {
    local config="$1" out="$2" delimiter=EASY_CS_AI_CONFIG tpl
    shopt -u patsub_replacement 2>/dev/null || true
    while grep -qxF "$delimiter" <<<"$config"; do
        delimiter+="_X"
    done
    tpl="$(cat "$HERE/templates/vm-script.sh.tpl")"
    tpl="${tpl//@@HEADER@@/$(header "$config")}"
    tpl="${tpl//@@URL@@/$(sq "$PACKAGE_URL")}"
    tpl="${tpl//@@VERSION@@/$(sq "$PACKAGE_VERSION")}"
    tpl="${tpl//@@SHA256@@/$(sq "$PACKAGE_SHA256")}"
    tpl="${tpl//@@FORMAT@@/$(sq "$PACKAGE_EXT")}"
    tpl="${tpl//@@DELIMITER@@/$delimiter}"
    tpl="${tpl//@@CONFIG@@/$config}"
    write_output "$out" "$tpl" 0755
    local size
    size="$(printf '%s
' "$tpl" | wc -c)"
    SCRIPT_BYTES="$size"
    ((DRY)) || log_info "script written to $out ($size bytes)"
    if ((size > SCRIPT_SIZE_LIMIT)); then
        log_warn "the script is larger than $SCRIPT_SIZE_LIMIT bytes, check the user-data limit of the target cloud"
    fi
}

# write_output <path> <content> <mode>: atomic write, or stderr with --dry-run.
write_output() {
    local path="$1" content="$2" mode="$3" tmp
    if ((DRY)); then
        log_info "dry run, would write $path:"
        printf '%s\n' "$content" >&2
        return 0
    fi
    tmp="$(mktemp "$(dirname "$path")/.generate.XXXXXX" 2>/dev/null)" || die "$EXIT_ERROR" "cannot write in $(dirname "$path")"
    printf '%s\n' "$content" >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path" || die "$EXIT_ERROR" "cannot write $path"
}

# --- Main ------------------------------------------------------------------------------

# json_result <document> <script-json>: print the validation document with the script written.
json_result() {
    jq -c --argjson s "$2" '. + {script: $s}' <<<"$1"
}

load_config() {
    local config desc doc rc
    [[ -r "$CONFIG_FILE" ]] || die "$EXIT_USAGE" "cannot read $CONFIG_FILE"
    config="$(cat "$CONFIG_FILE")"
    if ((_OPT_JSON)); then
        # the document of `config validate --target fresh`, extended with the script
        if jq -e . >/dev/null 2>&1 <<<"$config"; then
            doc="$(config_report "$config" fresh)"
        else
            doc="$(not_json_document fresh)"
        fi
        rc="$(config_exit_code "$doc")"
        if ((rc != 0)); then
            json_result "$doc" null
            config_report_text "$doc"
            exit "$rc"
        fi
        REPORT_DOC="$doc"
    fi
    jq -e . >/dev/null 2>&1 <<<"$config" || die "$EXIT_USAGE" "$CONFIG_FILE is not valid JSON"
    desc="$(apply_describes "$config")"
    apply_validate "$config" "$desc"
    apply_validate_models_need "$config" "$desc"
    apply_order "$config" "$desc" >/dev/null
    SESSION_CONFIG="$(jq . <<<"$config")"
    print_summary "$SESSION_CONFIG"
}

main() {
    parse_args "$@"
    _require_jq
    local out
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config
    else
        run_session
        apply_validate "$SESSION_CONFIG" "$(apply_describes "$SESSION_CONFIG")"
    fi
    if ((CONFIG_ONLY)); then
        out="${OUTPUT:-./easy-cs-ai.json}"
        write_output "$out" "$SESSION_CONFIG" 0644
        ((DRY)) || log_info "configuration written to $out"
        return 0
    fi
    resolve_package_source
    out="${OUTPUT:-./easy-cs-ai-vm.sh}"
    emit_script "$SESSION_CONFIG" "$out"
    if ((_OPT_JSON)); then
        json_result "$REPORT_DOC" "$(jq -nc --arg p "$out" --argjson b "$SCRIPT_BYTES" --argjson w "$((DRY ? 0 : 1))"             '{path: $p, bytes: $b, written: ($w == 1), package_version: $v, package_format: $f}' --arg v "$PACKAGE_VERSION" --arg f "$PACKAGE_FORMAT")"
    fi
}

main "$@"
