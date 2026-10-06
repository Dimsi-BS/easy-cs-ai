#!/usr/bin/env bash
# Ollama install script, see docs/spec-script-contract.md and search/ollama.md.
#
#   ollama.sh <action> [options]
#   actions: install uninstall status describe add-model remove-model list-models
set -euo pipefail

readonly NAME=ollama
readonly TYPE=engine
readonly SCRIPT_VERSION=0.1.0
readonly UNIT=ollama.service
readonly DEFAULT_VERSION=0.35.1
readonly HEALTH_TIMEOUT=60
# sha256 of ollama-linux-<arch>.tar.zst for DEFAULT_VERSION. Another --version
# is checked against the sha256sum.txt published with that release.
declare -A PINNED_SHA256=(
    [amd64]=9fcd79ac4575b2bd31b992eee18b1000c8ad126b451627c8f8cd091714cfbb10
    [arm64]=b1b1c85d25136b256d3740f6ecd2f7c0105e8ca71642fd6ff2fc199f3cefd69d
)
readonly ACTIONS="install uninstall status describe add-model remove-model list-models"

LIB_DIR="${EASY_CS_AI_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)}"
readonly LIB_DIR
readonly TEMPLATE_DIR="$LIB_DIR/../templates/ollama"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

ACTION="" FORCE=0 PURGE=0 MAKE_DEFAULT=0
POSITIONAL=()

usage() {
    cat <<EOF
Usage: ollama.sh <action> [options]

Actions: $ACTIONS

Options:
  --port <n>              listening port (default 11434, EASY_CS_AI_OLLAMA_PORT)
  --bind <address>        listening address (default 127.0.0.1, EASY_CS_AI_OLLAMA_BIND)
  --version <x.y.z>       Ollama version (default $DEFAULT_VERSION, EASY_CS_AI_OLLAMA_VERSION)
  --health-timeout <s>    seconds to wait for the API (default $HEALTH_TIMEOUT)
  --lock-timeout <s>      wait for a busy component lock instead of failing
  --default               install: make Ollama the default engine
  --force                 uninstall: even if another component requires it
  --purge                 uninstall: also remove models and the ollama user
  --help --version --verbose --dry-run --json
EOF
}

# --- Options ------------------------------------------------------------------

# The contract gives --version two meanings: the common flag (print the script
# version) and, for install, the component version to install. A value after
# it selects the second; it is renamed so the common parser leaves it alone.
rename_version_option() {
    RENAMED=()
    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        if [[ "$arg" == --version && $# -gt 0 && "$1" != -* ]]; then
            RENAMED+=(--component-version "$1")
            shift
        elif [[ "$arg" == --version=* ]]; then
            RENAMED+=(--component-version "${arg#*=}")
        else
            RENAMED+=("$arg")
        fi
    done
}

parse_args() {
    rename_version_option "$@"
    parse_common_options "${RENAMED[@]}"
    set -- "${COMMON_REST[@]}"
    if [[ $# -eq 0 ]]; then
        if wants_help || wants_version; then
            return 0
        fi
        usage >&2
        exit "$EXIT_USAGE"
    fi
    ACTION="$1"
    shift
    local opt value
    while [[ $# -gt 0 ]]; do
        opt="$1"
        shift
        case "$opt" in
        --port | --bind | --health-timeout | --lock-timeout | --component-version)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            value="$1"
            shift
            opt="${opt#--}"
            set_option "$NAME" "${opt#component-}" "$value"
            ;;
        --port=* | --bind=* | --health-timeout=* | --lock-timeout=*)
            value="${opt#*=}"
            opt="${opt%%=*}"
            set_option "$NAME" "${opt#--}" "$value"
            ;;
        --default) MAKE_DEFAULT=1 ;;
        --force) FORCE=1 ;;
        --purge) PURGE=1 ;;
        -*) die "$EXIT_USAGE" "unknown option: $opt" ;;
        *) POSITIONAL+=("$opt") ;;
        esac
    done
}

resolve_options() {
    set_option_default "$NAME" port 11434
    set_option_default "$NAME" bind 127.0.0.1
    set_option_default "$NAME" version "$DEFAULT_VERSION"
    set_option_default "$NAME" health-timeout "$HEALTH_TIMEOUT"
    PORT="$(get_option "$NAME" port)"
    BIND="$(get_option "$NAME" bind)"
    VERSION="$(get_option "$NAME" version)"
    HEALTH="$(get_option "$NAME" health-timeout)"
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
        die "$EXIT_USAGE" "invalid port '$PORT'"
    fi
    if [[ ! "$BIND" =~ ^[A-Za-z0-9.:-]+$ ]]; then
        die "$EXIT_USAGE" "invalid bind address '$BIND'"
    fi
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z]+)*$ ]]; then
        die "$EXIT_USAGE" "invalid version '$VERSION'"
    fi
    if [[ ! "$HEALTH" =~ ^[0-9]+$ ]]; then
        die "$EXIT_USAGE" "invalid health timeout '$HEALTH'"
    fi
}

# client_host: address to reach the server (a wildcard bind is reached locally).
client_host() {
    case "$1" in
    0.0.0.0 | "::" | "[::]") printf '127.0.0.1\n' ;;
    *) printf '%s\n' "$1" ;;
    esac
}

# adopt_recorded_params: for actions on an installed engine, use the parameters
# recorded at install unless the caller gave others.
adopt_recorded_params() {
    local json
    if json="$(state_read "$NAME")"; then
        set_option_default "$NAME" port "$(jq -r '.params.port // empty' <<<"$json")"
        set_option_default "$NAME" bind "$(jq -r '.params.bind // empty' <<<"$json")"
    fi
}

base_url() { printf 'http://%s:%s\n' "$(client_host "$BIND")" "$PORT"; }

# --- describe / help ------------------------------------------------------------

describe() {
    _require_jq
    jq -n --arg sv "$SCRIPT_VERSION" --arg cv "$DEFAULT_VERSION" --argjson ht "$HEALTH_TIMEOUT" \
        --arg actions "$ACTIONS" '{
        schema_version: 1, name: "ollama", type: "engine", script_version: $sv,
        component_version: $cv, requires: [], provides: ["openai-api"],
        platforms: ["debian", "ubuntu"], health_timeout: $ht,
        native: { command: "ollama", env: { OLLAMA_HOST: "{bind}:{port}" } },
        options: [
          { name: "port", env: "EASY_CS_AI_OLLAMA_PORT", default: "11434", secret: false, description: "Listening port" },
          { name: "bind", env: "EASY_CS_AI_OLLAMA_BIND", default: "127.0.0.1", secret: false, description: "Listening address" },
          { name: "version", env: "EASY_CS_AI_OLLAMA_VERSION", default: $cv, secret: false, description: "Ollama version to install" },
          { name: "health-timeout", env: "EASY_CS_AI_OLLAMA_HEALTH_TIMEOUT", default: ($ht | tostring), secret: false, description: "Seconds to wait for the API after start" },
          { name: "lock-timeout", env: "EASY_CS_AI_OLLAMA_LOCK_TIMEOUT", default: "0", secret: false, description: "Seconds to wait for a busy component lock" }
        ],
        actions: ($actions | split(" "))
      }'
}

# --- Helpers ----------------------------------------------------------------------

# run_logged <action> <command…>: journal start and end around a changing
# action. The command runs in a subshell so that a die still logs the end.
run_logged() {
    local action="$1" start=$SECONDS rc=0
    shift
    log_event "$NAME $action start version=$VERSION params=port=$PORT,bind=$BIND"
    ("$@") || rc=$?
    log_event "$NAME $action end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}

service_active() {
    ! is_test_root && systemctl is-active --quiet "$UNIT"
}

arch_name() {
    case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64) printf 'arm64\n' ;;
    *) die "$EXIT_UNSUPPORTED" "unsupported architecture '$(uname -m)'" ;;
    esac
}

# check_free <path> <megabytes>
check_free() {
    local free
    free="$(df -Pm "$1" | awk 'NR==2 {print $4}')"
    if ((free < $2)); then
        die "$EXIT_PRECONDITION" "not enough disk space on $1: ${free} MB free, $2 MB needed"
    fi
}

port_in_use() {
    command -v ss >/dev/null 2>&1 && [[ -n "$(ss -H -ltn "sport = :$PORT" 2>/dev/null)" ]]
}

recorded_version() { state_read "$NAME" 2>/dev/null | jq -r '.version // empty' || true; }

# --- install ----------------------------------------------------------------------

preflight() {
    require_root
    require_platform
    _require_jq
    if is_test_root; then
        return 0
    fi
    check_free /usr/local 6144
    check_free /var/tmp 2048
    if port_in_use && ! service_active; then
        die "$EXIT_PRECONDITION" "port $PORT is already in use by another process"
    fi
}

# expected_sha256 <arch> <archive-name>
expected_sha256() {
    if [[ "$VERSION" == "$DEFAULT_VERSION" ]]; then
        printf '%s\n' "${PINNED_SHA256[$1]}"
        return 0
    fi
    local sums
    sums="$(curl -fsSL "https://github.com/ollama/ollama/releases/download/v$VERSION/sha256sum.txt")" ||
        die "$EXIT_NETWORK" "could not fetch the checksums of Ollama $VERSION"
    awk -v f="$2" '{ n = $2; sub(/^\*?(\.\/)?/, "", n); if (n == f) print $1 }' <<<"$sums"
}

install_binary() {
    local arch archive url expected tmp actual
    if is_test_root; then
        log_info "(test mode) would download and unpack Ollama $VERSION"
        return 0
    fi
    arch="$(arch_name)"
    archive="ollama-linux-$arch.tar.zst"
    url="https://github.com/ollama/ollama/releases/download/v$VERSION/$archive"
    expected="$(expected_sha256 "$arch" "$archive")"
    [[ -n "$expected" ]] || die "$EXIT_NETWORK" "no checksum published for $archive ($VERSION)"
    apt_install curl ca-certificates zstd
    tmp="$(mktemp -p /var/tmp easy-cs-ai-ollama.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT
    log_info "downloading $url"
    curl -fL --retry 3 --retry-delay 5 -sS -o "$tmp" "$url" || die "$EXIT_NETWORK" "download failed: $url"
    actual="$(sha256sum "$tmp" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "$EXIT_NETWORK" "checksum mismatch for $archive"
    track_file /usr/local/bin/ollama
    track_file /usr/local/lib/ollama
    rm -rf "$(root_path /usr/local/lib/ollama)"
    tar --zstd -C /usr/local -xf "$tmp"
    rm -f "$tmp"
    trap - EXIT
}

ensure_user() {
    if is_test_root; then
        log_info "(test mode) would create the ollama user"
        return 0
    fi
    track_data_dir /usr/share/ollama/.ollama
    if ! id ollama >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -U -m -d /usr/share/ollama ollama >&2
    fi
    mkdir -p /usr/share/ollama/.ollama
    chown -R ollama:ollama /usr/share/ollama
}

record_state() {
    local json files dirs
    files="$(pending_read "$NAME" | jq -c '.files + ["/etc/systemd/system/'"$UNIT"'"] | unique')"
    dirs="$(pending_read "$NAME" | jq -c '.data_dirs + ["/usr/share/ollama/.ollama"] | unique')"
    json="$(jq -n --arg v "$VERSION" --arg sv "$SCRIPT_VERSION" --arg port "$PORT" --arg bind "$BIND" \
        --arg url "$(base_url)" --arg unit "$UNIT" --argjson files "$files" --argjson dirs "$dirs" \
        --argjson default "$MAKE_DEFAULT" '{
        name: "ollama", type: "engine", version: $v, script_version: $sv,
        params: { port: $port, bind: $bind },
        endpoint: { url: $url, openai_base_url: ($url + "/v1"), protected: false },
        service: { unit: $unit }, requires: [], files: $files, data_dirs: $dirs, secrets: []
      } + (if $default == 1 then { default: true } else {} end)')"
    if ! state_read "$NAME" >/dev/null 2>&1; then
        json="$(jq '. + { models: [] }' <<<"$json")"
    fi
    state_write "$NAME" "$json"
}

do_install() {
    local changed=0 rc=0 was_active=0
    service_active && was_active=1
    pending_begin "$TYPE" "$NAME"
    if [[ "$(recorded_version)" != "$VERSION" ]] || { ! is_test_root && [[ ! -x /usr/local/bin/ollama ]]; }; then
        changed=1
        ((was_active)) && systemd_disable_now "$UNIT"
        install_binary
    fi
    ensure_user
    OLLAMA_BIND="$BIND" OLLAMA_PORT="$PORT" render_template "$TEMPLATE_DIR/ollama.service" \
        "/etc/systemd/system/$UNIT" 0644 root:root || rc=$?
    if ((rc == 0)); then
        changed=1
    elif ((rc != 10)); then
        exit "$rc"
    fi
    systemd_enable_now "$UNIT"
    if ((changed && was_active)); then
        systemd_restart "$UNIT"
    elif ((!changed)); then
        log_info "already installed, nothing to change"
    fi
    if is_test_root; then
        log_info "(test mode) health check skipped"
    else
        wait_for_http "$(base_url)/api/version" "$HEALTH" "$UNIT" || {
            journalctl -u "$UNIT" -n 20 --no-pager >&2 || true
            exit "$EXIT_VERIFY"
        }
    fi
    record_state
    if ((MAKE_DEFAULT)); then
        defaults_set "$TYPE" "$NAME"
    fi
    pending_remove "$NAME"
    log_info "Ollama $VERSION is installed and answers on $(base_url)"
}

cmd_install() {
    preflight
    if is_dry_run; then
        log_info "dry run: would install Ollama $VERSION under /usr/local, create the ollama user," \
            "write /etc/systemd/system/$UNIT (bind $BIND, port $PORT), start it and record the state"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" install run_logged install do_install
}

# --- uninstall --------------------------------------------------------------------

remove_path() {
    local path="$1"
    if [[ "$path" != /?* || "$path" == *..* ]]; then
        log_warn "ignoring suspicious path in state: $path"
        return 0
    fi
    rm -rf "$(root_path "$path")"
}

do_uninstall() {
    local state="" pending="" other path
    state="$(state_read "$NAME" 2>/dev/null || true)"
    pending="$(pending_read "$NAME" 2>/dev/null || true)"
    if [[ -z "$state" && -z "$pending" ]]; then
        die "$EXIT_PRECONDITION" "$NAME is not installed"
    fi
    if ((!FORCE)); then
        # shellcheck disable=SC2119
        while read -r other; do
            [[ "$other" == "$NAME" || -z "$other" ]] && continue
            if state_read "$other" | jq -e --arg n "$NAME" '(.requires // []) | index($n)' >/dev/null; then
                die "$EXIT_PRECONDITION" "$other requires $NAME, uninstall it first or use --force"
            fi
        done < <(state_list)
    fi
    systemd_disable_now "$UNIT"
    while IFS= read -r path; do
        [[ -n "$path" ]] && remove_path "$path"
    done < <(jq -rs '[.[] | (.files // [])[]] | unique[]' <<<"$state $pending")
    remove_path "/etc/systemd/system/$UNIT"
    if ((PURGE)); then
        while IFS= read -r path; do
            [[ -n "$path" ]] && remove_path "$path"
        done < <(jq -rs '[.[] | (.data_dirs // [])[]] | unique[]' <<<"$state $pending")
        if ! is_test_root && id ollama >/dev/null 2>&1; then
            userdel ollama >&2 || log_warn "could not remove the ollama user"
        fi
    fi
    state_remove "$NAME"
    pending_remove "$NAME"
    _systemctl daemon-reload
    log_info "Ollama is uninstalled$( ((PURGE)) || printf ' (models kept, use --purge to remove them)')"
}

cmd_uninstall() {
    require_root
    _require_jq
    if is_dry_run; then
        log_info "dry run: would stop $UNIT, remove the recorded files and the state"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" uninstall run_logged uninstall do_uninstall
}

# --- status -----------------------------------------------------------------------

cmd_status() {
    _require_jq
    local json installed=false running=false healthy=false version=null rc=0
    if json="$(state_read "$NAME")"; then
        installed=true
        version="$(jq '.version' <<<"$json")"
        service_active && running=true
        if ! is_test_root && curl -fsS -o /dev/null --max-time 5 "$(base_url)/api/version" 2>/dev/null; then
            healthy=true
        fi
        [[ "$healthy" == true ]] || rc=$EXIT_VERIFY
    else
        rc=$EXIT_PRECONDITION
    fi
    jq -n --argjson i "$installed" --argjson r "$running" --argjson h "$healthy" --argjson v "$version" \
        '{ schema_version: 1, name: "ollama", installed: $i, running: $r, healthy: $h, version: $v }'
    return "$rc"
}

# --- models -----------------------------------------------------------------------

require_running() {
    state_read "$NAME" >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "$NAME is not installed"
    if is_test_root; then
        return 0
    fi
    service_active || die "$EXIT_PRECONDITION" "$UNIT is not running"
}

check_model_name() {
    if [[ -z "${1:-}" || ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]]; then
        die "$EXIT_USAGE" "invalid or missing model name '${1:-}'"
    fi
}

# ollama_cli <args…>: the native command, pointed at the installed instance.
ollama_cli() {
    OLLAMA_HOST="$(client_host "$BIND"):$PORT" ollama "$@" >&2
}

# list-models: the models served by the instance, as JSON read from its own API
# (`ollama list` is a table meant for people).
cmd_list_models() {
    state_read "$NAME" >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "$NAME is not installed"
    curl -fsS --max-time 10 "$(base_url)/api/tags" | jq '[.models[] | { name, size, modified_at }]'
}

do_add_model() {
    local model="$1"
    ollama_cli pull "$model" || die "$EXIT_NETWORK" "could not pull $model"
    state_write "$NAME" "$(state_read "$NAME" | jq --arg m "$model" --arg d "$(_state_now)" '{
        models: ((.models // []) | if any(.name == $m) then . else . + [{ name: $m, added_at: $d, exposed_via: null, linked_to: [] }] end)
      }')"
    log_info "model $model is available"
}

cmd_add_model() {
    check_model_name "${POSITIONAL[0]:-}"
    require_root
    require_running
    if is_dry_run; then
        log_info "dry run: would pull ${POSITIONAL[0]}"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" add-model run_logged add-model do_add_model "${POSITIONAL[0]}"
}

do_remove_model() {
    local model="$1"
    ollama_cli rm "$model" || die "$EXIT_PRECONDITION" "could not remove $model (not present?)"
    state_write "$NAME" "$(state_read "$NAME" | jq --arg m "$model" '{ models: ((.models // []) | map(select(.name != $m))) }')"
    log_info "model $model is removed"
}

cmd_remove_model() {
    check_model_name "${POSITIONAL[0]:-}"
    require_root
    require_running
    if is_dry_run; then
        log_info "dry run: would remove ${POSITIONAL[0]}"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" remove-model run_logged remove-model do_remove_model "${POSITIONAL[0]}"
}

# --- main -------------------------------------------------------------------------

main() {
    parse_args "$@"
    if wants_help; then
        usage
        return 0
    fi
    if wants_version; then
        printf '%s\n' "$SCRIPT_VERSION"
        return 0
    fi
    case " $ACTIONS " in
    *" $ACTION "*) ;;
    *) die "$EXIT_USAGE" "unknown action '$ACTION' (expected: $ACTIONS)" ;;
    esac
    if [[ "$ACTION" == describe ]]; then
        describe
        return 0
    fi
    if [[ "$ACTION" != install ]]; then
        adopt_recorded_params
    fi
    resolve_options
    case "$ACTION" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    list-models) cmd_list_models ;;
    add-model) cmd_add_model ;;
    remove-model) cmd_remove_model ;;
    esac
}

main "$@"
