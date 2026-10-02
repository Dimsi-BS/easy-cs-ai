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

# --- Options (spec-script-contract.md, "Parameters") ------------------------
# Precedence: command line > environment > built-in default. Every option has
# an environment variable EASY_CS_AI_<COMPONENT>_<OPTION> (upper snake case).
# A script parses its command line first (set_option for each value it reads),
# then fills what is still missing with set_option_default.

# option_var <component> <option>: print the variable name for an option.
option_var() {
    local name="EASY_CS_AI_${1}_${2}"
    name="${name^^}"
    printf '%s\n' "${name//-/_}"
}

# set_option <component> <option> <value>: value given on the command line.
# It overrides the environment.
set_option() {
    local var
    var="$(option_var "$1" "$2")"
    printf -v "$var" '%s' "$3"
    export "${var?}"
}

# set_option_default <component> <option> <default>: use the default only when
# neither the command line nor the environment gave a value.
set_option_default() {
    local var
    var="$(option_var "$1" "$2")"
    if [[ -z "${!var:-}" ]]; then
        set_option "$1" "$2" "$3"
    fi
}

# get_option <component> <option>: print the current value.
get_option() {
    local var
    var="$(option_var "$1" "$2")"
    printf '%s\n' "${!var:-}"
}

# Result of the command line, not settings: kept in private shell variables,
# never exported and never read from the environment, and read through the
# functions below. Only --verbose is a setting that must reach child scripts,
# so it is exported as EASY_CS_AI_VERBOSE.
_OPT_HELP=0
_OPT_VERSION=0
_OPT_DRY_RUN=0
_OPT_JSON=0

wants_help() { [[ "$_OPT_HELP" == "1" ]]; }
wants_version() { [[ "$_OPT_VERSION" == "1" ]]; }
is_dry_run() { [[ "$_OPT_DRY_RUN" == "1" ]]; }
wants_json() { [[ "$_OPT_JSON" == "1" ]]; }

# parse_common_options <args…>: consume the options shared by every script
# (--help, --version, --verbose, --dry-run, --json), to be read with
# wants_help, wants_version, is_dry_run and wants_json (--verbose turns on
# log_debug for this script and the ones it starts). Everything else is left,
# in order, in the array COMMON_REST for the script's own parse_args. Unknown
# options are not an error here: the script rejects them (exit 2) once it has
# parsed its own, see reject_unknown_options.
COMMON_REST=()
parse_common_options() {
    COMMON_REST=()
    _OPT_HELP=0 _OPT_VERSION=0 _OPT_DRY_RUN=0 _OPT_JSON=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help) _OPT_HELP=1 ;;
            --version) _OPT_VERSION=1 ;;
            --verbose) export EASY_CS_AI_VERBOSE=1 ;;
            --dry-run) _OPT_DRY_RUN=1 ;;
            --json) _OPT_JSON=1 ;;
            *) COMMON_REST+=("$arg") ;;
        esac
    done
}

# reject_unknown_options <args…>: usage error (exit 2) for any leftover option.
reject_unknown_options() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == -* && "$arg" != "-" ]]; then
            die "$EXIT_USAGE" "unknown option: $arg"
        fi
    done
}

# --- Secrets (spec-script-contract.md, "Secrets") ---------------------------
# A secret is never taken from the command line. Accepted channels: a file
# (--<name>-file, mode 0600 or stricter), the environment (see get_option), or
# stdin. These helpers print the secret on stdout for the caller to capture;
# they never log it.

# read_secret <file|->: print the secret held in a file (mode 0600 or
# stricter, else exit 2) or read from stdin when the source is "-".
read_secret() {
    local source="${1:-}" value=""
    if [[ -z "$source" ]]; then
        die "$EXIT_USAGE" "read_secret: no source given"
    fi
    if [[ "$source" == "-" ]]; then
        IFS= read -r value || true
    else
        if [[ ! -f "$source" ]]; then
            die "$EXIT_USAGE" "secret file not found: $source"
        fi
        local mode
        mode="$(stat -c '%a' "$source")"
        if ((8#$mode & 8#077)); then
            die "$EXIT_USAGE" "secret file $source has mode $mode, 600 or stricter required"
        fi
        IFS= read -r value <"$source" || true
    fi
    if [[ -z "$value" ]]; then
        die "$EXIT_USAGE" "secret is empty"
    fi
    printf '%s\n' "$value"
}

# generate_secret: print a random secret, 32 bytes from /dev/urandom,
# base64url without padding.
generate_secret() {
    head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
    printf '\n'
}
