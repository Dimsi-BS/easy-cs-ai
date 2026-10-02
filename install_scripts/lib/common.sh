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

# --- Preconditions ----------------------------------------------------------

# require_root: exit 4 when not running as root. Skipped in test mode.
require_root() {
    if is_test_root; then
        log_debug "test mode: root requirement skipped"
        return 0
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "$EXIT_PRECONDITION" "this action must run as root"
    fi
}

# --- Action journal (spec-script-contract.md, "Action journal") -------------

# log_event <message…>: write one line to the system journal, tag easy-cs-ai.
# In test mode there is no journal: the event goes to stderr as an INFO line
# flagged "(journal, test mode)". Never pass a secret.
log_event() {
    if is_test_root; then
        log_info "(journal, test mode) $*"
        return 0
    fi
    if command -v logger >/dev/null 2>&1; then
        logger -t easy-cs-ai -- "$*" || log_warn "could not write to the journal"
    else
        log_warn "logger not found, event not journaled: $*"
    fi
    return 0
}

# --- Health check (spec-script-contract.md, "Health check") -----------------

# wait_for_http <url> <timeout-seconds> [<systemd-unit> [<interval-seconds>]]
# Polls the URL (curl, any 2xx/3xx) every <interval> seconds (default 2) until
# it answers. Returns 0 on success, EXIT_VERIFY (6) on timeout, or at once if
# the unit is in the failed state (pass "" to skip that check). Logs the last
# probe result on failure. The caller decides whether to die.
wait_for_http() {
    local url="${1:-}" timeout="${2:-}" unit="${3:-}" interval="${4:-2}"
    if [[ -z "$url" || ! "$timeout" =~ ^[0-9]+$ || ! "$interval" =~ ^[0-9]+$ ]]; then
        die "$EXIT_USAGE" "wait_for_http: usage: wait_for_http <url> <timeout-seconds> [unit [interval-seconds]]"
    fi

    local deadline=$((SECONDS + timeout)) last="no probe made"
    while :; do
        if last="$(curl -fsS -o /dev/null --max-time 5 "$url" 2>&1)"; then
            log_debug "health check passed: $url"
            return 0
        fi
        if [[ -n "$unit" ]] && ! is_test_root && systemctl is-failed --quiet "$unit"; then
            log_error "unit $unit failed while waiting for $url"
            return "$EXIT_VERIFY"
        fi
        if ((SECONDS >= deadline)); then
            log_error "health check timed out after ${timeout}s on $url (last probe: ${last:-no answer})"
            return "$EXIT_VERIFY"
        fi
        sleep "$interval"
    done
}
