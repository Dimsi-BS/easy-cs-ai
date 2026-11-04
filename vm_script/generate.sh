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
CONFIG_FILE="" CONFIG_ONLY=0 OUTPUT="" EDIT_FILE=""
REPORT_DOC="" SCRIPT_BYTES=0
PACKAGE_URL="" PACKAGE_VERSION="" PACKAGE_FORMAT=deb PACKAGE_SHA256="" PACKAGE_FILE="" PACKAGE_EXT=deb

usage() {
    cat <<'EOF'
Usage: generate [options]

Writes the VM post-install script (default ./easy-cs-ai-vm.sh), after an
interactive session or from a configuration file. When the stack is split on
two VMs (the first question of the session, or components that carry a vm),
it writes one script per VM, the VM inserted before the extension of the name
(easy-cs-ai-vm-engine.sh, easy-cs-ai-vm-web.sh), then prints what is left to do
once the VMs are up.

  --config <file>          configuration to turn into a script, no prompt at all
  --config-only            write only the configuration (default ./easy-cs-ai.json)
  --edit <file>            open an existing configuration in the session; saving regenerates
                           its scripts (not with --config nor --config-only)
  --output <path>          where to write the result (for several VMs: the name the VM is inserted in)
  --package-url <url>      where the VM downloads the package (a mirror, for instance)
  --package-version <v>    pinned version (default: the version of the installed CLI)
  --package-format <f>     deb (default), rpm or tarball
  --package-sha256 <hex>   checksum the script verifies
  --package-file <path>    compute the checksum from a local copy of the package
  --dry-run                run everything, print the result on stderr, write nothing
  --json                   with --config: print one JSON document on stdout (validation,
                           warnings, plan, script written, or scripts and next steps for
                           several VMs) instead of the human output
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
        --config | --edit | --output | --package-url | --package-version | --package-format | --package-sha256 | --package-file)
            [[ $# -gt 0 ]] || die "$EXIT_USAGE" "$arg needs a value"
            case "$arg" in
            --config) CONFIG_FILE="$1" ;;
            --edit) EDIT_FILE="$1" ;;
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
    if [[ -n "$EDIT_FILE" ]] && { [[ -n "$CONFIG_FILE" ]] || ((CONFIG_ONLY)); }; then
        die "$EXIT_USAGE" "--edit cannot be combined with --config nor --config-only"
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

# header <config> [<vm> <rank> <total>]: comment block recording what the script was built from.
# For a configuration that names VMs, one more line says which VM the script is for.
header() {
    local config="$1" vm="${2:-}" desc order type name version
    desc="$(apply_describes "$config")"
    order="$(apply_order "$config" "$desc")"
    printf '# easy-cs-ai VM post-install script, generated by easy-cs-ai generate %s on %s\n' "$GENERATOR_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -z "$vm" ]] || printf '# VM: %s (%s of %s)\n' "$vm" "$3" "$4"
    printf '# package: easy-cs-ai %s (%s)\n' "$PACKAGE_VERSION" "$PACKAGE_FORMAT"
    while read -r type name; do
        [[ -n "$name" ]] || continue
        version="$(jq -r --arg k "$type/$name" '.[$k].component_version // "?"' <<<"$desc")"
        printf '# component: %s %s %s %s\n' "$type" "$name" "$version" \
            "$(jq -r --arg t "$type" --arg n "$name" '(.components[] | select(.type == $t and .name == $n) | .options // {}) | to_entries | map("--\(.key)=\(.value)") | join(" ")' <<<"$config")"
    done <<<"$order"
}

# build_script <config> [<vm> <rank> <total>]: the script on stdout, for the configuration of one VM.
build_script() {
    local config="$1" delimiter=EASY_CS_AI_CONFIG tpl
    shopt -u patsub_replacement 2>/dev/null || true
    while grep -qxF "$delimiter" <<<"$config"; do
        delimiter+="_X"
    done
    tpl="$(cat "$HERE/templates/vm-script.sh.tpl")"
    tpl="${tpl//@@HEADER@@/$(header "$@")}"
    tpl="${tpl//@@URL@@/$(sq "$PACKAGE_URL")}"
    tpl="${tpl//@@VERSION@@/$(sq "$PACKAGE_VERSION")}"
    tpl="${tpl//@@SHA256@@/$(sq "$PACKAGE_SHA256")}"
    tpl="${tpl//@@FORMAT@@/$(sq "$PACKAGE_EXT")}"
    tpl="${tpl//@@DELIMITER@@/$delimiter}"
    tpl="${tpl//@@CONFIG@@/$config}"
    printf '%s' "$tpl"
}

# size_check <bytes>: the warning about the user-data limit.
size_check() {
    if (($1 > SCRIPT_SIZE_LIMIT)); then
        log_warn "the script is larger than $SCRIPT_SIZE_LIMIT bytes, check the user-data limit of the target cloud"
    fi
}

# emit_script <config> <path>: the script of a configuration that names no VM.
emit_script() {
    local config="$1" out="$2" tpl size
    tpl="$(build_script "$config")"
    write_output "$out" "$tpl" 0755
    size="$(printf '%s\n' "$tpl" | wc -c)"
    SCRIPT_BYTES="$size"
    ((DRY)) || log_info "script written to $out ($size bytes)"
    size_check "$size"
}

# vm_path <base> <vm>: the name of the script of a VM, the VM inserted before the extension of <base>
# (vm.sh gives vm-engine.sh, a name with no extension gets -engine at its end).
vm_path() {
    local base="$1" vm="$2" dir file
    dir="$(dirname "$base")"
    file="$(basename "$base")"
    if [[ "$file" == *.* && "${file%.*}" != "" ]]; then
        file="${file%.*}-$vm.${file##*.}"
    else
        file="$file-$vm"
    fi
    [[ "$base" == */* ]] && printf '%s/%s\n' "$dir" "$file" || printf '%s\n' "$file"
}

# emit_vm_scripts <config>: one script per VM of a configuration that names VMs, each with the
# slice of its VM. They are written together: when one cannot be written none is kept. The result
# is in SCRIPTS_JSON (one entry per script) and SCRIPT_PATHS.
SCRIPTS_JSON='[]'
SCRIPT_PATHS=()
emit_vm_scripts() {
    local config="$1" base="${OUTPUT:-./easy-cs-ai-vm.sh}" vm i=0 total out slice content size tmp k
    local -a names=() tmps=() outs=() sizes=() moved=()
    mapfile -t names < <(apply_vms "$config")
    total=${#names[@]}
    SCRIPTS_JSON='[]'
    SCRIPT_PATHS=()
    for vm in "${names[@]}"; do
        i=$((i + 1))
        slice="$(apply_slice "$config" "$vm" | jq .)"
        out="$(vm_path "$base" "$vm")"
        content="$(build_script "$slice" "$vm" "$i" "$total")"
        size="$(printf '%s\n' "$content" | wc -c)"
        if ((DRY)); then
            log_info "dry run, would write $out:"
            printf '%s\n' "$content" >&2
        else
            if ! tmp="$(mktemp "$(dirname "$out")/.generate.XXXXXX" 2>/dev/null)"; then
                ((${#tmps[@]} == 0)) || rm -f "${tmps[@]}"
                die "$EXIT_ERROR" "cannot write in $(dirname "$out"): no script was written"
            fi
            tmps+=("$tmp")
            printf '%s\n' "$content" >"$tmp"
            chmod 0755 "$tmp"
        fi
        outs+=("$out")
        sizes+=("$size")
        SCRIPT_PATHS+=("$out")
        SCRIPTS_JSON="$(jq -c --arg v "$vm" --arg p "$out" --argjson b "$size" --argjson w "$((DRY ? 0 : 1))" --arg pv "$PACKAGE_VERSION" --arg pf "$PACKAGE_FORMAT" \
            '. + [{vm: $v, path: $p, bytes: $b, written: ($w == 1), package_version: $pv, package_format: $pf}]' <<<"$SCRIPTS_JSON")"
    done
    if ((!DRY)); then
        for k in "${!tmps[@]}"; do
            if ! mv -f "${tmps[$k]}" "${outs[$k]}"; then
                ((${#moved[@]} == 0)) || rm -f "${moved[@]}"
                rm -f "${tmps[@]}"
                die "$EXIT_ERROR" "cannot write ${outs[$k]}: no script was kept"
            fi
            moved+=("${outs[$k]}")
        done
        for k in "${!outs[@]}"; do log_info "script written to ${outs[$k]} (${sizes[$k]} bytes)"; done
    fi
    for k in "${!sizes[@]}"; do size_check "${sizes[$k]}"; done
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

# print_vm_scripts_report <config>: after the scripts of several VMs, what was written and what is
# left to do, from the next steps the validation computes (the generator computes nothing of them).
print_vm_scripts_report() {
    local config="$1" desc cross names total i=0 vm words
    desc="$(apply_describes "$config")"
    cross="$(config_cross "$config" "$desc")"
    mapfile -t names < <(apply_vms "$config")
    total=${#names[@]}
    case "$total" in 1) words="One script" ;; 2) words="Two scripts" ;; 3) words="Three scripts" ;; *) words="$total scripts" ;; esac
    {
        if ((DRY)); then printf '\n%s, nothing written (dry run), one per VM:\n' "$words"
        else printf '\n%s written, one per VM:\n' "$words"; fi
        for vm in "${names[@]}"; do
            printf '  %s   VM %s  (%s)\n' "${SCRIPT_PATHS[$i]}" "$vm" \
                "$(apply_slice "$config" "$vm" | jq -r '[.components[].name] | join(", ")')"
            i=$((i + 1))
        done
        next_steps_text "$(jq -c '.next_steps' <<<"$cross")"
    } >&2
}

# --- Main ------------------------------------------------------------------------------

# json_result <document> <script-json>: print the validation document with the script written.
# For a file that names VMs the document has `script: null` and `scripts`, one entry per VM.
json_result() {
    jq -c --argjson s "$2" --argjson ss "${3:-null}" \
        '. + (if $ss != null then {script: null, scripts: $ss} else {script: $s} end)' <<<"$1"
}

# print_vm_summaries <config>: the summary of each VM of a file that names several, then the
# warnings that need several VMs to be computed, which come after the ones of the VMs.
print_vm_summaries() {
    local config="$1" vm
    while IFS= read -r vm; do
        [[ -n "$vm" ]] || continue
        printf '\nVM %s\n' "$vm" >&2
        print_summary "$(apply_slice "$config" "$vm")"
    done < <(apply_vms "$config")
    print_cross_warnings "$config"
}

load_config() {
    local config desc doc rc vm
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
            if [[ "$(jq -r 'has("next_steps")' <<<"$doc")" == true ]]; then
                json_result "$doc" null '[]'
            else
                json_result "$doc" null
            fi
            config_report_text "$doc"
            exit "$rc"
        fi
        REPORT_DOC="$doc"
    fi
    jq -e . >/dev/null 2>&1 <<<"$config" || die "$EXIT_USAGE" "$CONFIG_FILE is not valid JSON"
    desc="$(apply_describes "$config")"
    apply_validate "$config" "$desc"
    apply_validate_models_need "$config" "$desc"
    config_validate_cross "$config" "$desc"
    SESSION_CONFIG="$(jq . <<<"$config")"
    if apply_named "$config"; then
        # each VM is validated and ordered as a one-VM file
        while IFS= read -r vm; do
            [[ -n "$vm" ]] || continue
            apply_order "$(apply_slice "$config" "$vm")" "$desc" >/dev/null
        done < <(apply_vms "$config")
        print_vm_summaries "$config"
    else
        apply_order "$config" "$desc" >/dev/null
        print_summary "$SESSION_CONFIG"
    fi
}

# --- The editor: generate --edit <file>, docs/spec-multi-vm.md#editing ----------------

EDIT_ORIGINAL=""

# _editor_known_vm <config> <vm>: that name is one of the VMs of the file.
_editor_known_vm() {
    [[ -n "$2" ]] || return 1
    apply_named "$1" || return 1
    apply_vms "$1" | grep -qxF "$2"
}

# _editor_list_stale <config>: the scripts on disk (the pattern of --output) that no VM of the
# file produces any more. The editor never deletes a file, only lists them.
_editor_list_stale() {
    local config="$1" base="${OUTPUT:-./easy-cs-ai-vm.sh}" dir file prefix ext f vm
    local -a stale=()
    apply_named "$config" || return 0
    dir="$(dirname "$base")"
    file="$(basename "$base")"
    if [[ "$file" == *.* && "${file%.*}" != "" ]]; then
        prefix="${file%.*}"
        ext=".${file##*.}"
    else
        prefix="$file"
        ext=""
    fi
    for f in "$dir/$prefix"-*"$ext"; do
        [[ -e "$f" ]] || continue
        vm="$(basename "$f")"
        vm="${vm#"$prefix"-}"
        [[ -z "$ext" ]] || vm="${vm%"$ext"}"
        apply_vms "$config" | grep -qxF "$vm" || stale+=("$f")
    done
    ((${#stale[@]})) || return 0
    log_warn "no longer produced by any VM, remove by hand if unneeded: ${stale[*]}"
}

# _editor_write <file>: `y`. Refuses when the file changed on disk since it was opened. Then
# validates again, resolves the package source and writes the configuration and every script
# together: the configuration is renamed into place only once the scripts succeeded, so a
# failure of either keeps the file exactly as it was (docs/spec-multi-vm.md#editing).
_editor_write() {
    local file="$1" disk tmp mode
    disk="$(cat "$file" 2>/dev/null || true)"
    if [[ "$disk" != "$EDIT_ORIGINAL" ]]; then
        log_warn "the file changed on disk since it was opened: nothing written, open it again"
        return 1
    fi
    resolve_package_source
    if ((DRY)); then
        log_info "dry run, would write $file:"
        printf '%s\n' "$EDIT_CONFIG" >&2
        if apply_named "$EDIT_CONFIG"; then
            emit_vm_scripts "$EDIT_CONFIG"
            print_vm_scripts_report "$EDIT_CONFIG"
        else
            emit_script "$EDIT_CONFIG" "${OUTPUT:-./easy-cs-ai-vm.sh}"
        fi
        return 0
    fi
    mode="$(stat -c %a "$file" 2>/dev/null)" || mode=644
    tmp="$(mktemp "$(dirname "$file")/.generate.XXXXXX" 2>/dev/null)" || {
        log_warn "cannot write in $(dirname "$file"): nothing written"
        return 1
    }
    jq . <<<"$EDIT_CONFIG" >"$tmp"
    chmod "$mode" "$tmp" 2>/dev/null || true
    if apply_named "$EDIT_CONFIG"; then
        emit_vm_scripts "$EDIT_CONFIG"
    else
        emit_script "$EDIT_CONFIG" "${OUTPUT:-./easy-cs-ai-vm.sh}"
    fi
    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        log_warn "cannot write $file: the scripts were written, the configuration was not; fix this and save again"
        return 1
    fi
    log_info "configuration written to $file"
    _editor_list_stale "$EDIT_CONFIG"
    apply_named "$EDIT_CONFIG" && print_vm_scripts_report "$EDIT_CONFIG"
    return 0
}

# run_editor <file>: open, show the summary, apply commands until the person writes (y), quits
# (q) or cancels (end of input); see docs/spec-multi-vm.md#editing. Saving regenerates the
# scripts: the configuration and the scripts of its VMs are written together.
run_editor() {
    local file="$1" content cmd sub arg1 v
    [[ -r "$file" ]] || die "$EXIT_USAGE" "cannot read $file"
    content="$(cat "$file")"
    jq -e . >/dev/null 2>&1 <<<"$content" || die "$EXIT_USAGE" "$file is not valid JSON"
    EDIT_ORIGINAL="$content"
    EDIT_CONFIG="$(jq -c . <<<"$content")"
    while :; do
        _editor_summary "$EDIT_CONFIG"
        _read "a add a VM   e <vm> edit   m <vm> models   l links   n <vm> rename   r <vm> remove   f fix   y write   q quit" ""
        cmd="$REPLY"
        read -r sub arg1 _ <<<"$cmd"
        case "$sub" in
        a | A) _editor_add_vm ;;
        e | E)
            if _editor_known_vm "$EDIT_CONFIG" "$arg1"; then
                _editor_edit_vm "$arg1"
            elif ! apply_named "$EDIT_CONFIG" && [[ -z "$arg1" ]]; then
                _editor_edit_vm ""
            else
                log_warn "'$arg1' is not a VM of this configuration"
            fi
            ;;
        m | M)
            if _editor_known_vm "$EDIT_CONFIG" "$arg1"; then
                _editor_redo_models "$arg1"
            else
                log_warn "'$arg1' is not a VM of this configuration"
            fi
            ;;
        l | L) _editor_redo_links ;;
        n | N)
            if ! _editor_known_vm "$EDIT_CONFIG" "$arg1"; then
                log_warn "'$arg1' is not a VM of this configuration"
            else
                VM_NAMES=()
                while IFS= read -r v; do [[ -z "$v" || "$v" == "$arg1" ]] || VM_NAMES+=("$v"); done < <(apply_vms "$EDIT_CONFIG")
                _ask_vm_name "$arg1"
                [[ "$REPLY" == "$arg1" ]] || EDIT_CONFIG="$(_editor_rename_vm "$EDIT_CONFIG" "$arg1" "$REPLY")"
            fi
            ;;
        r | R)
            if ! _editor_known_vm "$EDIT_CONFIG" "$arg1"; then
                log_warn "'$arg1' is not a VM of this configuration"
            elif (($(apply_vms "$EDIT_CONFIG" | grep -c .) <= 1)); then
                log_warn "the last VM cannot be removed"
            else
                printf 'removing VM %s: %s\n' "$arg1" \
                    "$(jq -r --arg v "$arg1" '[.components[] | select(.vm == $v) | "\(.type) \(.name)"] | join(", ")' <<<"$EDIT_CONFIG")" >&2
                _read "Remove VM $arg1? (y/n)" y
                if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
                    EDIT_CONFIG="$(_editor_remove_vm "$EDIT_CONFIG" "$arg1")"
                    _editor_maybe_flatten
                fi
            fi
            ;;
        f | F) _editor_fix ;;
        y | Y)
            if [[ "$EDIT_ERRORS" != '[]' ]]; then
                log_warn "nothing is written while an error stands: fix it (f), or edit/link/rename/remove the VM it names"
                continue
            fi
            _editor_write "$file" && return 0
            ;;
        q | Q) log_info "cancelled, nothing written"; return 0 ;;
        *) log_warn "'$cmd' is not a valid answer" ;;
        esac
    done
}

main() {
    parse_args "$@"
    _require_jq
    local out desc
    if [[ -n "$EDIT_FILE" ]]; then
        run_editor "$EDIT_FILE"
        return 0
    fi
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config
    else
        run_session
        desc="$(apply_describes "$SESSION_CONFIG")"
        apply_validate "$SESSION_CONFIG" "$desc"
        apply_validate_models_need "$SESSION_CONFIG" "$desc"
        config_validate_cross "$SESSION_CONFIG" "$desc"
    fi
    if ((CONFIG_ONLY)); then
        out="${OUTPUT:-./easy-cs-ai.json}"
        write_output "$out" "$SESSION_CONFIG" 0644
        ((DRY)) || log_info "configuration written to $out"
        return 0
    fi
    resolve_package_source
    if apply_named "$SESSION_CONFIG"; then
        emit_vm_scripts "$SESSION_CONFIG"
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
