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
PASS_TYPES=("${TYPES[@]}")   # the types the session asks in this pass (all of them, or those of one VM)
PASS_REQUIRED=""           # the type that defines the VM of this pass, which `none` cannot refuse
VM_MODE=""                 # "", or the VM of the pass when the stack is split: engine or web
PROXY_DECLINED=0           # the proxy of the engine VM was refused: back to its components

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
    for t in "${PASS_TYPES[@]}"; do
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
                if [[ "$t" == "$PASS_REQUIRED" ]]; then
                    log_warn "this VM is defined by its $t, none is not offered here: choose one of $names"
                    continue
                fi
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
    local only="${1:-}" t name oname default descr secret
    for t in "${TYPES[@]}"; do
        [[ -z "$only" || "$t" == "$only" ]] || continue
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

# _component_args: --component <type>/<name> for each component of the VM, one argument per line.
_component_args() {
    local t
    for t in "${TYPES[@]}"; do
        [[ -z "${SEL[$t]:-}" ]] || printf '%s\n' --component "$t/${SEL[$t]}"
    done
}

# _plan_stack: a VM that ends with no model is sized from its components alone, from the same
# action (docs/spec-model-fit.md#a-stack-with-no-model). llmfit itself is not needed, only its
# script: a package that ships none has no recommendation, and says so.
_plan_stack() {
    local script args=() line
    ((${#SESSION_MODELS[@]} == 0)) || return 0
    SESSION_PLAN=""
    while IFS= read -r line; do args+=("$line"); done < <(_component_args)
    ((${#args[@]})) || return 0
    script="$(script_path provisioning llmfit)"
    if [[ ! -f "$script" ]]; then
        SESSION_PLAN="  no recommendation: this package ships no sizing component"
        return 0
    fi
    [[ -z "$TARGET_CORES" ]] || args+=(--target-cpu-cores "$TARGET_CORES")
    SESSION_PLAN="$(bash "$script" plan "${args[@]}" 2>/dev/null)" || {
        log_warn "the components could not be sized, no VM recommendation"
        SESSION_PLAN=""
    }
}

# _plan_models <script>: what the VM needs for the models of the session, from
# `provisioning llmfit plan` (sizes and estimated margin are the action's, the generator
# only prints them). The action announces each model on stderr, which llmfit's slowness needs.
_plan_models() {
    local script="$1" args=() m line
    SESSION_PLAN=""
    ((${#SESSION_MODELS[@]})) || return 0
    # each model with the engine it goes to, and the components of the VM: their declared resources
    # make the margin
    for m in "${SESSION_MODELS[@]}"; do args+=("$m@${SEL[engine]}"); done
    while IFS= read -r line; do args+=("$line"); done < <(_component_args)
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

# _propose_proxy: the models named need a proxy to be reached from outside the VM when their engine
# is not protected (docs/spec-config.md#what-a-model-needs). Without one in the stack the session
# proposes the rank 1 proxy, as it proposes a missing dependency: `y` adds it and asks its options,
# `n` takes the models out of the list. A package that ships no proxy proposes nothing: the
# validation says why in the summary.
_propose_proxy() {
    local engine="${SEL[engine]:-}" proxy names prompt
    [[ -n "$engine" && -z "${SEL[proxy]:-}" ]] || return 0
    ((${#SESSION_MODELS[@]})) || [[ "$VM_MODE" == engine ]] || return 0
    _describe_of engine "$engine"
    [[ "$(jq -r '.endpoint.protected // false' <<<"${DESC[$engine]}")" != true ]] || return 0
    proxy="$(rank_lookup proxy)"
    [[ -n "$proxy" && -f "$(script_path proxy "$proxy")" ]] || proxy="$(component_names proxy | head -1)"
    [[ -n "$proxy" ]] || return 0
    if ((${#SESSION_MODELS[@]})); then
        names="$(printf '%s, ' "${SESSION_MODELS[@]}")"
        names="${names%, }"
        prompt="$names needs a proxy to be reached from outside the VM (the engine listens on the loopback only). Add $proxy? (y/n)"
    else
        prompt="Other VMs reach $engine through a proxy (it listens on the loopback only). Add $proxy? (y/n)"
    fi
    _read "$prompt" y
    if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
        SEL[proxy]="$proxy"
        step_options proxy
    elif [[ "$VM_MODE" == engine ]]; then
        log_warn "other VMs could not reach $engine without a proxy, choose the components again"
        PROXY_DECLINED=1
    else
        log_warn "without a proxy the models cannot be reached from outside the VM: none is added"
        SESSION_MODELS=()
        SESSION_FIT_WARN=()
    fi
}

step_models() {
    local m s script="" suggested=0 prompt picked default_models
    # the editor redoing the models of a VM seeds SESSION_MODELS first, to offer them back as
    # the default; a fresh pass has none yet, so this changes nothing for it.
    default_models="$(
        local IFS=,
        printf '%s' "${SESSION_MODELS[*]:-}"
    )"
    SESSION_MODELS=()
    SESSION_FIT_WARN=()
    SESSION_PLAN=""
    SUGGESTIONS=()
    [[ -n "${SEL[engine]:-}" ]] || { _plan_stack; return 0; }
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
    _read "$prompt" "$default_models"
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
    _propose_proxy
    ((! PROXY_DECLINED)) || return 0
    if [[ -n "$script" && "$MODELS_ORDER" == m ]]; then
        # The recommendation is printed once, in the summary that follows.
        _plan_models "$script"
    fi
    _plan_stack
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
# SUMMARY_ERRORS: how many problems the last summary showed (what a model needs and the file does not give,
# for instance a package that ships no proxy to propose): the session does not confirm a configuration that
# cannot finish.
SUMMARY_ERRORS=0

print_summary() {
    local config="$1" desc order type name warnings fit errors
    desc="$(apply_describes "$config")"
    order="$(apply_order "$config" "$desc")"
    warnings="$(summary_warnings "$config" "$desc")"
    # The validation gives it, so a --config file gets it too.
    fit="$(config_cross "$config" "$desc" | jq -r '.warnings[] | select(.code == "models_not_checked") | "    \(.message)"')"
    [[ -z "$fit" ]] || warnings="${warnings:+$warnings$'\n'}$fit"
    for fit in "${SESSION_FIT_WARN[@]}"; do
        warnings="${warnings:+$warnings$'\n'}    may not fit the VM, $fit"
    done
    errors="$(apply_problems "$config" "$desc" true | jq -r '.[] | select(.code == "missing_requirement" and (.path | startswith("$.models"))) | "    \(.message)"')"
    SUMMARY_ERRORS=0
    [[ -z "$errors" ]] || SUMMARY_ERRORS="$(grep -c . <<<"$errors")"
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
        if [[ -n "$errors" ]]; then
            printf '  [ERROR] to fix before this can be confirmed:\n%s\n' "$errors"
        fi
    } >&2
    _print_vm_recommendation
}

# The session is the journey walked once, or once per VM for a stack of any size
# (docs/spec-multi-vm.md#in-the-session): a pass is the five steps over the types of a VM.
# shellcheck disable=SC2034  # read by generate.sh
SESSION_CONFIG=""
PASS_CONFIG=""
PASS_DONE='[]'    # the passes already confirmed: [{vm, config}], the one-VM configuration of each
VM_NAMES=()       # the names given so far, in order
LINKS_JSON='[]'   # the links answered, see _ask_links

# _assemble_done: the configuration of every pass in PASS_DONE: every component gets the vm of its
# pass, every model the vm and the engine of the pass that holds it.
_assemble_done() {
    jq -n --argjson parts "$PASS_DONE" '
        {schema_version: 1,
         components: [$parts[] | .vm as $v | .config.components[] | . + {vm: $v}],
         models: [$parts[] | .vm as $v | (.config.components | map(select(.type == "engine"))[0].name) as $e
                  | (.config.models // [])[] | . + {vm: $v, engine: $e}]}
        | if (.models | length) == 0 then del(.models) else . end'
}

# _vm_ok <name>: the shape of spec-config.md#several-vms.
_vm_ok() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]]; }

# _vm_taken <name>: the name is already used by an earlier VM of this session.
_vm_taken() {
    local n
    for n in "${VM_NAMES[@]}"; do [[ "$n" == "$1" ]] && return 0; done
    return 1
}

# _default_vm_name <role>: the role, made unique by a number (engine, web, web-2…); for custom
# (and the first VM, named only once a second one is added), vm-1, vm-2…
_default_vm_name() {
    local role="$1" base="$1" n
    if [[ "$role" != engine && "$role" != web ]]; then
        base=vm
        n=1
        while _vm_taken "$base-$n"; do n=$((n + 1)); done
        printf '%s-%s\n' "$base" "$n"
        return 0
    fi
    if ! _vm_taken "$base"; then
        printf '%s\n' "$base"
        return 0
    fi
    n=2
    while _vm_taken "$base-$n"; do n=$((n + 1)); done
    printf '%s-%s\n' "$base" "$n"
}

# _ask_vm_name <default>: a name of the right shape, not already taken, asked again otherwise.
# Leaves the answer in REPLY and appends it to VM_NAMES.
_ask_vm_name() {
    local default="$1"
    while :; do
        _read "Name of the VM" "$default"
        if ! _vm_ok "$REPLY"; then
            log_warn "'$REPLY' is not lowercase letters, digits and dashes, starting with a letter"
        elif _vm_taken "$REPLY"; then
            log_warn "'$REPLY' is already the name of another VM"
        else
            VM_NAMES+=("$REPLY")
            return 0
        fi
    done
}

# _ask_role: engine, web or custom (default), for a new VM.
# _ask_role: leaves the answer in REPLY (never "$(...)", which would only end a subshell on end
# of input instead of the whole session).
_ask_role() {
    while :; do
        _read "Role of the new VM: engine, web or custom" custom
        case "$REPLY" in
        engine | web | custom) return 0 ;;
        esac
        log_warn "'$REPLY' is not engine, web or custom"
    done
}

# _selected_any: at least one type has a component selected (SEL is not empty).
_selected_any() {
    local t
    for t in "${TYPES[@]}"; do [[ -n "${SEL[$t]:-}" ]] && return 0; done
    return 1
}

# _choose_component <type> <names>: the component of that type to add, rank 1 preselected.
_choose_component() {
    local t="$1" names="$2" rank
    rank="$(rank_lookup "$t")"
    [[ " $names " == *" $rank "* ]] || rank="${names%% *}"
    while :; do
        _read "$t (${names% })" "$rank"
        if [[ " $names " == *" $REPLY "* ]]; then
            SEL[$t]="$REPLY"
            return 0
        fi
        log_warn "'$REPLY' is not one of: $names"
    done
}

# step_components_custom <vm>: the custom role, docs/spec-multi-vm.md#roles: every type, one at a
# time, "Add a <type> on <vm>? (y/n)", and on y the choice of the component. Nothing is required
# except that the VM ends with a component: with none the walk starts again.
step_components_custom() {
    local vm="$1" t names
    while :; do
        for t in "${TYPES[@]}"; do
            names="$(component_names "$t" | tr '\n' ' ')"
            [[ -n "${names// /}" ]] || continue
            [[ -z "${SEL[$t]:-}" ]] || continue
            _read "Add a $t on $vm? (y/n)" n
            if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
                _choose_component "$t" "$names"
            fi
        done
        _selected_any && return 0
        log_warn "this VM has no component yet, choose again"
    done
}

# run_pass <role> <vm>: the five steps over the types of a VM. <role> is "" for the plain,
# unrestricted pass (the one-VM session, and the first VM of a several-VM one, run exactly alike,
# docs/spec-multi-vm.md#creating), or engine / web / custom for the VMs that follow. <vm> is the
# name of the VM, empty for the plain pass. Leaves the one-VM configuration of the pass in
# PASS_CONFIG. Cancelling cancels everything.
run_pass() {
    local role="${1:-}" vm="${2:-}" step=1 answer menu="components (c), options (o), models (m)"
    VM_MODE="$role"
    PASS_REQUIRED=""
    PASS_TYPES=("${TYPES[@]}")
    case "$role" in
    engine) PASS_TYPES=(provisioning proxy engine); PASS_REQUIRED=engine ;;
    web)
        PASS_TYPES=(proxy chat-interface)
        PASS_REQUIRED=chat-interface
        # the web role has no models step: nothing of an engine (its specs, its models) is its own
        menu="components (c), options (o)"
        TARGET_RAM="" TARGET_VRAM="" TARGET_CORES=""
        ;;
    esac
    if [[ -n "$vm" ]]; then
        SEL=() OPTV=()
        SESSION_MODELS=() SESSION_FIT_WARN=() SESSION_PLAN="" SUGGESTIONS=()
        printf '\nVM %s\n' "$vm" >&2
    fi
    while :; do
        case "$step" in
        1)
            if [[ "$role" == custom ]]; then step_components_custom "$vm"; else step_components; fi
            step=2
            ;;
        2) if step_dependencies; then step=3; else step=1; fi ;;
        3) step_options; step=4 ;;
        4)
            PROXY_DECLINED=0
            step_models
            if ((PROXY_DECLINED)); then step=1; else step=5; fi
            ;;
        5)
            PASS_CONFIG="$(session_config)"
            print_summary "$PASS_CONFIG"
            _read "Confirm (y), cancel (n) or redo a step: $menu" y
            answer="$REPLY"
            case "$answer" in
            y | Y)
                if ((SUMMARY_ERRORS)); then
                    log_warn "this configuration cannot finish, redo a step or cancel"
                else
                    return 0
                fi
                ;;
            n | N) log_info "cancelled, nothing written"; exit 0 ;;
            c | C) step=1 ;;
            o | O) step=3 ;;
            m | M)
                if [[ "$role" == web ]]; then log_warn "'$answer' is not a valid answer"; else step=4; fi
                ;;
            *) log_warn "'$answer' is not a valid answer" ;;
            esac
            ;;
        esac
    done
}

# print_cross_warnings <config>: the problems of a stack on several VMs that need several of them to
# be computed: the errors (an engine nothing exposes, two VMs with the same server name) and the
# warning (an address not known yet), each naming its VM.
print_cross_warnings() {
    local cross errlines warnlines
    cross="$(config_cross "$1" "$(apply_describes "$1")")"
    errlines="$(jq -r '.errors[] | select(.code == "engine_unreachable" or .code == "duplicate_server_name") | "    [VM \(.vm)] \(.message)"' <<<"$cross")"
    warnlines="$(jq -r '.warnings[] | select(.code == "engine_address_unknown") | "    [VM \(.vm)] \(.message)"' <<<"$cross")"
    [[ -z "$errlines" ]] || printf '  [ERROR] between the VMs, to fix before this can be confirmed:\n%s\n' "$errlines" >&2
    [[ -z "$warnlines" ]] || printf '  [WARN] between the VMs, to read before creating them:\n%s\n' "$warnlines" >&2
}

# _vm_has_type <vm> <type>: a component of that type is on that VM, in SESSION_CONFIG.
_vm_has_type() {
    jq -e --arg v "$1" --arg t "$2" 'any((.components // [])[]; .vm == $v and .type == $t)' <<<"$SESSION_CONFIG" >/dev/null
}

# _ask_links: for every VM with a chat interface that has at least one other VM with an engine,
# "Which VMs hold the engines whose models <web_vm> lists?" (docs/spec-multi-vm.md#creating). Each
# answer is validated against the real rules (an unknown VM, the VM itself, no engine, a protected
# engine, a cycle) by the same computation config validate uses, so nothing is reimplemented here
# (rule 4 of the journey). Leaves the links in LINKS_JSON.
_ask_links() {
    # Both VM lists are read into arrays first: a `while read … done < <(…)` loop redirects stdin
    # for its whole body, which would swallow the answer of the _read prompt below.
    local web o others default name candidate merged desc errs line
    local -a all_vms
    mapfile -t all_vms < <(apply_vms "$SESSION_CONFIG")
    LINKS_JSON='[]'
    desc="$(apply_describes "$SESSION_CONFIG")"
    for web in "${all_vms[@]}"; do
        [[ -n "$web" ]] || continue
        _vm_has_type "$web" chat-interface || continue
        others=""
        for o in "${all_vms[@]}"; do
            [[ -n "$o" && "$o" != "$web" ]] || continue
            _vm_has_type "$o" engine || continue
            others="${others:+$others }$o"
        done
        if _vm_has_type "$web" engine; then default=none; else default="${others:-none}"; fi
        while :; do
            _read "Which VMs hold the engines whose models $web lists? (names separated by spaces, none)" "$default"
            if [[ "$REPLY" == none ]]; then
                candidate="$LINKS_JSON"
            else
                candidate="$LINKS_JSON"
                for name in $REPLY; do
                    candidate="$(jq -c --arg w "$web" --arg e "$name" '. + [{web_vm: $w, engine_vm: $e}]' <<<"$candidate")"
                done
            fi
            merged="$(jq -c --argjson links "$candidate" '. + {links: $links}' <<<"$SESSION_CONFIG")"
            errs="$(config_cross "$merged" "$desc" | jq -r '.errors[] | select(.path | startswith("$.links")) | .message')"
            if [[ -n "$errs" ]]; then
                while IFS= read -r line; do log_warn "$line"; done <<<"$errs"
                continue
            fi
            LINKS_JSON="$candidate"
            break
        done
    done
}

# _final_summary: the summary of the whole configuration, once every VM and the links are known
# (docs/spec-multi-vm.md#creating): the links, and the warnings and errors that need several VMs,
# which a pass cannot give. Confirm (y, default) writes, cancel (n) or end of input writes nothing.
_final_summary() {
    printf '\nLinks: %s\n' "$(jq -r '(.links // []) | if length == 0 then "none" else map("\(.web_vm) -> \(.engine_vm)") | join(", ") end' <<<"$SESSION_CONFIG")" >&2
    print_cross_warnings "$SESSION_CONFIG"
    _read "Write the configuration? (y/n)" y
    if [[ "$REPLY" != y && "$REPLY" != Y ]]; then
        log_info "cancelled, nothing written"
        exit 0
    fi
}

# run_session: the first VM exactly as a one-VM session, then, for any number of further VMs, a
# role, a name and a pass, then the links, then the summary of the whole configuration
# (docs/spec-multi-vm.md#creating). With one VM, ends exactly as a one-VM session does. Leaves the
# configuration in SESSION_CONFIG.
run_session() {
    local role name
    VM_NAMES=()
    PASS_DONE='[]'
    run_pass "" ""
    # the question is asked when there is something to split: an engine and a chat interface
    if [[ -z "$(component_names engine)" || -z "$(component_names chat-interface)" ]]; then
        SESSION_CONFIG="$PASS_CONFIG"
        return 0
    fi
    _read "Add another VM? (y/n)" n
    if [[ "$REPLY" != y && "$REPLY" != Y ]]; then
        SESSION_CONFIG="$PASS_CONFIG"
        return 0
    fi
    _ask_vm_name "$(_default_vm_name custom)"
    name="$REPLY"
    PASS_DONE="$(jq -c --argjson c "$PASS_CONFIG" --arg v "$name" '. + [{vm: $v, config: $c}]' <<<"$PASS_DONE")"
    while :; do
        _ask_role
        role="$REPLY"
        _ask_vm_name "$(_default_vm_name "$role")"
        name="$REPLY"
        run_pass "$role" "$name"
        PASS_DONE="$(jq -c --argjson c "$PASS_CONFIG" --arg v "$name" '. + [{vm: $v, config: $c}]' <<<"$PASS_DONE")"
        _read "Add another VM? (y/n)" n
        [[ "$REPLY" == y || "$REPLY" == Y ]] || break
    done
    SESSION_CONFIG="$(_assemble_done)"
    _ask_links
    SESSION_CONFIG="$(jq -c --argjson l "$LINKS_JSON" '. + (if ($l | length) > 0 then {links: $l} else {} end)' <<<"$SESSION_CONFIG")"
    _final_summary
}

# ======================================================================================
# The editor: generate --edit <file>, docs/spec-multi-vm.md#editing. Opens an existing
# configuration, shows the summary of the whole thing and a letter menu, and keeps applying
# commands to EDIT_CONFIG until the person writes (y) or leaves (q, cancel, end of input).
# ======================================================================================

# shellcheck disable=SC2034  # read and written by generate.sh's run_editor
EDIT_CONFIG=""     # the configuration as it stands, updated by each command
EDIT_ERRORS='[]'   # the errors of the last summary, see _editor_summary
EDIT_WARNINGS='[]' # the warnings of the last summary

# _editor_vm_name <vm>: "no VM" (empty string) prints as "the configuration" in messages.
_editor_vm_label() { [[ -n "$1" ]] && printf '%s\n' "$1" || printf 'the configuration\n'; }

# _editor_slice <config> <vm>: the slice of that VM, or the whole file when it names none.
_editor_slice() {
    if [[ -n "$2" ]]; then apply_slice "$1" "$2"; else jq -c 'del(.links)' <<<"$1"; fi
}

# _editor_fmt_options <slice> <type> <name>: "--k=v …", a secret (an object value) shown as
# "(secret)", never its source.
_editor_fmt_options() {
    jq -r --arg t "$2" --arg n "$3" '
        (.components[] | select(.type == $t and .name == $n) | .options // {})
        | to_entries | map("--\(.key)=\(if (.value | type) == "object" then "(secret)" else (.value | tostring) end)") | join(" ")' <<<"$1"
}

# _editor_print_vm_body <slice>: components in install order (as written when the order is
# circular, which the editor still has to show), then its models.
_editor_print_vm_body() {
    local config="$1" desc order type name
    desc="$(apply_describes "$config")"
    if order="$(apply_order "$config" "$desc" 2>/dev/null)"; then
        while read -r type name; do
            [[ -n "$name" ]] || continue
            printf '    %s %s %s\n' "$type" "$name" "$(_editor_fmt_options "$config" "$type" "$name")"
        done <<<"$order"
    else
        jq -r '.components[]? | "    \(.type) \(.name) (order unresolved: circular requirement)"' <<<"$config"
    fi
    printf '    models: %s\n' "$(jq -r '[.models[]?.name] | if length == 0 then "none" else join(", ") end' <<<"$config")"
}

# _editor_compute <config>: leaves the errors and warnings of the whole configuration in
# EDIT_ERRORS / EDIT_WARNINGS (links included), without printing anything: used by the summary
# and by the fix loop, which needs the current list without redrawing the screen.
_editor_compute() {
    local config="$1" desc named=0 cross
    desc="$(apply_describes "$config")"
    apply_named "$config" && named=1
    EDIT_ERRORS="$(apply_problems "$config" "$desc" true)"
    EDIT_WARNINGS="$(jq -c --argjson desc "$desc" "$CONFIG_WARNINGS_JQ" <<<"$config" 2>/dev/null)" || EDIT_WARNINGS='[]'
    if ((named)); then
        cross="$(config_cross "$config" "$desc" 2>/dev/null)" || cross='{"errors":[],"warnings":[],"next_steps":[]}'
        EDIT_ERRORS="$(jq -c --argjson c "$cross" '. + $c.errors' <<<"$EDIT_ERRORS")"
        EDIT_WARNINGS="$(jq -c --argjson c "$cross" '. + $c.warnings' <<<"$EDIT_WARNINGS")"
    fi
}

# _editor_summary <config>: the summary of the whole configuration (VMs, components, options
# with secrets masked, models, links, platforms) then every warning and every numbered error,
# each with its code, its vm and the command that fixes it. Leaves them in EDIT_ERRORS /
# EDIT_WARNINGS for the command loop (f, and refusing y while an error stands).
_editor_summary() {
    local config="$1" vm named=0 errors warnings
    apply_named "$config" && named=1
    _editor_compute "$config"
    errors="$EDIT_ERRORS"
    warnings="$EDIT_WARNINGS"
    {
        printf '\nConfiguration\n'
        if ((named)); then
            while IFS= read -r vm; do
                [[ -n "$vm" ]] || continue
                printf '  VM %s\n' "$vm"
                _editor_print_vm_body "$(apply_slice "$config" "$vm")"
            done < <(apply_vms "$config")
            printf '  links: %s\n' "$(jq -r '(.links // []) | if length == 0 then "none" else map("\(.web_vm) -> \(.engine_vm)") | join(", ") end' <<<"$config")"
        else
            _editor_print_vm_body "$config"
        fi
        if [[ "$warnings" != '[]' ]]; then
            printf '  [WARN]\n'
            jq -r '.[] | "    \(.path): \(.message)" + (if .vm then " (VM \(.vm))" else "" end)' <<<"$warnings"
        fi
        if [[ "$errors" != '[]' ]]; then
            printf '  [ERROR]\n'
            jq -r 'to_entries[] | "    \(.key + 1). \(.value.path): \(.value.message)" + (if .value.vm then " (VM \(.value.vm))" else "" end) + " [\(.value.code)]"' <<<"$errors"
        fi
    } >&2
}

# _editor_seed <slice>: SEL, OPTV and SESSION_MODELS from an existing slice, so a redone pass
# offers its current content as the defaults (docs/spec-multi-vm.md#editing).
_editor_seed() {
    local slice="$1" t name opts
    SEL=() OPTV=() SESSION_MODELS=()
    for t in "${TYPES[@]}"; do
        name="$(jq -r --arg t "$t" '[.components[]? | select(.type == $t)][0].name // empty' <<<"$slice")"
        [[ -n "$name" ]] || continue
        SEL[$t]="$name"
        opts="$(jq -c --arg t "$t" --arg n "$name" '(.components[] | select(.type == $t and .name == $n) | .options) // {}' <<<"$slice")"
        OPTV[$name]="$opts"
    done
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        SESSION_MODELS+=("$name")
    done < <(jq -r '.models[]?.name' <<<"$slice")
}

# step_options_edit: like step_options, but the default of each option is its current value
# (from OPTV, seeded by _editor_seed) rather than the describe's default.
step_options_edit() {
    local t name oname default secret descr cur
    for t in "${TYPES[@]}"; do
        name="${SEL[$t]:-}"
        [[ -n "$name" ]] || continue
        _describe_of "$t" "$name"
        [[ -n "${OPTV[$name]:-}" ]] || OPTV[$name]='{}'
        while IFS=$'\x1f' read -r oname default secret descr <&3; do
            [[ -n "$oname" ]] || continue
            if [[ "$secret" == true ]]; then
                log_info "$name: $oname is a secret, it is generated at run time and never written"
                continue
            fi
            cur="$(jq -r --arg k "$oname" 'if has($k) then .[$k] | tostring else empty end' <<<"${OPTV[$name]}")"
            [[ -n "$cur" ]] || cur="$default"
            printf '  %s\n' "$descr" >&2
            _read "$name --$oname" "$cur"
            if [[ "$REPLY" == "$default" ]]; then
                OPTV[$name]="$(jq -c --arg k "$oname" 'del(.[$k])' <<<"${OPTV[$name]}")"
            elif [[ -n "$REPLY" ]]; then
                OPTV[$name]="$(jq -c --arg k "$oname" --arg v "$REPLY" '. + {($k): $v}' <<<"${OPTV[$name]}")"
            fi
        done 3< <(jq -r '.options[]? | [.name, (.default // ""), (.secret // false | tostring), (.description // "")] | join("")' <<<"${DESC[$name]}")
    done
}

# _editor_walk_components <vm>: every type, preselected from SEL (seeded by _editor_seed):
# "Keep/add a <type> on <vm>? (y/n)", y default when it is already there. On y, the choice of
# the component (the current one preselected); on n, it leaves that type out.
_editor_walk_components() {
    local vm="$1" t names default_yn rank
    for t in "${TYPES[@]}"; do
        names="$(component_names "$t" | tr '\n' ' ')"
        [[ -n "${names// /}" ]] || continue
        default_yn=n
        [[ -z "${SEL[$t]:-}" ]] || default_yn=y
        _read "Keep/add a $t on $vm? (y/n)" "$default_yn"
        if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
            rank="${SEL[$t]:-}"
            [[ -n "$rank" ]] || rank="$(rank_lookup "$t")"
            [[ " $names " == *" $rank "* ]] || rank="${names%% *}"
            while :; do
                _read "$t (${names% })" "$rank"
                if [[ " $names " == *" $REPLY "* ]]; then
                    SEL[$t]="$REPLY"
                    break
                fi
                log_warn "'$REPLY' is not one of: $names"
            done
        else
            unset "SEL[$t]"
        fi
    done
}

# _editor_run_pass <vm>: redo the pass of an existing VM from its current content, always as
# custom (docs/spec-multi-vm.md#editing: "it never imposes a role"). Leaves the new one-VM
# configuration in PASS_CONFIG; SUMMARY_ERRORS says whether it still needs fixing.
_editor_run_pass() {
    local vm="$1" step=1 answer
    printf '\nVM %s\n' "$vm" >&2
    while :; do
        case "$step" in
        1) _editor_walk_components "$vm"; step=2 ;;
        2) if step_dependencies; then step=3; else step=1; fi ;;
        3) step_options_edit; step=4 ;;
        4)
            PROXY_DECLINED=0
            step_models
            if ((PROXY_DECLINED)); then step=1; else step=5; fi
            ;;
        5)
            PASS_CONFIG="$(session_config)"
            print_summary "$PASS_CONFIG"
            _read "Confirm (y), cancel (n) or redo a step: components (c), options (o), models (m)" y
            answer="$REPLY"
            case "$answer" in
            y | Y) return 0 ;;
            n | N) return 1 ;;
            c | C) step=1 ;;
            o | O) step=3 ;;
            m | M) step=4 ;;
            *) log_warn "'$answer' is not a valid answer" ;;
            esac
            ;;
        esac
    done
}

# _editor_vms <config>: the VM names, one per line; a single empty line for a file with none
# (it is then "the" VM of the editor, with no name).
_editor_vms() {
    if apply_named "$1"; then apply_vms "$1"; else printf '\n'; fi
}

# _editor_set_vm_slice <config> <vm> <new-slice>: the configuration with that VM's components
# and models replaced (its vm added back when the file names VMs), keeping every other VM, its
# links, and anything else the editor does not touch (order of components, `default`…).
_editor_set_vm_slice() {
    local config="$1" vm="$2" slice="$3"
    if [[ -n "$vm" ]]; then
        slice="$(jq -c --arg v "$vm" '
            .components |= map(. + {vm: $v})
            | .models = ((.models // []) | map(. + {vm: $v}))
            | if (.models | length) == 0 then del(.models) else . end' <<<"$slice")"
        jq -c --arg v "$vm" --argjson s "$slice" '
            .components |= (map(select(.vm != $v)) + $s.components)
            | .models = (((.models // []) | map(select(.vm != $v))) + ($s.models // []))
            | if (.models | length) == 0 then del(.models) else . end' <<<"$config"
    else
        printf '%s\n' "$slice"
    fi
}

# _editor_promote <vm>: a one-VM file (no vm field) gets one, becoming the whole content of
# that VM; `vm` is all or none (docs/spec-config.md#several-vms).
_editor_promote() {
    EDIT_CONFIG="$(jq -c --arg v "$1" '
        .components |= map(. + {vm: $v})
        | .models = ((.models // []) | map(. + {vm: $v}))
        | if (.models | length) == 0 then del(.models) else . end' <<<"$EDIT_CONFIG")"
}

# _editor_add_vm: `a`, a role, a name and a pass, then its own links if it holds a chat
# interface (docs/spec-multi-vm.md#editing: "a adds a VM: its role..., then its pass, then its
# links"). A one-VM file (no vm yet) is named first, becoming a several-VM one. Reads and
# updates EDIT_CONFIG directly: called straight, never through "$(...)", since a session that
# ends on end of input exits the whole program from inside run_pass / _ask_links_for_one, and a
# command substitution would only end the subshell.
_editor_add_vm() {
    local role name was_named=0
    apply_named "$EDIT_CONFIG" && was_named=1
    if ((! was_named)); then
        _ask_vm_name vm-1
        _editor_promote "$REPLY"
        printf 'the existing machine is now VM %s\n' "$REPLY" >&2
    fi
    _ask_role
    role="$REPLY"
    _ask_vm_name "$(_default_vm_name "$role")"
    name="$REPLY"
    SEL=() OPTV=() SESSION_MODELS=()
    case "$role" in
    engine) PASS_REQUIRED=engine ;;
    web) PASS_REQUIRED=chat-interface ;;
    *) PASS_REQUIRED="" ;;
    esac
    run_pass "$role" "$name" || return 0
    EDIT_CONFIG="$(_editor_set_vm_slice "$EDIT_CONFIG" "$name" "$PASS_CONFIG")"
    if jq -e --arg v "$name" 'any((.components // [])[]; .vm == $v and .type == "chat-interface")' <<<"$EDIT_CONFIG" >/dev/null; then
        SESSION_CONFIG="$EDIT_CONFIG"
        _ask_links_for_one "$name"
        EDIT_CONFIG="$(jq -c --arg v "$name" --argjson l "$LINKS_JSON" '
            .links = ((.links // []) | map(select(.web_vm != $v)) + $l)' <<<"$SESSION_CONFIG")"
    fi
}

# _ask_links_for_one <web>: the links question for one VM only (used by a and l), the current
# links (if any) offered as the default. Leaves the answer in LINKS_JSON (that VM's links alone).
_ask_links_for_one() {
    local web="$1" others o default name candidate merged desc errs line current
    desc="$(apply_describes "$SESSION_CONFIG")"
    current="$(jq -r --arg w "$web" '[(.links // [])[] | select(.web_vm == $w) | .engine_vm] | join(" ")' <<<"$SESSION_CONFIG")"
    others=""
    while IFS= read -r o; do
        [[ -n "$o" && "$o" != "$web" ]] || continue
        _vm_has_type "$o" engine || continue
        others="${others:+$others }$o"
    done < <(apply_vms "$SESSION_CONFIG")
    if [[ -n "$current" ]]; then
        default="$current"
    elif _vm_has_type "$web" engine; then
        default=none
    else
        default="${others:-none}"
    fi
    LINKS_JSON='[]'
    while :; do
        _read "Which VMs hold the engines whose models $web lists? (names separated by spaces, none)" "$default"
        if [[ "$REPLY" == none ]]; then
            candidate='[]'
        else
            candidate='[]'
            for name in $REPLY; do
                candidate="$(jq -c --arg w "$web" --arg e "$name" '. + [{web_vm: $w, engine_vm: $e}]' <<<"$candidate")"
            done
        fi
        merged="$(jq -c --arg w "$web" --argjson links "$candidate" '
            .links = ((.links // []) | map(select(.web_vm != $w)) + $links)' <<<"$SESSION_CONFIG")"
        errs="$(config_cross "$merged" "$desc" | jq -r '.errors[] | select(.path | startswith("$.links")) | .message')"
        if [[ -n "$errs" ]]; then
            while IFS= read -r line; do log_warn "$line"; done <<<"$errs"
            continue
        fi
        LINKS_JSON="$candidate"
        break
    done
}

# _editor_edit_vm <vm>: `e <vm>`, redo its pass from its current content. Cancelling (n) at its
# own confirm leaves that VM untouched. Updates EDIT_CONFIG directly (see _editor_add_vm: never
# called through "$(...)").
_editor_edit_vm() {
    local vm="$1" slice
    slice="$(_editor_slice "$EDIT_CONFIG" "$vm")"
    _editor_seed "$slice"
    if _editor_run_pass "$(_editor_vm_label "$vm")"; then
        EDIT_CONFIG="$(_editor_set_vm_slice "$EDIT_CONFIG" "$vm" "$PASS_CONFIG")"
    else
        log_info "unchanged"
    fi
}

# _editor_redo_models <vm>: `m <vm>`, redo its models only, keeping its components. Updates
# EDIT_CONFIG directly (never called through "$(...)").
_editor_redo_models() {
    local vm="$1" slice
    slice="$(_editor_slice "$EDIT_CONFIG" "$vm")"
    _editor_seed "$slice"
    if [[ -z "${SEL[engine]:-}" ]]; then
        log_warn "VM $(_editor_vm_label "$vm") has no engine, nothing to size models for"
        return 0
    fi
    step_models
    PASS_CONFIG="$(session_config)"
    print_summary "$PASS_CONFIG"
    _read "Confirm (y) or cancel (n)" y
    if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
        EDIT_CONFIG="$(_editor_set_vm_slice "$EDIT_CONFIG" "$vm" "$PASS_CONFIG")"
    else
        log_info "unchanged"
    fi
}

# _editor_redo_links: `l`, the links question again for every VM with a chat interface, the
# current links offered as the default. Updates EDIT_CONFIG directly (never called through
# "$(...)"); a plain `for` over an array, not a `while read … done < <(…)`, which would
# redirect stdin for the whole body and starve the _read prompts inside it.
_editor_redo_links() {
    local vm
    local -a vms=()
    SESSION_CONFIG="$EDIT_CONFIG"
    mapfile -t vms < <(apply_vms "$EDIT_CONFIG")
    for vm in "${vms[@]}"; do
        [[ -n "$vm" ]] || continue
        _vm_has_type "$vm" chat-interface || continue
        _ask_links_for_one "$vm"
        SESSION_CONFIG="$(jq -c --arg w "$vm" --argjson links "$LINKS_JSON" '
            .links = ((.links // []) | map(select(.web_vm != $w)) + $links)' <<<"$SESSION_CONFIG")"
    done
    EDIT_CONFIG="$SESSION_CONFIG"
}

# _editor_rename_vm <config> <old> <new>: `n <vm>`, its components, its models and the links
# that name it follow.
_editor_rename_vm() {
    jq -c --arg o "$2" --arg n "$3" '
        .components |= map(if .vm == $o then . + {vm: $n} else . end)
        | (if has("models") then .models |= map(if .vm == $o then . + {vm: $n} else . end) else . end)
        | (if has("links") then .links |= map(
             (if .web_vm == $o then .web_vm = $n else . end)
             | (if .engine_vm == $o then .engine_vm = $n else . end)) else . end)' <<<"$1"
}

# _editor_remove_vm <config> <vm>: `r <vm>`, its components, its models and the links that name
# it; the last VM is refused by the caller before this runs.
_editor_remove_vm() {
    jq -c --arg v "$2" '
        .components |= map(select(.vm != $v))
        | (if has("models") then .models |= map(select(.vm != $v)) else . end)
        | (if (.models // []) == [] then del(.models) else . end)
        | (if has("links") then .links |= map(select(.web_vm != $v and .engine_vm != $v)) else . end)' <<<"$1"
}

# _editor_fix: `f`, one pass over the errors EDIT_ERRORS held at the time it was chosen
# (docs/spec-multi-vm.md#editing). Each kind of error is handled the way the spec lists: an
# unknown entry is offered for removal, duplicate_server_name and the link errors point to the
# fix and offer to run it; anything else sends the person to the VM it is about. Before showing
# an error, it is checked against the current configuration: one an earlier fix in this same
# pass already resolved is skipped silently. Updates EDIT_CONFIG directly (never called through
# "$(...)").
_editor_fix() {
    local errors="$EDIT_ERRORS" i=0 err code path vm msg still
    while :; do
        err="$(jq -c ".[$i] // empty" <<<"$errors")"
        [[ -n "$err" ]] || break
        code="$(jq -r '.code' <<<"$err")"
        path="$(jq -r '.path' <<<"$err")"
        _editor_compute "$EDIT_CONFIG"
        still="$(jq --arg c "$code" --arg p "$path" 'any(.[]; .code == $c and .path == $p)' <<<"$EDIT_ERRORS")"
        if [[ "$still" != true ]]; then
            i=$((i + 1))
            continue
        fi
        vm="$(jq -r '.vm // empty' <<<"$err")"
        msg="$(jq -r '.message' <<<"$err")"
        printf '\n%s: %s [%s]\n' "$path" "$msg" "$code" >&2
        case "$code" in
        unknown_key | unknown_component | unknown_option | invalid_value | wrong_type)
            _read "Remove this entry? (y/n)" y
            if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
                # $path is the display form ("$.foo[0].bar"); jq's own path syntax drops the "$"
                EDIT_CONFIG="$(jq -c "del(${path#\$})" <<<"$EDIT_CONFIG" 2>/dev/null)" ||
                    log_warn "could not remove $path by itself, edit VM $(_editor_vm_label "$vm") instead"
            fi
            ;;
        duplicate_server_name)
            _read "Edit VM $vm now to change its server-name? (y/n)" y
            [[ "$REPLY" != y && "$REPLY" != Y ]] || _editor_edit_vm "$vm"
            ;;
        unlinked_vm | engine_unreachable | link_cycle | link_protected_engine)
            _read "Redo the links (l), edit VM $vm (e), remove it (r), or leave it (any other answer)" l
            case "$REPLY" in
            l | L) _editor_redo_links ;;
            e | E) _editor_edit_vm "$vm" ;;
            r | R) _editor_remove_vm_checked "$vm" ;;
            esac
            ;;
        missing_requirement | unresolved_engine | unresolved_chat_interface | ambiguous_engine | ambiguous_chat_interface | engine_other_vm | chat_interface_other_vm)
            if [[ -n "$vm" ]]; then
                _read "Edit VM $vm now to fix this? (y/n)" y
                [[ "$REPLY" != y && "$REPLY" != Y ]] || _editor_edit_vm "$vm"
            else
                log_warn "fix it by hand, or with e/m/l/n/r"
            fi
            ;;
        *)
            if [[ -n "$vm" ]]; then
                _read "Edit VM $vm now to fix this? (y/n)" n
                [[ "$REPLY" != y && "$REPLY" != Y ]] || _editor_edit_vm "$vm"
            else
                log_warn "fix it by hand, or with e/m/l/n/r"
            fi
            ;;
        esac
        i=$((i + 1))
    done
}

# _editor_remove_vm_checked <vm>: `r` from the fix loop, the last VM refused as the real `r`
# command does.
_editor_remove_vm_checked() {
    if (($(apply_vms "$EDIT_CONFIG" | grep -c .) <= 1)); then
        log_warn "the last VM cannot be removed"
    else
        EDIT_CONFIG="$(_editor_remove_vm "$EDIT_CONFIG" "$1")"
    fi
}
