#!/usr/bin/env bash
# Helpers shared by the CLI (package/bin/easy-cs-ai) and the VM script
# generator (vm_script/generate.sh). Sourced after common.sh; HOME_DIR is the
# root of the scripts tree.

# Types in install order; uninstall --all goes the other way round.
readonly TYPES=(provisioning proxy engine chat-interface)

# fail <code> <message> [<hint>]: "[ERROR] what (exit n: meaning)" then the hint.
fail() {
    local code="$1" message="$2" hint="${3:-}" meaning
    case "$code" in
    1) meaning="error" ;; 2) meaning="usage" ;; 3) meaning="unsupported platform" ;;
    4) meaning="precondition not met" ;; 5) meaning="network" ;; 6) meaning="verification failed" ;;
    *) meaning="failed" ;;
    esac
    log_error "$message (exit $code: $meaning)"
    [[ -z "$hint" ]] || log_info "$hint"
    exit "$code"
}

is_type() {
    local t
    for t in "${TYPES[@]}"; do
        [[ "$t" == "$1" ]] && return 0
    done
    return 1
}

script_path() { printf '%s/%s/%s.sh\n' "$HOME_DIR" "$1" "$2"; }

component_names() {
    local f
    for f in "$HOME_DIR/$1"/*.sh; do
        [[ -e "$f" ]] && basename "$f" .sh
    done
    return 0
}

# rank_lookup <type>: the rank 1 component of a type, empty when none.
rank_lookup() { awk -v t="$1" '$1 == t { print $2; exit }' "$HOME_DIR/ranks.conf" 2>/dev/null || true; }

# rank_one <type>: same, but a usage error when none.
rank_one() {
    local name
    name="$(rank_lookup "$1")"
    [[ -n "$name" ]] || fail "$EXIT_USAGE" "no default component known for type $1"
    printf '%s\n' "$name"
}

# type_of <name>: the type of an installed or shipped component.
type_of() {
    local t json
    if json="$(state_read "$1" 2>/dev/null)"; then
        jq -r '.type' <<<"$json"
        return 0
    fi
    for t in "${TYPES[@]}"; do
        if [[ -e "$(script_path "$t" "$1")" ]]; then
            printf '%s\n' "$t"
            return 0
        fi
    done
    return 1
}

# is_installed <name-or-type>: EASY_CS_AI_ASSUME_EMPTY (the generator, which
# plans for another machine) makes everything not installed.
is_installed() {
    [[ -z "${EASY_CS_AI_ASSUME_EMPTY:-}" ]] || return 1
    state_read "$1" >/dev/null 2>&1 && return 0
    is_type "$1" && [[ -n "$(state_list "$1")" ]]
}

