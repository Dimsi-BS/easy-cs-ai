#!/usr/bin/env bash
# llmfit install script, see docs/spec-script-contract.md and search/llmfit.md.
#
#   llmfit.sh <action> [options]
#   actions: install uninstall status describe recommend check
set -euo pipefail

readonly NAME=llmfit
readonly TYPE=provisioning
readonly SCRIPT_VERSION=0.1.0
readonly DEFAULT_VERSION=1.1.16
readonly HEALTH_TIMEOUT=60
readonly BINARY=/usr/local/bin/llmfit
# sha256 of llmfit-v<version>-<arch>-unknown-linux-gnu.tar.gz for DEFAULT_VERSION.
# Another --version is checked against the .sha256 published next to its archive.
declare -A PINNED_SHA256=(
    [x86_64]=27fad93d5e579156e4d87609e1bdef51675342cef3da111ef0f58e1ec10be7f1
    [aarch64]=87d1fd489cd90d4e28e4421bd9a9411d89d4f1ee2526216db0207df4ba7152ff
)
readonly ACTIONS="install uninstall status describe recommend check"

LIB_DIR="${EASY_CS_AI_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)}"
readonly LIB_DIR
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

ACTION="" FORCE=0 MAKE_DEFAULT=0
POSITIONAL=()
# Hardware to size for instead of this machine (recommend and check), as llmfit's own
# global options, which go before its subcommand.
TARGET_ARGS=()

usage() {
    cat <<EOF
Usage: llmfit.sh <action> [options]

Actions: $ACTIONS
  recommend [args]        llmfit's own recommendations for this machine (JSON)
  check <model>           {"fits": true|false, "reason": "…"} for a model

Options of recommend and check, to size for another machine:
  --target-ram <GB>       RAM of the machine to size for (llmfit --ram)
  --target-vram <GB>      GPU memory of the machine to size for (llmfit --memory)
  --target-cpu-cores <n>  CPU cores of the machine to size for (llmfit --cpu-cores)

Options:
  --version <x.y.z>       llmfit version (default $DEFAULT_VERSION, EASY_CS_AI_LLMFIT_VERSION)
  --health-timeout <s>    seconds allowed to the verification (default $HEALTH_TIMEOUT)
  --lock-timeout <s>      wait for a busy component lock instead of failing
  --default               install: make llmfit the default of its type
  --force                 uninstall: even if another component requires it
  --purge                 uninstall: accepted and ignored, llmfit keeps no data
  --help --version --verbose --dry-run --json
EOF
}

# --- Options ------------------------------------------------------------------

# --version has two meanings (script version alone, llmfit version with a value),
# see the contract: a value after it is renamed so the common parser leaves it.
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
        --health-timeout | --lock-timeout | --component-version)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
            value="$1"
            shift
            opt="${opt#--}"
            set_option "$NAME" "${opt#component-}" "$value"
            ;;
        --health-timeout=* | --lock-timeout=*)
            value="${opt#*=}"
            opt="${opt%%=*}"
            set_option "$NAME" "${opt#--}" "$value"
            ;;
        --target-ram | --target-vram | --target-cpu-cores | --target-ram=* | --target-vram=* | --target-cpu-cores=*)
            if [[ "$opt" == *=* ]]; then
                value="${opt#*=}"
                opt="${opt%%=*}"
            else
                [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$opt needs a value"
                value="$1"
                shift
            fi
            [[ "$ACTION" == recommend || "$ACTION" == check ]] || die "$EXIT_USAGE" "$opt only applies to recommend and check"
            [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_USAGE" "$opt needs a positive whole number, got '$value'"
            case "$opt" in
            --target-ram) TARGET_ARGS+=(--ram "$value") ;;
            --target-vram) TARGET_ARGS+=(--memory "$value") ;;
            --target-cpu-cores) TARGET_ARGS+=(--cpu-cores "$value") ;;
            esac
            ;;
        --default) MAKE_DEFAULT=1 ;;
        --force) FORCE=1 ;;
        # `uninstall --all --purge` forwards --purge to every component: llmfit keeps no data, nothing to purge
        --purge) ;;
        -*)
            # recommend passes its own options to llmfit.
            [[ "$ACTION" == recommend ]] || die "$EXIT_USAGE" "unknown option: $opt"
            POSITIONAL+=("$opt")
            ;;
        *) POSITIONAL+=("$opt") ;;
        esac
    done
}

resolve_options() {
    set_option_default "$NAME" version "$DEFAULT_VERSION"
    set_option_default "$NAME" health-timeout "$HEALTH_TIMEOUT"
    VERSION="$(get_option "$NAME" version)"
    HEALTH="$(get_option "$NAME" health-timeout)"
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z]+)*$ ]]; then
        die "$EXIT_USAGE" "invalid version '$VERSION'"
    fi
    if [[ ! "$HEALTH" =~ ^[0-9]+$ ]]; then
        die "$EXIT_USAGE" "invalid health timeout '$HEALTH'"
    fi
}

describe() {
    _require_jq
    jq -n --arg sv "$SCRIPT_VERSION" --arg cv "$DEFAULT_VERSION" --argjson ht "$HEALTH_TIMEOUT" \
        --arg actions "$ACTIONS" '{
        schema_version: 1, name: "llmfit", type: "provisioning", script_version: $sv,
        component_version: $cv, requires: [], provides: ["model-fit"],
        platforms: ["debian", "ubuntu"], health_timeout: $ht,
        native: { command: "llmfit" },
        options: [
          { name: "version", env: "EASY_CS_AI_LLMFIT_VERSION", default: $cv, secret: false, description: "llmfit version to install" },
          { name: "health-timeout", env: "EASY_CS_AI_LLMFIT_HEALTH_TIMEOUT", default: ($ht | tostring), secret: false, type: "integer", min: 0, description: "Seconds allowed to the verification (llmfit recommend --json)" },
          { name: "lock-timeout", env: "EASY_CS_AI_LLMFIT_LOCK_TIMEOUT", default: "0", secret: false, type: "integer", min: 0, description: "Seconds to wait for a busy component lock" }
        ],
        actions: ($actions | split(" ")),
        action_options: {
          recommend: [
            { name: "target-ram", type: "integer", min: 1, description: "RAM in GB of the machine to size for, instead of this one" },
            { name: "target-vram", type: "integer", min: 1, description: "GPU memory in GB of the machine to size for, instead of this one" },
            { name: "target-cpu-cores", type: "integer", min: 1, description: "CPU cores of the machine to size for, instead of this one" }
          ],
          check: [
            { name: "target-ram", type: "integer", min: 1, description: "RAM in GB of the machine to size for, instead of this one" },
            { name: "target-vram", type: "integer", min: 1, description: "GPU memory in GB of the machine to size for, instead of this one" },
            { name: "target-cpu-cores", type: "integer", min: 1, description: "CPU cores of the machine to size for, instead of this one" }
          ]
        }
      }'
}

# --- Helpers --------------------------------------------------------------------

run_logged() {
    local action="$1" start=$SECONDS rc=0
    shift
    log_event "$NAME $action start version=$VERSION"
    ("$@") || rc=$?
    log_event "$NAME $action end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}

# llmfit_bin: the installed binary, else the one on the PATH (test mode, or a
# machine where llmfit was installed some other way).
llmfit_bin() {
    local installed
    installed="$(root_path "$BINARY")"
    if [[ -x "$installed" ]]; then
        printf '%s\n' "$installed"
    elif command -v llmfit >/dev/null 2>&1; then
        command -v llmfit
    else
        return 1
    fi
}

# verify_llmfit: the binary runs and its own recommendation is valid JSON.
verify_llmfit() {
    local bin out
    bin="$(llmfit_bin)" || return 1
    "$bin" --version >/dev/null 2>&1 || return 1
    out="$(timeout "$HEALTH" "$bin" recommend --json --no-dashboard 2>/dev/null)" || return 1
    jq -e '.models | type == "array"' >/dev/null 2>&1 <<<"$out"
}

check_free() {
    local free
    free="$(df -Pm "$1" | awk 'NR==2 {print $4}')"
    if ((free < $2)); then
        die "$EXIT_PRECONDITION" "not enough disk space on $1: ${free} MB free, $2 MB needed"
    fi
}

# --- install ----------------------------------------------------------------------

expected_sha256() {
    local arch="$1" archive="$2" sum
    if [[ "$VERSION" == "$DEFAULT_VERSION" ]]; then
        printf '%s\n' "${PINNED_SHA256[$arch]}"
        return 0
    fi
    sum="$(curl -fsSL "https://github.com/AlexsJones/llmfit/releases/download/v$VERSION/$archive.sha256")" ||
        die "$EXIT_NETWORK" "could not fetch the checksum of llmfit $VERSION"
    awk 'NR == 1 {print $1}' <<<"$sum"
}

install_binary() {
    local arch archive url expected tmp dir
    if is_test_root; then
        log_info "(test mode) would download and install llmfit $VERSION"
        return 0
    fi
    arch="$(uname -m)"
    [[ "$arch" == x86_64 || "$arch" == aarch64 ]] || die "$EXIT_UNSUPPORTED" "unsupported architecture '$arch'"
    archive="llmfit-v$VERSION-$arch-unknown-linux-gnu.tar.gz"
    url="https://github.com/AlexsJones/llmfit/releases/download/v$VERSION/$archive"
    expected="$(expected_sha256 "$arch" "$archive")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "$EXIT_NETWORK" "no valid checksum for $archive"
    apt_install curl ca-certificates
    dir="$(mktemp -d -p /var/tmp easy-cs-ai-llmfit.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$dir'" EXIT
    tmp="$dir/$archive"
    log_info "downloading $url"
    curl -fL --retry 3 --retry-delay 5 -sS -o "$tmp" "$url" || die "$EXIT_NETWORK" "download failed: $url"
    [[ "$(sha256sum "$tmp" | awk '{print $1}')" == "$expected" ]] || die "$EXIT_NETWORK" "checksum mismatch for $archive"
    tar -xzf "$tmp" -C "$dir" --strip-components=1 || die "$EXIT_ERROR" "cannot unpack $archive"
    [[ -f "$dir/llmfit" ]] || die "$EXIT_ERROR" "$archive does not contain the llmfit binary"
    track_file "$BINARY"
    install -m 0755 -o root -g root "$dir/llmfit" "$BINARY"
    rm -rf "$dir"
    trap - EXIT
}

record_state() {
    local files json
    files="$(pending_read "$NAME" | jq -c '.files + ["'"$BINARY"'"] | unique')"
    json="$(jq -n --arg v "$VERSION" --arg sv "$SCRIPT_VERSION" --argjson files "$files" \
        --argjson default "$MAKE_DEFAULT" '{
        name: "llmfit", type: "provisioning", version: $v, script_version: $sv,
        params: {}, requires: [], files: $files, data_dirs: [], secrets: []
      } + (if $default == 1 then { default: true } else {} end)')"
    state_write "$NAME" "$json"
}

do_install() {
    local changed=0
    pending_begin "$TYPE" "$NAME"
    if [[ "$(state_read "$NAME" 2>/dev/null | jq -r '.version // empty' || true)" != "$VERSION" ]] ||
        { ! is_test_root && [[ ! -x "$BINARY" ]]; }; then
        changed=1
        install_binary
    fi
    if is_test_root; then
        log_info "(test mode) verification skipped"
    elif ! verify_llmfit; then
        die "$EXIT_VERIFY" "llmfit does not run, or llmfit recommend --json is not valid JSON"
    fi
    ((changed)) || log_info "already installed, nothing to change"
    record_state
    ((MAKE_DEFAULT == 0)) || defaults_set "$TYPE" "$NAME"
    pending_remove "$NAME"
    log_info "llmfit $VERSION is installed"
}

cmd_install() {
    require_root
    require_platform
    _require_jq
    if is_test_root; then :; else check_free /usr/local 200; fi
    if is_dry_run; then
        log_info "dry run: would install llmfit $VERSION to $BINARY and record the state"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" install run_logged install do_install
}

# --- uninstall ----------------------------------------------------------------------

remove_path() {
    local path="$1"
    if [[ "$path" != /?* || "$path" == *..* ]]; then
        log_warn "ignoring suspicious path in state: $path"
        return 0
    fi
    rm -rf "$(root_path "$path")"
}

do_uninstall() {
    local state pending other path
    state="$(state_read "$NAME" 2>/dev/null || true)"
    pending="$(pending_read "$NAME" 2>/dev/null || true)"
    if [[ -z "$state" && -z "$pending" ]]; then
        die "$EXIT_PRECONDITION" "$NAME is not installed"
    fi
    if ((!FORCE)); then
        # shellcheck disable=SC2119
        while read -r other; do
            [[ -z "$other" || "$other" == "$NAME" ]] && continue
            if state_read "$other" | jq -e --arg n "$NAME" --arg t "$TYPE" '(.requires // []) | any(. == $n or . == $t)' >/dev/null; then
                die "$EXIT_PRECONDITION" "$other requires $NAME, uninstall it first or use --force"
            fi
        done < <(state_list)
    fi
    while IFS= read -r path; do
        [[ -z "$path" ]] || remove_path "$path"
    done < <(jq -rs '[.[] | (.files // [])[]] | unique[]' <<<"$state $pending")
    remove_path "$BINARY"
    state_remove "$NAME"
    pending_remove "$NAME"
    log_info "llmfit is uninstalled"
}

cmd_uninstall() {
    require_root
    _require_jq
    if is_dry_run; then
        log_info "dry run: would remove $BINARY and the state"
        return 0
    fi
    with_component_lock "$TYPE" "$NAME" uninstall run_logged uninstall do_uninstall
}

# --- status ---------------------------------------------------------------------------

# There is no service: "running" means the command is there, "healthy" that
# llmfit recommend --json answers with valid JSON.
cmd_status() {
    _require_jq
    local json installed=false running=false healthy=false version=null rc=0
    if json="$(state_read "$NAME")"; then
        installed=true
        version="$(jq '.version' <<<"$json")"
        if llmfit_bin >/dev/null; then
            running=true
            verify_llmfit && healthy=true
        fi
        [[ "$healthy" == true ]] || rc=$EXIT_VERIFY
    else
        rc=$EXIT_PRECONDITION
    fi
    jq -n --argjson i "$installed" --argjson r "$running" --argjson h "$healthy" --argjson v "$version" \
        '{ schema_version: 1, name: "llmfit", installed: $i, running: $r, healthy: $h, version: $v }'
    return "$rc"
}

# --- recommend and check ----------------------------------------------------------------

require_installed() {
    state_read "$NAME" >/dev/null 2>&1 || die "$EXIT_PRECONDITION" "$NAME is not installed, run: easy-cs-ai install provisioning llmfit"
    llmfit_bin >/dev/null || die "$EXIT_PRECONDITION" "the llmfit binary is missing, run: easy-cs-ai install provisioning llmfit"
}

# recommend: llmfit's own JSON, untouched.
cmd_recommend() {
    local bin
    require_installed
    bin="$(llmfit_bin)"
    "$bin" "${TARGET_ARGS[@]}" recommend --json --no-dashboard "${POSITIONAL[@]}" ||
        die "$EXIT_ERROR" "llmfit recommend failed"
}

# fit_entry <model>: print the llmfit model entry for a name, or fail.
# llmfit knows models by Hugging Face name ("meta-llama/Llama-3.2-3B-Instruct"),
# found by `llmfit info`, which also takes partial names. Ollama tags
# ("llama3.2:3b") are known only through the `ollama_name` field of `llmfit fit`,
# which lists the models that fit this machine.
fit_entry() {
    local bin="$1" model="$2" out entry
    if out="$("$bin" "${TARGET_ARGS[@]}" info "$model" --json --no-dashboard 2>/dev/null)" && entry="$(jq -ce '.models[0] // empty' <<<"$out")" && [[ -n "$entry" ]]; then
        printf '%s\n' "$entry"
        return 0
    fi
    if out="$("$bin" "${TARGET_ARGS[@]}" fit --json -n 100000 --no-dashboard 2>/dev/null)" &&
        entry="$(jq -ce --arg m "$model" '[.models[] | select(.ollama_name == $m)] | max_by(.score) // empty' <<<"$out")" &&
        [[ -n "$entry" ]]; then
        printf '%s\n' "$entry"
        return 0
    fi
    return 1
}

cmd_check() {
    local model="${POSITIONAL[0]:-}" bin entry
    [[ -n "$model" ]] || die "$EXIT_USAGE" "check needs a model name"
    require_installed
    bin="$(llmfit_bin)"
    if ! entry="$(fit_entry "$bin" "$model")"; then
        die "$EXIT_ERROR" "llmfit does not know '$model'. It knows Hugging Face names and the Ollama tags of the models that fit this machine; use --force to skip the check"
    fi
    # Too Tight is the only level that does not fit; Perfect, Good and Marginal do.
    jq '{
        fits: ((.fit_level // "") != "Too Tight" and (.fit_level // "") != ""),
        reason: "\(.name): fit \(.fit_level), \(.run_mode // "?") mode, needs \(.memory_required_gb // "?") GB of \(.memory_available_gb // "?") GB available"
      }' <<<"$entry"
}

# --- main -------------------------------------------------------------------------------

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
    resolve_options
    case "$ACTION" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    recommend) cmd_recommend ;;
    check) cmd_check ;;
    esac
}

main "$@"
