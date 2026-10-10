#!/usr/bin/env bash
# Question engine of the VM script generator: an interactive session that ends
# with a configuration (docs/spec-config.md). Sourced by generate.sh. Prompts
# and the summary go to stderr, answers come from stdin. Nothing is chosen
# silently: a component is in the result only if it was picked or a proposed
# dependency was accepted.

declare -A SEL=()    # type -> selected component name
declare -A OPTV=()   # component -> JSON object of the options given
declare -A DESC=()   # component -> describe JSON
SESSION_MODELS=()

# _read <prompt> [<default>]: answer in REPLY. End of input cancels the session.
_read() {
    local prompt="$1" default="${2:-}"
    printf '%s%s: ' "$prompt" "${default:+ [$default]}" >&2
    if ! IFS= read -r REPLY; then
        printf '\n' >&2
        log_info "no more input, session cancelled, nothing written"
        exit 0
    fi
    [[ -n "$REPLY" ]] || REPLY="$default"
}

_describe_of() {
    local type="$1" name="$2"
    if [[ -z "${DESC[$name]:-}" ]]; then
        DESC[$name]="$(bash "$(script_path "$type" "$name")" describe)" || fail "$EXIT_ERROR" "describe of $name failed"
    fi
}

_type_of_selected() {
    local t
    for t in "${TYPES[@]}"; do
        [[ "${SEL[$t]:-}" == "$1" ]] && { printf '%s\n' "$t"; return 0; }
    done
    return 1
}

# --- Step 1: components ---------------------------------------------------------------

step_components() {
    local t names rank
    for t in "${TYPES[@]}"; do
        names="$(component_names "$t" | tr '\n' ' ')"
        [[ -n "${names// /}" ]] || continue
        rank="$(rank_lookup "$t")"
        [[ " $names " == *" $rank "* ]] || rank=""
        while :; do
            _read "$t (${names% }, or none)" "${SEL[$t]:-${rank:-none}}"
            if [[ "$REPLY" == none ]]; then
                unset "SEL[$t]"
                break
            elif [[ " $names " == *" $REPLY "* ]]; then
                SEL[$t]="$REPLY"
                break
            fi
            log_warn "'$REPLY' is not one of: $names"
        done
    done
    return 0
}

# --- Step 2: dependencies -------------------------------------------------------------

# step_dependencies: propose what is required and missing. Returns 1 when the
# administrator refuses a dependency (the selection cannot be satisfied).
step_dependencies() {
    local changed=1 t name req satisfied cand rt
    while ((changed)); do
        changed=0
        for t in "${TYPES[@]}"; do
            name="${SEL[$t]:-}"
            [[ -n "$name" ]] || continue
            _describe_of "$t" "$name"
            while IFS= read -r req <&3; do
                [[ -n "$req" ]] || continue
                satisfied=0
                for rt in "${TYPES[@]}"; do
                    if [[ "${SEL[$rt]:-}" == "$req" || ( "$rt" == "$req" && -n "${SEL[$rt]:-}" ) ]]; then satisfied=1; fi
                done
                ((satisfied)) && continue
                if is_type "$req"; then
                    rt="$req"
                    cand="$(rank_lookup "$req")"
                    [[ -n "$cand" && -f "$(script_path "$rt" "$cand")" ]] || cand="$(component_names "$rt" | head -1)"
                else
                    rt="$(type_of "$req")" || rt=""
                    cand="$req"
                fi
                if [[ -z "$rt" || -z "$cand" || ! -f "$(script_path "$rt" "$cand")" ]]; then
                    fail "$EXIT_PRECONDITION" "$name requires $req and no shipped component provides it"
                fi
                _read "$name requires $req: add $rt $cand? (y/n)" y
                if [[ "$REPLY" != y && "$REPLY" != Y ]]; then
                    log_warn "$name cannot work without $req, choose again"
                    return 1
                fi
                SEL[$rt]="$cand"
                changed=1
            done 3< <(jq -r '.requires[]?' <<<"${DESC[$name]}")
        done
    done
    return 0
}

# --- Step 3: options ------------------------------------------------------------------

step_options() {
    local t name oname default descr secret
    for t in "${TYPES[@]}"; do
        name="${SEL[$t]:-}"
        [[ -n "$name" ]] || continue
        _describe_of "$t" "$name"
        OPTV[$name]='{}'
        # Fields are joined with the unit separator: a tab would swallow empty defaults.
        while IFS=$'\x1f' read -r oname default secret descr <&3; do
            [[ -n "$oname" ]] || continue
            if [[ "$secret" == true ]]; then
                log_info "$name: $oname is a secret, it is generated at run time and never written"
                continue
            fi
            printf '  %s\n' "$descr" >&2
            _read "$name --$oname" "$default"
            if [[ "$REPLY" != "$default" && -n "$REPLY" ]]; then
                OPTV[$name]="$(jq -c --arg k "$oname" --arg v "$REPLY" '. + {($k): $v}' <<<"${OPTV[$name]}")"
            fi
        done 3< <(jq -r '.options[]? | [.name, (.default // ""), (.secret // false | tostring), (.description // "")] | join("")' <<<"${DESC[$name]}")
    done
}

# --- Step 4: models -------------------------------------------------------------------

step_models() {
    local m
    SESSION_MODELS=()
    [[ -n "${SEL[engine]:-}" ]] || return 0
    _read "Models to add on ${SEL[engine]} (comma separated, empty for none)" ""
    local IFS=','
    for m in $REPLY; do
        m="${m#"${m%%[![:space:]]*}"}"
        m="${m%"${m##*[![:space:]]}"}"
        [[ -z "$m" ]] || SESSION_MODELS+=("$m")
    done
}

# --- Configuration and summary --------------------------------------------------------

# session_config: print the configuration JSON of the current selection.
session_config() {
    local t name comps='[]' models='[]' m opts
    for t in "${TYPES[@]}"; do
        name="${SEL[$t]:-}"
        [[ -n "$name" ]] || continue
        opts="${OPTV[$name]:-}"
        [[ -n "$opts" ]] || opts='{}'
        comps="$(jq -c --arg t "$t" --arg n "$name" --argjson o "$opts" \
            '. + [{type: $t, name: $n} + (if ($o | length) > 0 then {options: $o} else {} end)]' <<<"$comps")"
    done
    for m in "${SESSION_MODELS[@]}"; do
        models="$(jq -c --arg m "$m" '. + [{name: $m}]' <<<"$models")"
    done
    jq -n --argjson c "$comps" --argjson m "$models" \
        '{schema_version: 1, components: $c} + (if ($m | length) > 0 then {models: $m} else {} end)'
}

# summary_warnings <config> <describe-map>: the warnings of the options whose effective
# value (the one given, else the default) equals the `when` of their `warn` entry in
# `describe`, one line each, so a risk that comes with a default (LibreChat's open
# registration) is read before the VM exists. The wording comes from the script.
summary_warnings() {
    jq -r --argjson cfg "$1" '
      to_entries[] | .key as $k | .value as $d | ($k | split("/")) as [$t, $n]
      | ($cfg.components[] | select(.type == $t and .name == $n) | (.options // {})) as $o
      | $d.options[]? | select(.warn != null) | . as $opt
      | (if ($o | has($opt.name)) then $o[$opt.name] else $opt.default end | tostring) as $v
      | select($v == $opt.warn.when)
      | "    \($n) --\($opt.name)=\($v): \($opt.warn.message)"' <<<"$2"
}

# print_summary <config>: components in install order, options (secrets are
# generated, so nothing to mask), models, platforms, and the warnings of the options.
print_summary() {
    local config="$1" desc order type name warnings
    desc="$(apply_describes "$config")"
    order="$(apply_order "$config" "$desc")"
    warnings="$(summary_warnings "$config" "$desc")"
    {
        printf '\nSummary\n  components, in install order:\n'
        while read -r type name; do
            [[ -n "$name" ]] || continue
            printf '    %s %s %s\n' "$type" "$name" "$(jq -r --arg t "$type" --arg n "$name" '(.components[] | select(.type == $t and .name == $n) | .options // {}) | to_entries | map("--\(.key)=\(.value)") | join(" ")' <<<"$config")"
        done <<<"$order"
        printf '  models: %s\n' "$(jq -r '[.models[]?.name] | if length == 0 then "none" else join(", ") end' <<<"$config")"
        printf '  platforms: %s\n' "$(jq -r '[.[].platforms[]?] | unique | join(", ")' <<<"$desc")"
        if [[ -n "$warnings" ]]; then
            printf '  [WARN] to read before creating the VM:\n%s\n' "$warnings"
        fi
    } >&2
}

# run_session: the five steps. Leaves the configuration in SESSION_CONFIG.
SESSION_CONFIG=""
run_session() {
    local step=1 answer
    while :; do
        case "$step" in
        1) step_components; step=2 ;;
        2) if step_dependencies; then step=3; else step=1; fi ;;
        3) step_options; step=4 ;;
        4) step_models; step=5 ;;
        5)
            SESSION_CONFIG="$(session_config)"
            print_summary "$SESSION_CONFIG"
            _read "Confirm (y), cancel (n) or redo a step: components (c), options (o), models (m)" y
            answer="$REPLY"
            case "$answer" in
            y | Y) return 0 ;;
            n | N) log_info "cancelled, nothing written"; exit 0 ;;
            c | C) step=1 ;;
            o | O) step=3 ;;
            m | M) step=4 ;;
            *) log_warn "'$answer' is not a valid answer" ;;
            esac
            ;;
        esac
    done
}
