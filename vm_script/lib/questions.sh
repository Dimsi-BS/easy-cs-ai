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
        if [[ "$t" == provisioning ]]; then
            printf '  llmfit checks on the VM that each model fits; with none, the models are added unchecked\n' >&2
        fi
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

# llmfit is optional here (docs/spec-model-fit.md#llmfit-is-optional): it only helps to
# choose the models, and the generator never installs it.
SUGGESTIONS=()         # the models llmfit suggested, numbered in the list
SESSION_FIT_WARN=()    # "<model>: <reason>", shown in the summary
TARGET_RAM="" TARGET_VRAM="" TARGET_CORES=""    # the specs of the VM, kept to be offered again
LLMFIT_NOTICE_GIVEN=0
MODELS_ORDER=h         # h: the models that fit the hardware, m: the hardware the models need
SESSION_PLAN=""        # the text of `llmfit plan` for the models named in the m order, shown as it is

# _llmfit_ready: the llmfit script is shipped and installed, working, on this machine.
_llmfit_ready() {
    local script
    script="$(script_path provisioning llmfit)"
    [[ -f "$script" ]] || return 1
    bash "$script" status 2>/dev/null | jq -e '.installed == true and .healthy == true' >/dev/null 2>&1
}

# _offer_llmfit: llmfit is not usable here. Once per session, offer to install it now (the
# administrator's answer is the consent, the default is no), so the session goes on with it.
# A refusal or a failure is not one: the models are typed.
_offer_llmfit() {
    local script
    ((! LLMFIT_NOTICE_GIVEN)) || return 0
    LLMFIT_NOTICE_GIVEN=1
    script="$(script_path provisioning llmfit)"
    if [[ ! -f "$script" ]]; then
        log_info "this package ships no llmfit: no model suggestion, no fit check"
        return 0
    fi
    _read "llmfit is not installed here: install it now, to get model suggestions and a fit check? (y/n)" n
    if [[ "$REPLY" != y && "$REPLY" != Y ]]; then
        log_info "no model suggestion, no fit check (install llmfit later with: sudo easy-cs-ai install provisioning llmfit)"
        return 0
    fi
    # The generator plans for another machine (ASSUME_EMPTY); the install is for this one.
    if is_test_root || [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        env -u EASY_CS_AI_ASSUME_EMPTY bash "$script" install >&2
    elif command -v sudo >/dev/null 2>&1; then
        sudo env -u EASY_CS_AI_ASSUME_EMPTY bash "$script" install >&2
    else
        log_warn "installing llmfit needs root and sudo is not available: run it as root (easy-cs-ai install provisioning llmfit)"
        return 0
    fi || log_warn "llmfit could not be installed, type the model names"
}

# _read_spec <prompt> <variable>: a positive whole number or empty, asked again otherwise.
# `none` clears an answer kept from a previous pass.
_read_spec() {
    local prompt="$1" var="$2"
    while :; do
        _read "$prompt" "${!var}"
        [[ "$REPLY" != none ]] || REPLY=""
        if [[ -z "$REPLY" || "$REPLY" =~ ^[1-9][0-9]*$ ]]; then
            printf -v "$var" '%s' "$REPLY"
            return 0
        fi
        log_warn "'$REPLY' is not a positive whole number"
    done
}

# _target_args: the --target-* options of the specs given, one per line.
_target_args() {
    [[ -z "$TARGET_RAM" ]] || printf '%s\n' --target-ram "$TARGET_RAM"
    [[ -z "$TARGET_VRAM" ]] || printf '%s\n' --target-vram "$TARGET_VRAM"
    [[ -z "$TARGET_CORES" ]] || printf '%s\n' --target-cpu-cores "$TARGET_CORES"
}

# _suggest_models <script>: show, on stderr, the numbered list that `provisioning llmfit suggest`
# prints for the VM, and keep its names in SUGGESTIONS. The selection (Ollama tags, nothing Too
# Tight, best score first) and the numbering are the action's. Only the Ollama tags can be added today.
_suggest_models() {
    local script="$1" args=() out line name
    SUGGESTIONS=()
    while IFS= read -r line; do args+=("$line"); done < <(_target_args)
    [[ "${SEL[engine]}" == ollama ]] || { log_info "model suggestions are only available for ollama"; return 0; }
    printf '  asking llmfit for the models that fit the VM, a few seconds...
' >&2
    out="$(bash "$script" suggest "${args[@]}" 2>/dev/null)" || { log_warn "llmfit could not make suggestions, type the model names"; return 0; }
    # The action's own text is shown as it is; the only thing read from it is the number and the
    # name at the start of each line, so that a number can be picked.
    printf '%s\n' "$out" >&2
    while read -r name; do
        [[ -n "$name" ]] && SUGGESTIONS+=("$name")
    done < <(sed -nE 's/^ *[0-9]+\) ([^ ]+).*/\1/p' <<<"$out")
}

# _check_model <script> <model>: keep a negative verdict, or an unknown model, as a warning.
_check_model() {
    local script="$1" model="$2" args=() line out
    while IFS= read -r line; do args+=("$line"); done < <(_target_args)
    printf '  checking %s with llmfit, a few seconds...
' "$model" >&2
    if ! out="$(bash "$script" check "$model" "${args[@]}" 2>/dev/null)"; then
        SESSION_FIT_WARN+=("$model: not known to llmfit, the fit is not checked")
    elif [[ "$(jq -r '.fits' <<<"$out")" != true ]]; then
        SESSION_FIT_WARN+=("$model: $(jq -r '.reason' <<<"$out")")
    fi
}

# _read_order: hardware first or models first, offered again as the default when redone.
_read_order() {
    printf '  work from the hardware (h): give the specs of the VM and get the models that fit them,\n' >&2
    printf '  or from the models (m): name the models and get the VM they need\n' >&2
    while :; do
        _read "Order, hardware first (h) or models first (m)" "$MODELS_ORDER"
        case "$REPLY" in
        h | H) MODELS_ORDER=h; return 0 ;;
        m | M) MODELS_ORDER=m; return 0 ;;
        esac
        log_warn "'$REPLY' is not h or m"
    done
}

# _plan_models <script>: what the VM needs for the models of the session, from
# `provisioning llmfit plan` (sizes and estimated margin are the action's, the generator
# only prints them). The action announces each model on stderr, which llmfit's slowness needs.
_plan_models() {
    local script="$1" args=()
    SESSION_PLAN=""
    ((${#SESSION_MODELS[@]})) || return 0
    args=("${SESSION_MODELS[@]}")
    [[ -z "${SEL[chat-interface]:-}" ]] || args+=(--chat-interface)
    [[ -z "$TARGET_CORES" ]] || args+=(--target-cpu-cores "$TARGET_CORES")
    SESSION_PLAN="$(bash "$script" plan "${args[@]}")" || {
        log_warn "llmfit could not size the models, no VM recommendation"
        SESSION_PLAN=""
    }
}

# _print_vm_recommendation: the characteristics to ask for when creating the VM, on stderr
# (docs/spec-model-fit.md#recommended-vm): the text of the plan action, kept in SESSION_PLAN
# and shown as it is. The action shows the margin as estimated, with what it is made of.
_print_vm_recommendation() {
    [[ -n "$SESSION_PLAN" ]] || return 0
    printf '%s\n' "$SESSION_PLAN" >&2
}

step_models() {
    local m s script="" suggested=0 prompt picked
    SESSION_MODELS=()
    SESSION_FIT_WARN=()
    SESSION_PLAN=""
    SUGGESTIONS=()
    [[ -n "${SEL[engine]:-}" ]] || return 0
    # Looking for llmfit and asking its status can take a moment before anything is asked.
    [[ ! -f "$(script_path provisioning llmfit)" ]] || printf '  checking whether llmfit is available on this machine, a few seconds...
' >&2
    _llmfit_ready || _offer_llmfit
    if _llmfit_ready; then
        script="$(script_path provisioning llmfit)"
        _read_order
        if [[ "$MODELS_ORDER" == h ]]; then
            printf '  llmfit sizes the models for the VM; each answer is optional\n' >&2
            _read_spec "RAM of the VM in GB" TARGET_RAM
            _read_spec "GPU memory of the VM in GB (empty for a CPU-only VM)" TARGET_VRAM
            _read_spec "CPU cores of the VM" TARGET_CORES
            if [[ -n "$TARGET_RAM$TARGET_VRAM$TARGET_CORES" ]]; then
                suggested=1
                _suggest_models "$script"
            else
                # Without a spec llmfit would size for this machine, not for the VM.
                log_info "no spec given, no suggestion and no fit check"
            fi
        fi
    fi
    prompt="Models to add on ${SEL[engine]} (comma separated, empty for none)"
    ((${#SUGGESTIONS[@]})) && prompt="Models to add on ${SEL[engine]} (names or numbers of the list, comma separated, empty for none)"
    _read "$prompt" ""
    local IFS=','
    for m in $REPLY; do
        m="${m#"${m%%[![:space:]]*}"}"
        m="${m%"${m##*[![:space:]]}"}"
        [[ -n "$m" ]] || continue
        picked=0
        if [[ "$m" =~ ^[1-9][0-9]*$ ]] && ((m <= ${#SUGGESTIONS[@]})); then
            m="${SUGGESTIONS[m - 1]}"
            picked=1
        else
            for s in "${SUGGESTIONS[@]}"; do [[ "$s" == "$m" ]] && picked=1; done
        fi
        SESSION_MODELS+=("$m")
        # The ones of the list were sized by llmfit already.
        if ((suggested && ! picked)); then _check_model "$script" "$m"; fi
    done
    IFS=$' \t\n'
    if [[ -n "$script" && "$MODELS_ORDER" == m ]]; then
        # The recommendation is printed once, in the summary that follows.
        _plan_models "$script"
    fi
}

# --- Configuration and summary --------------------------------------------------------

# session_config: print the configuration JSON of the current selection.
session_config() {
    local t name comps='[]' models='[]' m opts force=false
    # No llmfit in the stack: nothing on the VM can check the fit, and `add` would stop on the
    # missing requirement, so the models are added unchecked (the summary says so).
    [[ -n "${SEL[provisioning]:-}" ]] || force=true
    for t in "${TYPES[@]}"; do
        name="${SEL[$t]:-}"
        [[ -n "$name" ]] || continue
        opts="${OPTV[$name]:-}"
        [[ -n "$opts" ]] || opts='{}'
        comps="$(jq -c --arg t "$t" --arg n "$name" --argjson o "$opts" \
            '. + [{type: $t, name: $n} + (if ($o | length) > 0 then {options: $o} else {} end)]' <<<"$comps")"
    done
    for m in "${SESSION_MODELS[@]}"; do
        models="$(jq -c --arg m "$m" --argjson f "$force" '. + [{name: $m} + (if $f then {force: true} else {} end)]' <<<"$models")"
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
    local config="$1" desc order type name warnings fit
    desc="$(apply_describes "$config")"
    order="$(apply_order "$config" "$desc")"
    warnings="$(summary_warnings "$config" "$desc")"
    # Derived from the configuration, so a --config file gets it too.
    fit="$(jq -r 'if ((.models // []) | any(.force == true)) and ((.components // []) | all(.type != "provisioning"))
        then "    models not checked for fit on the VM: llmfit is not part of the stack" else empty end' <<<"$config")"
    [[ -z "$fit" ]] || warnings="${warnings:+$warnings$'\n'}$fit"
    for fit in "${SESSION_FIT_WARN[@]}"; do
        warnings="${warnings:+$warnings$'\n'}    may not fit the VM, $fit"
    done
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
    _print_vm_recommendation
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
