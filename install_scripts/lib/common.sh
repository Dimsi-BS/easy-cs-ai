#!/usr/bin/env bash
# Shared helpers sourced by every install script, see docs/spec-script-contract.md.
# This file is meant to be sourced, not executed.

# The EXIT_* constants are used by the scripts that source this file.
# shellcheck disable=SC2034

# Guard against double sourcing.
if [[ -n "${EASY_CS_AI_COMMON_LOADED:-}" ]]; then
    return 0
fi
EASY_CS_AI_COMMON_LOADED=1

# --- Exit codes (spec-script-contract.md, "Exit codes") ---------------------
readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_USAGE=2
readonly EXIT_UNSUPPORTED=3
readonly EXIT_PRECONDITION=4
readonly EXIT_NETWORK=5
readonly EXIT_VERIFY=6

# --- Logging ----------------------------------------------------------------
# Logs go to stderr, one line each, "[LEVEL] message". stdout is reserved for
# machine-readable output. DEBUG lines appear only when EASY_CS_AI_VERBOSE=1.

_log() {
    local level="$1"
    shift
    printf '[%s] %s\n' "$level" "$*" >&2
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

log_debug() {
    if [[ "${EASY_CS_AI_VERBOSE:-0}" == "1" ]]; then
        _log DEBUG "$@"
    fi
    return 0
}

# die <exit-code> <message>: log an error and exit with the given code.
die() {
    local code="${1:-$EXIT_ERROR}"
    shift || true
    log_error "$@"
    exit "$code"
}

# --- Paths and test mode (spec-script-contract.md, "Paths and testability") --
# EASY_CS_AI_ROOT is a prefix applied to every absolute path a script writes.
# When set to something other than "/", the scripts run in test mode: no
# package installation, no service control, no journal, no root requirement.

# is_test_root: succeeds when EASY_CS_AI_ROOT points somewhere other than "/".
is_test_root() {
    local root="${EASY_CS_AI_ROOT:-/}"
    [[ "$root" != "/" && -n "$root" ]]
}

# root_path <absolute-path>: print the path under EASY_CS_AI_ROOT.
root_path() {
    local path="${1:-}"
    if [[ "$path" != /* ]]; then
        die "$EXIT_ERROR" "root_path: absolute path expected, got '$path'"
    fi
    if is_test_root; then
        printf '%s%s\n' "${EASY_CS_AI_ROOT%/}" "$path"
    else
        printf '%s\n' "$path"
    fi
}

# state_dir / config_dir: the logical directories, under EASY_CS_AI_ROOT.
state_dir() { root_path "${EASY_CS_AI_STATE_DIR:-/var/lib/easy-cs-ai}"; }
config_dir() { root_path "${EASY_CS_AI_CONFIG_DIR:-/etc/easy-cs-ai}"; }
