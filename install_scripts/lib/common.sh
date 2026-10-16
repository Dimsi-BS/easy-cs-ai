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

# use_color <fd>: succeeds when output on that file descriptor may be colored.
# Never for NO_COLOR (https://no-color.org), TERM=dumb or a pipe or file, so
# captured and parsed output stays plain; EASY_CS_AI_COLOR=always forces it on
# and =never forces it off.
use_color() {
    case "${EASY_CS_AI_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    esac
    [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb && -t "${1:-2}" ]]
}

# _color_code <level|style>: the ANSI sequence of a log level or style.
_color_code() {
    case "$1" in
    ERROR | red) printf '\033[1;31m' ;;
    WARN | yellow) printf '\033[1;33m' ;;
    INFO | green) printf '\033[32m' ;;
    DEBUG | dim) printf '\033[2m' ;;
    bold) printf '\033[1m' ;;
    esac
}

_log() {
    local level="$1"
    shift
    if use_color 2; then
        case "$level" in
        # lines to notice or to ignore are colored whole, routine ones by their tag only
        ERROR | WARN | DEBUG) printf '%b[%s] %s\033[0m\n' "$(_color_code "$level")" "$level" "$*" >&2 ;;
        *) printf '[%b%s\033[0m] %s\n' "$(_color_code "$level")" "$level" "$*" >&2 ;;
        esac
    else
        printf '[%s] %s\n' "$level" "$*" >&2
    fi
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

# once_only <option>: an option of an action may be given once, unless its `describe` says it is
# `repeatable` (docs/spec-script-contract.md#describe): given again it is a usage error, exit 2.
declare -A _ONCE_SEEN=()
once_only() {
    if [[ -n "${_ONCE_SEEN[$1]:-}" ]]; then
        die "$EXIT_USAGE" "$1 is given more than once"
    fi
    _ONCE_SEEN[$1]=1
}

# generate_secret: print a random secret, 32 bytes from /dev/urandom,
# base64url without padding.
generate_secret() {
    head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
    printf '\n'
}

# --- Locking (spec-script-contract.md, "Locking") ---------------------------
# Two flock-based locks, always taken component first, then state:
#   - state lock     <state>/.lock, fd 9, a few seconds, waits (60 s) then exit 1
#   - component lock <state>/locks/<type>-<name>.lock, fd 8, whole action,
#                    fails at once with exit 4 unless a lock timeout is given
# Neither is reentrant: the held locks are listed in EASY_CS_AI_LOCK_HELD, and
# taking one twice is a bug that ends with exit 1 instead of a silent hang.
# The command runs with the lock descriptors closed (the lock stays held by
# this shell), so background children it starts never keep the lock alive.
# The command runs in the current shell, so it can be a function.

# _lock_check_free <lock-id>: die if this lock is already held by this chain.
_lock_check_free() {
    if [[ " ${EASY_CS_AI_LOCK_HELD:-} " == *" $1 "* ]]; then
        die "$EXIT_ERROR" "lock '$1' is already held, locks are not reentrant"
    fi
}

# with_state_lock <command…>: run the command under the state lock, waiting up
# to 60 s for it (the contract's value).
with_state_lock() {
    with_state_lock_timeout 60 "$@"
}

# with_state_lock_timeout <seconds> <command…>: same, with another wait. Busy
# after that: exit 1. A state directory that is not an absolute path ends the
# script (die in root_path) before any lock file is created.
with_state_lock_timeout() {
    if [[ $# -lt 2 || ! "$1" =~ ^[0-9]+$ ]]; then
        die "$EXIT_USAGE" "with_state_lock: usage: with_state_lock <command…>"
    fi
    local wait="$1"
    shift
    _lock_check_free state

    local dir
    dir="$(state_dir)" || exit "$?"
    mkdir -p "$dir"
    exec 9>>"$dir/.lock"
    if ! flock -w "$wait" 9; then
        exec 9>&-
        die "$EXIT_ERROR" "could not take the state lock within ${wait}s"
    fi

    local previous="${EASY_CS_AI_LOCK_HELD:-}" rc=0
    export EASY_CS_AI_LOCK_HELD="$previous state"
    "$@" 8>&- 9>&-
    rc=$?
    exec 9>&-
    export EASY_CS_AI_LOCK_HELD="$previous"
    return "$rc"
}

# with_component_lock <type> <name> <action> <command…>: run the command under the lock
# of one component. Busy: exit 4 naming the holder's action and pid, unless
# EASY_CS_AI_<NAME>_LOCK_TIMEOUT (--lock-timeout) gives a number of seconds to
# wait. The action (install, uninstall, add-model…) is recorded in the lock
# file so that a busy message can name it.
with_component_lock() {
    if [[ $# -lt 4 ]]; then
        die "$EXIT_USAGE" "with_component_lock: usage: with_component_lock <type> <name> <action> <command…>"
    fi
    local type="$1" name="$2" action="$3"
    shift 3
    local id="component:${type}-${name}"
    _lock_check_free "$id"

    local dir file wait
    dir="$(state_dir)/locks" || exit "$?"
    file="$dir/${type}-${name}.lock"
    wait="$(get_option "$name" lock-timeout)"
    wait="${wait:-0}"
    if [[ ! "$wait" =~ ^[0-9]+$ ]]; then
        die "$EXIT_USAGE" "invalid lock timeout '$wait' for $name: a number of seconds is expected"
    fi
    mkdir -p "$dir"
    exec 8>>"$file"
    if ! flock -w "$wait" 8; then
        exec 8>&-
        local holder
        holder="$(cat "$file" 2>/dev/null || true)"
        local holder_action="${holder%% *}" holder_pid="${holder##* }"
        die "$EXIT_PRECONDITION" "another action is running on $name (${holder_action:-unknown}, pid ${holder_pid:-unknown})"
    fi
    # Informative only: who holds the lock. Written after the lock is taken.
    printf '%s %s\n' "$action" "$$" >"$file"

    local previous="${EASY_CS_AI_LOCK_HELD:-}" rc=0
    export EASY_CS_AI_LOCK_HELD="$previous $id"
    "$@" 8>&- 9>&-
    rc=$?
    exec 8>&-
    export EASY_CS_AI_LOCK_HELD="$previous"
    return "$rc"
}

# --- State (spec-state-format.md) -------------------------------------------
# One JSON file per installed component: <state>/components/<name>.json.
# Writers take the state lock (callers never hold it) and write atomically
# (temp file, jq empty, mv). Readers take no lock. Everything below needs jq.
# The *_unlocked functions run inside with_state_lock and are internal.

readonly STATE_SCHEMA_VERSION=1

_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        die "$EXIT_PRECONDITION" "jq is required but not installed"
    fi
}

# _state_now: current time, ISO 8601 UTC.
_state_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _state_check_name <name>: component names are plain words, never a path.
_state_check_name() {
    if [[ ! "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "$EXIT_USAGE" "invalid component name '${1:-}': lowercase letters, digits and dashes expected"
    fi
}

# _state_dir_components: directory of the component files.
_state_dir_components() {
    local dir
    dir="$(state_dir)" || exit "$?"
    printf '%s/components\n' "$dir"
}

# _state_file <name>: path of the file of one component.
_state_file() {
    _state_check_name "$1"
    local dir
    dir="$(_state_dir_components)" || exit "$?"
    printf '%s/%s.json\n' "$dir" "$1"
}

# _state_store_unlocked <name> <json>: validate and write one component file
# atomically (temp file in the same directory, jq empty, mv), mode 0644.
_state_store_unlocked() {
    local name="$1" json="$2" file dir tmp
    file="$(_state_file "$name")" || exit "$?"
    dir="${file%/*}"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.${name}.XXXXXX")"
    printf '%s\n' "$json" >"$tmp"
    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        die "$EXIT_ERROR" "refusing to write invalid JSON for component $name"
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file"
}

# _state_names [<type>]: component names, one per line, sorted.
_state_names() {
    local dir file
    dir="$(_state_dir_components)" || exit "$?"
    for file in "$dir"/*.json; do
        [[ -e "$file" ]] || continue
        if [[ -n "${1:-}" ]]; then
            jq -e --arg t "$1" '.type == $t' "$file" >/dev/null 2>&1 || continue
        fi
        file="${file##*/}"
        printf '%s\n' "${file%.json}"
    done
}

# _state_defaults <type>: names of the components of this type flagged default.
_state_defaults() {
    local dir file
    dir="$(_state_dir_components)" || exit "$?"
    for file in "$dir"/*.json; do
        [[ -e "$file" ]] || continue
        jq -e --arg t "$1" '.type == $t and .default == true' "$file" >/dev/null 2>&1 || continue
        file="${file##*/}"
        printf '%s\n' "${file%.json}"
    done
}

# _state_set_default_flag_unlocked <name> <true|false>: change one flag, and
# updated_at when it actually changed.
_state_set_default_flag_unlocked() {
    local name="$1" flag="$2" file old new
    file="$(_state_file "$name")" || exit "$?"
    old="$(cat "$file")"
    new="$(jq --argjson f "$flag" --arg now "$(_state_now)" \
        'if .default == $f then . else .default = $f | .updated_at = $now end' <<<"$old")"
    if [[ "$new" != "$old" ]]; then
        _state_store_unlocked "$name" "$new"
    fi
}

# _state_clear_other_defaults_unlocked <type> <name>: the writer sets the new
# flag first (done by the caller), then clears the others.
_state_clear_other_defaults_unlocked() {
    local other
    while IFS= read -r other; do
        if [[ -n "$other" && "$other" != "$2" ]]; then
            _state_set_default_flag_unlocked "$other" false
        fi
    done < <(_state_defaults "$1")
}

# _state_write_unlocked <name> <json>
_state_write_unlocked() {
    local name="$1" json="$2" file old merged now type others
    file="$(_state_file "$name")" || exit "$?"
    now="$(_state_now)"
    if ! jq -e 'type == "object"' <<<"$json" >/dev/null 2>&1; then
        die "$EXIT_ERROR" "state for $name is not a JSON object"
    fi
    if [[ "$(jq -r '.name // empty' <<<"$json")" != "$name" ]]; then
        die "$EXIT_ERROR" "state for $name has a different or missing \"name\""
    fi
    type="$(jq -r '.type // empty' <<<"$json")"
    case "$type" in
        engine | chat-interface | proxy | provisioning) ;;
        *) die "$EXIT_ERROR" "state for $name has an invalid or missing \"type\": '$type'" ;;
    esac

    old='{}'
    if [[ -f "$file" ]]; then
        old="$(cat "$file")"
    fi
    # Unknown fields of the existing file are kept (old + new, new wins).
    merged="$(jq --argjson old "$old" --arg now "$now" --argjson v "$STATE_SCHEMA_VERSION" \
        '$old + . | .schema_version = (.schema_version // $v)
         | .installed_at = ($old.installed_at // .installed_at // $now)' <<<"$json")"

    # The first component of a type becomes its default, unless told otherwise.
    if [[ "$(jq 'has("default")' <<<"$merged")" == "false" ]]; then
        others="$(_state_defaults "$type" | grep -vx "$name" || true)"
        if [[ -z "$others" ]]; then
            merged="$(jq '.default = true' <<<"$merged")"
        else
            merged="$(jq '.default = false' <<<"$merged")"
        fi
    fi

    # Rewrite only when the content changed, so updated_at means something.
    if [[ "$old" != '{}' ]] &&
        [[ "$(jq -S 'del(.updated_at)' <<<"$old")" == "$(jq -S 'del(.updated_at)' <<<"$merged")" ]]; then
        return 0
    fi
    merged="$(jq --arg now "$now" '.updated_at = $now' <<<"$merged")"
    _state_store_unlocked "$name" "$merged"

    if [[ "$(jq '.default' <<<"$merged")" == "true" ]]; then
        _state_clear_other_defaults_unlocked "$type" "$name"
    fi
}

# state_write <component> <json>: create or update the state of a component.
# Fields the writer does not know are kept, installed_at is kept, updated_at
# only changes when the content does, and the first component of a type
# becomes its default. A "default": true clears the flag of the others.
state_write() {
    _require_jq
    if [[ $# -ne 2 ]]; then
        die "$EXIT_USAGE" "state_write: usage: state_write <component> <json>"
    fi
    _state_check_name "$1"
    with_state_lock _state_write_unlocked "$1" "$2"
}

# state_read <component>: print the state JSON. Returns 1, printing nothing,
# when the component has no state. No lock (writes are atomic). A state of a
# newer schema than this library knows is refused (exit 1).
state_read() {
    _require_jq
    local file version
    file="$(_state_file "${1:-}")" || exit "$?"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    if ! version="$(jq -er '.schema_version' "$file" 2>/dev/null)"; then
        die "$EXIT_ERROR" "state file $file is not valid or has no schema_version"
    fi
    if ((version > STATE_SCHEMA_VERSION)); then
        die "$EXIT_ERROR" "state file $file has schema_version $version, this version understands up to $STATE_SCHEMA_VERSION"
    fi
    cat "$file"
}

# state_list [<type>]: names of the components that have a state, sorted.
state_list() {
    _require_jq
    _state_names "${1:-}"
}

_state_remove_unlocked() {
    local name="$1" file type was_default remaining
    file="$(_state_file "$name")" || exit "$?"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    type="$(jq -r '.type // empty' "$file")"
    was_default="$(jq -r '.default // false' "$file")"
    rm -f "$file"
    # The default is gone: the only component left of the type is promoted,
    # otherwise the type has no default and nothing is guessed.
    if [[ "$was_default" == "true" && -n "$type" ]]; then
        remaining="$(_state_names "$type")"
        if [[ -n "$remaining" && "$remaining" != *$'\n'* ]]; then
            _state_set_default_flag_unlocked "$remaining" true
        fi
    fi
}

# state_remove <component>: delete the state of a component (nothing to do if
# it has none), and promote the last remaining component of its type to
# default if it was the default.
state_remove() {
    _require_jq
    if [[ $# -ne 1 ]]; then
        die "$EXIT_USAGE" "state_remove: usage: state_remove <component>"
    fi
    _state_check_name "$1"
    with_state_lock _state_remove_unlocked "$1"
}

# defaults_get <type>: print the name of the default component of a type.
# Returns 1, printing nothing, when the type has none. Several defaults are
# read again once (a change may be in progress), then it is an error (exit 1).
defaults_get() {
    _require_jq
    local names count
    names="$(_state_defaults "${1:-}")"
    count="$(grep -c . <<<"$names" || true)"
    if ((count > 1)); then
        sleep 1
        names="$(_state_defaults "$1")"
        count="$(grep -c . <<<"$names" || true)"
        if ((count > 1)); then
            die "$EXIT_ERROR" "several defaults for type $1 ($(tr '\n' ' ' <<<"$names")): run 'install $1 <name> --default' to repair"
        fi
    fi
    if ((count == 0)); then
        return 1
    fi
    printf '%s\n' "$names"
}

_defaults_set_unlocked() {
    local type="$1" name="$2" file
    file="$(_state_file "$name")" || exit "$?"
    if [[ ! -f "$file" ]]; then
        die "$EXIT_PRECONDITION" "$name is not installed"
    fi
    if [[ "$(jq -r '.type' "$file")" != "$type" ]]; then
        die "$EXIT_PRECONDITION" "$name is not a component of type $type"
    fi
    _state_set_default_flag_unlocked "$name" true
    _state_clear_other_defaults_unlocked "$type" "$name"
}

# defaults_set <type> <name>: make a component the default of its type. The
# new flag is set first, then the others are cleared, so an interruption
# leaves two defaults (repaired by running it again), never none.
defaults_set() {
    _require_jq
    if [[ $# -ne 2 ]]; then
        die "$EXIT_USAGE" "defaults_set: usage: defaults_set <type> <name>"
    fi
    _state_check_name "$2"
    with_state_lock _defaults_set_unlocked "$1" "$2"
}

# --- Platform and component preconditions ------------------------------------

# require_platform: exit 3 unless running on Debian/Ubuntu (or derived), on
# x86_64 or aarch64, with systemd as init (spec-script-contract.md,
# "Platform"). Skipped in test mode.
require_platform() {
    if is_test_root; then
        log_debug "test mode: platform check skipped"
        return 0
    fi
    local id="" id_like=""
    if [[ -r /etc/os-release ]]; then
        id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
        id_like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')"
    fi
    case " $id $id_like " in
    *" debian "* | *" ubuntu "*) ;;
    *) die "$EXIT_UNSUPPORTED" "unsupported distribution '${id:-unknown}': Debian or Ubuntu expected" ;;
    esac
    case "$(uname -m)" in
    x86_64 | aarch64) ;;
    *) die "$EXIT_UNSUPPORTED" "unsupported architecture '$(uname -m)': x86_64 or aarch64 expected" ;;
    esac
    if [[ ! -d /run/systemd/system ]]; then
        die "$EXIT_UNSUPPORTED" "systemd is required as the running init, it is not"
    fi
}

# require_component <name>: exit 4 unless the component is installed (has a
# state). Scripts check their requirements, they never install them.
require_component() {
    if [[ $# -ne 1 ]]; then
        die "$EXIT_USAGE" "require_component: usage: require_component <name>"
    fi
    if ! state_read "$1" >/dev/null; then
        die "$EXIT_PRECONDITION" "required component $1 is not installed"
    fi
}

# --- Pending manifest (spec-state-format.md, "Pending manifest") -------------
# Records, before creating them, the files, units and data directories an
# install creates, so a failed install can always be cleaned by uninstall.
# Only the holder of the component lock touches it: no state lock needed.

_PENDING_NAME=""
_PENDING_TYPE=""

_pending_file() {
    _state_check_name "$1"
    local dir
    dir="$(state_dir)" || exit "$?"
    printf '%s/pending/%s.json\n' "$dir" "$1"
}

# _pending_store <json>: atomic write (temp file, jq empty, mv), mode 0644.
_pending_store() {
    local file dir tmp
    file="$(_pending_file "$_PENDING_NAME")" || exit "$?"
    dir="${file%/*}"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.${_PENDING_NAME}.XXXXXX")"
    printf '%s\n' "$1" >"$tmp"
    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        die "$EXIT_ERROR" "refusing to write invalid JSON for the pending manifest of $_PENDING_NAME"
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file"
}

# pending_begin <type> <name>: select the component the track_* functions
# record for, and create its manifest unless one exists (a re-run completes it).
pending_begin() {
    _require_jq
    if [[ $# -ne 2 ]]; then
        die "$EXIT_USAGE" "pending_begin: usage: pending_begin <type> <name>"
    fi
    _state_check_name "$2"
    _PENDING_TYPE="$1"
    _PENDING_NAME="$2"
    local file
    file="$(_pending_file "$2")" || exit "$?"
    if [[ -f "$file" ]]; then
        return 0
    fi
    _pending_store "$(jq -n --arg n "$2" --arg t "$1" --arg d "$(_state_now)" \
        '{schema_version: 1, name: $n, type: $t, started_at: $d, files: [], units: [], data_dirs: []}')"
}

# pending_read <name>: print the manifest, return 1 with no output when none.
pending_read() {
    local file
    file="$(_pending_file "${1:-}")" || exit "$?"
    [[ -f "$file" ]] || return 1
    cat "$file"
}

# pending_remove <name>: delete the manifest (nothing to do if absent).
pending_remove() {
    local file
    file="$(_pending_file "${1:-}")" || exit "$?"
    rm -f "$file"
}

# _pending_add <key> <value>: add a value to one list, once.
_pending_add() {
    if [[ -z "$_PENDING_NAME" ]]; then
        die "$EXIT_ERROR" "track_*: no install in progress, call pending_begin first"
    fi
    local file
    file="$(_pending_file "$_PENDING_NAME")" || exit "$?"
    _pending_store "$(jq --arg k "$1" --arg v "$2" 'if (.[$k] | index($v)) then . else .[$k] += [$v] end' "$file")"
}

# track_file / track_unit / track_data_dir <value>: record before creating.
# Paths are logical (EASY_CS_AI_ROOT is not applied).
track_file() { _pending_add files "${1:?track_file: path expected}"; }
track_unit() { _pending_add units "${1:?track_unit: unit expected}"; }
track_data_dir() { _pending_add data_dirs "${1:?track_data_dir: path expected}"; }

# --- Files, packages and services ---------------------------------------------

# render_template <template> <destination> <mode> <owner>: render a template
# with envsubst (variables from the environment) into the logical absolute
# <destination>, atomically, with explicit mode and owner (<user>[:<group>]).
# Returns 0 when the file changed, 10 when it is identical (nothing written),
# so callers restart a service only when needed. Tracks the file in the
# pending manifest when an install is in progress.
render_template() {
    if [[ $# -ne 4 ]]; then
        die "$EXIT_USAGE" "render_template: usage: render_template <template> <destination> <mode> <owner>"
    fi
    local template="$1" dest mode="$3" owner="$4" tmp
    [[ -r "$template" ]] || die "$EXIT_ERROR" "template not found: $template"
    dest="$(root_path "$2")" || exit "$?"
    if [[ -n "$_PENDING_NAME" ]]; then
        track_file "$2"
    fi
    mkdir -p "${dest%/*}"
    tmp="$(mktemp "${dest%/*}/.${dest##*/}.XXXXXX")"
    if ! envsubst <"$template" >"$tmp"; then
        rm -f "$tmp"
        die "$EXIT_ERROR" "could not render template $template"
    fi
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 10
    fi
    chmod "$mode" "$tmp"
    if ! is_test_root; then
        chown "$owner" "$tmp"
    fi
    mv -f "$tmp" "$dest"
}

# apt_install <package…>: install packages non-interactively, skipping the
# ones already present. In test mode it only logs.
apt_install() {
    if [[ $# -eq 0 ]]; then
        die "$EXIT_USAGE" "apt_install: usage: apt_install <package…>"
    fi
    if is_test_root; then
        log_info "(test mode) would install packages: $*"
        return 0
    fi
    local missing=() package
    for package in "$@"; do
        dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    log_info "installing packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2 || die "$EXIT_NETWORK" "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >&2 ||
        die "$EXIT_NETWORK" "apt-get install failed: ${missing[*]}"
}

# _systemctl <args…>: run systemctl, or only log in test mode.
_systemctl() {
    if is_test_root; then
        log_info "(test mode) systemctl $*"
        return 0
    fi
    systemctl "$@" >&2
}

# systemd_enable_now <unit>: track, reload, enable and start a unit.
systemd_enable_now() {
    local unit="${1:?systemd_enable_now: unit expected}"
    if [[ -n "$_PENDING_NAME" ]]; then
        track_unit "$unit"
    fi
    _systemctl daemon-reload
    _systemctl enable --now "$unit"
}

# systemd_restart <unit>: reload unit files and restart.
systemd_restart() {
    _systemctl daemon-reload
    _systemctl restart "${1:?systemd_restart: unit expected}"
}

# systemd_disable_now <unit>: stop and disable; an unknown unit is not an error.
systemd_disable_now() {
    local unit="${1:?systemd_disable_now: unit expected}"
    if is_test_root; then
        log_info "(test mode) systemctl disable --now $unit"
        return 0
    fi
    systemctl disable --now "$unit" >&2 || log_debug "could not disable $unit (not installed?)"
    return 0
}

# --- Docker (docs/decision-librechat-install.md, point 1) ---------------------
# Docker comes from its own apt repository, so the packages have the same names
# on Debian and Ubuntu. An existing Docker with Compose v2, whatever its origin,
# is kept. Docker is a shared system package: nothing here is recorded in the
# pending manifest, so uninstall never removes the packages, the apt source or
# the signing key.

# Fingerprint of the signing key published by Docker (checked, not trusted blindly).
readonly DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
readonly DOCKER_APT_KEY=/etc/apt/keyrings/docker.asc
readonly DOCKER_APT_LIST=/etc/apt/sources.list.d/docker.list
readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)

# _docker_bin: the docker command. EASY_CS_AI_DOCKER replaces it, for the tests.
_docker_bin() { printf '%s\n' "${EASY_CS_AI_DOCKER:-docker}"; }

# docker_ready: Docker and the Compose v2 plugin are installed.
docker_ready() {
    local bin
    bin="$(_docker_bin)"
    command -v "$bin" >/dev/null 2>&1 && "$bin" compose version >/dev/null 2>&1
}

# _docker_repo <os-release-file>: print "<distro> <codename>" of Docker's repository
# for this system (ubuntu or debian, a derivative follows its parent).
_docker_repo() {
    local file="$1" id like codename ubuntu_codename distro
    [[ -r "$file" ]] || die "$EXIT_UNSUPPORTED" "cannot read $file: Debian or Ubuntu expected"
    id="$(sed -n 's/^ID=//p' "$file" | tr -d '"')"
    like="$(sed -n 's/^ID_LIKE=//p' "$file" | tr -d '"')"
    codename="$(sed -n 's/^VERSION_CODENAME=//p' "$file" | tr -d '"')"
    ubuntu_codename="$(sed -n 's/^UBUNTU_CODENAME=//p' "$file" | tr -d '"')"
    case " $id $like " in
    *" ubuntu "*)
        codename="${ubuntu_codename:-$codename}"
        distro=ubuntu
        ;;
    *" debian "*) distro=debian ;;
    *) die "$EXIT_UNSUPPORTED" "unsupported distribution '${id:-unknown}': Debian or Ubuntu expected" ;;
    esac
    [[ -n "$codename" ]] ||
        die "$EXIT_UNSUPPORTED" "no release codename in $file: Docker's repository needs a stable Debian or Ubuntu release"
    printf '%s %s\n' "$distro" "$codename"
}

# _docker_arch: the Debian architecture name Docker's repository uses.
_docker_arch() {
    case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64) printf 'arm64\n' ;;
    *) die "$EXIT_UNSUPPORTED" "unsupported architecture '$(uname -m)': x86_64 or aarch64 expected" ;;
    esac
}

# _docker_fetch_key <distro> <destination>: download the signing key, check its
# fingerprint, install it atomically (mode 0644).
_docker_fetch_key() {
    local distro="$1" dest="$2" tmp fingerprint
    tmp="$(mktemp "${dest%/*}/.${dest##*/}.XXXXXX")"
    if ! curl -fsSL --retry 3 --max-time 60 "https://download.docker.com/linux/$distro/gpg" -o "$tmp"; then
        rm -f "$tmp"
        die "$EXIT_NETWORK" "could not download the Docker signing key from download.docker.com"
    fi
    fingerprint="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
    if [[ "$fingerprint" != "$DOCKER_KEY_FINGERPRINT" ]]; then
        rm -f "$tmp"
        die "$EXIT_NETWORK" "the Docker signing key has an unexpected fingerprint '${fingerprint:-none}', refusing it"
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}

# _docker_write_source <distro> <codename> <arch>: the apt source, written only
# when it differs.
_docker_write_source() {
    local list tmp line
    list="$(root_path "$DOCKER_APT_LIST")"
    line="deb [arch=$3 signed-by=$DOCKER_APT_KEY] https://download.docker.com/linux/$1 $2 stable"
    mkdir -p "${list%/*}"
    tmp="$(mktemp "${list%/*}/.${list##*/}.XXXXXX")"
    printf '%s\n' "$line" >"$tmp"
    if [[ -f "$list" ]] && cmp -s "$tmp" "$list"; then
        rm -f "$tmp"
        return 0
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$list"
}

# _docker_daemon_up: start the Docker service when the daemon does not answer,
# then wait for it (30 s). Skipped in test mode.
_docker_daemon_up() {
    local bin deadline
    if is_test_root; then
        return 0
    fi
    bin="$(_docker_bin)"
    if "$bin" info >/dev/null 2>&1; then
        return 0
    fi
    _systemctl enable --now docker.service
    deadline=$((SECONDS + 30))
    until "$bin" info >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
            die "$EXIT_VERIFY" "the Docker daemon does not answer after 30 s (journalctl -u docker)"
        fi
        sleep 1
    done
}

# ensure_docker: make sure Docker and Compose v2 are installed and running. Does
# nothing when they are. Exit 3 on an unsupported distribution or architecture,
# 5 when Docker's repository or key cannot be reached or the key does not match.
# In test mode it writes the apt source under EASY_CS_AI_ROOT, and only logs the
# download, the packages and the service.
ensure_docker() {
    if docker_ready; then
        log_debug "Docker and Compose are already installed"
        _docker_daemon_up
        return 0
    fi
    local repo distro codename arch key
    repo="$(_docker_repo "$(root_path /etc/os-release)")" || exit "$?"
    distro="${repo% *}"
    codename="${repo#* }"
    arch="$(_docker_arch)" || exit "$?"
    log_info "installing Docker from its apt repository ($distro $codename, $arch)"
    apt_install ca-certificates curl gnupg
    key="$(root_path "$DOCKER_APT_KEY")"
    mkdir -p "${key%/*}"
    chmod 0755 "${key%/*}"
    if is_test_root; then
        log_info "(test mode) would download and check the signing key of download.docker.com"
    else
        _docker_fetch_key "$distro" "$key"
    fi
    _docker_write_source "$distro" "$codename" "$arch"
    apt_install "${DOCKER_PACKAGES[@]}"
    _systemctl enable --now docker.service
    _docker_daemon_up
    if ! is_test_root && ! docker_ready; then
        die "$EXIT_VERIFY" "Docker is installed but 'docker compose version' fails"
    fi
}
