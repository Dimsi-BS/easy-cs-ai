#!/usr/bin/env bash
# Question engine of the VM script generator: an interactive session that ends
# with a configuration (docs/spec-config.md). Sourced by lib/generator.sh. Prompts
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
        # shellcheck disable=SC2153 # EXIT_ERROR is common.sh's exit code, not a typo of EDIT_ERRORS
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

PASS_VM=""        # the name of the VM of the pass ("" for none)

# session_config: print the configuration JSON of the current selection: a file of one VM (the
# VM of the pass), its components, and the models held by its engine (docs/spec-config.md#format).
session_config() {
    local t name comps='[]' models='[]' m opts force=false
    # No llmfit in the stack: nothing on the VM can check the fit, and `add` would stop on the
    # missing requirement, so the models are added unchecked (the summary says so).
    [[ -n "${SEL[provisioning]:-}" ]] || force=true
    for m in "${SESSION_MODELS[@]}"; do
        models="$(jq -c --arg m "$m" --argjson f "$force" '. + [{model: $m} + (if $f then {force: true} else {} end)]' <<<"$models")"
    done
    for t in "${TYPES[@]}"; do
        name="${SEL[$t]:-}"
        [[ -n "$name" ]] || continue
        opts="${OPTV[$name]:-}"
        [[ -n "$opts" ]] || opts='{}'
        comps="$(jq -c --arg k "$t/$name" --argjson o "$opts" --argjson m "$models" --arg t "$t" \
            '. + [{component: $k} + (if ($o | length) > 0 then {options: $o} else {} end)
                  + (if $t == "engine" and ($m | length) > 0 then {models: $m} else {} end)]' <<<"$comps")"
    done
    jq -n --argjson c "$comps" --arg v "$PASS_VM" \
        '{schema_version: '"$APPLY_SCHEMA_VERSION"', vms: [(if $v == "" then {} else {name: $v} end) + {components: $c}]}'
}

# summary_warnings <config> <describe-map>: the warnings of the options whose effective
# value (the one given, else the default) equals the `when` of their `warn` entry in
# `describe`, one line each, so a risk that comes with a default (LibreChat's open
# registration) is read before the VM exists. The wording comes from the script.
summary_warnings() {
    jq -r --argjson cfg "$1" '
      to_entries[] | .key as $k | .value as $d | ($k | split("/")) as [$t, $n]
      | ($cfg.vms[0].components[] | select(.component == $k) | (.options // {})) as $o
      | $d.options[]? | select(.warn != null) | . as $opt
      | (if ($o | has($opt.name)) then $o[$opt.name] else $opt.default end | tostring) as $v
      | select($v == $opt.warn.when)
      | "    \($n) --\($opt.name)=\($v): \($opt.warn.message)"' <<<"$2"
}

# print_summary <config>: components in install order, options (secrets are
# generated, so nothing to mask), models, platforms, and the warnings of the options.
# <config> is the file of one VM. SUMMARY_ERRORS: how many problems the last summary showed
# (what a model needs and the file does not give, for instance a package that ships no proxy to
# propose): the session does not confirm a configuration that cannot finish.
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
    errors="$(apply_problems "$config" "$desc" true | jq -r '.[] | select(.code == "missing_requirement" and (.path | test("\\.models\\[[0-9]+\\]$"))) | "    \(.message)"')"
    SUMMARY_ERRORS=0
    [[ -z "$errors" ]] || SUMMARY_ERRORS="$(grep -c . <<<"$errors")"
    {
        printf '\nSummary\n  components, in install order:\n'
        while read -r type name; do
            [[ -n "$name" ]] || continue
            printf '    %s %s %s\n' "$type" "$name" "$(jq -r --arg k "$type/$name" '(.vms[0].components[] | select(.component == $k) | .options // {}) | to_entries | map("--\(.key)=\(.value)") | join(" ")' <<<"$config")"
        done <<<"$order"
        printf '  models: %s\n' "$(jq -r '[.vms[0].components[] | .models[]? | .model] | if length == 0 then "none" else join(", ") end' <<<"$config")"
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

# The session is the journey walked once per VM (docs/spec-multi-vm.md#in-the-session): a pass is
# the five steps over the types of a VM.
# shellcheck disable=SC2034  # read by config.sh and script.sh
SESSION_CONFIG=""
PASS_CONFIG=""
PASS_DONE='[]'    # the passes already confirmed: [{vm, config}], the one-VM file of each
VM_NAMES=()       # the names given so far, in order

# _assemble_done: the file of every pass in PASS_DONE, one VM each, no link yet.
_assemble_done() {
    jq -n --argjson parts "$PASS_DONE" '
        {schema_version: '"$APPLY_SCHEMA_VERSION"', vms: [$parts[] | {name: .vm, components: .config.vms[0].components}]}'
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
    rank="${SEL[$t]:-$(rank_lookup "$t")}"
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
            if [[ "$t" == provisioning ]]; then
                printf '  llmfit checks on the VM that each model fits; with none, the models are added unchecked
' >&2
            fi
            _read "Add a $t on $vm? (y/n)" y
            if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
                _choose_component "$t" "$names"
            else
                unset "SEL[$t]"
            fi
        done
        _selected_any && return 0
        log_warn "this VM has no component yet, choose again"
    done
}

# run_pass <role> <vm>: the five steps over the types of a VM. <role> is "" for the plain,
# unrestricted pass, or engine / web / custom (docs/spec-multi-vm.md#creating). <vm> is the
# name of the VM. Leaves the one-VM file of the pass in PASS_CONFIG. Cancelling cancels
# everything.
run_pass() {
    local role="${1:-}" vm="${2:-}" step=1 answer menu="components (c), options (o), models (m)"
    VM_MODE="$role"
    PASS_VM="$vm"
    PASS_REQUIRED=""
    PASS_TYPES=("${TYPES[@]}")
    case "$role" in
    engine) PASS_TYPES=(provisioning proxy engine); PASS_REQUIRED=engine ;;
    web)
        PASS_TYPES=(proxy chat-interface)
        PASS_REQUIRED="chat-interface"
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
# be computed: the error (two VMs with the same server name) and the warning (an address not known
# yet), each naming its VM.
print_cross_warnings() {
    local cross errlines warnlines
    cross="$(config_cross "$1" "$(apply_describes "$1")")"
    errlines="$(jq -r '.errors[] | select(.code == "duplicate_server_name") | "    [VM \(.vm)] \(.message)"' <<<"$cross")"
    warnlines="$(jq -r '.warnings[] | select(.code == "engine_address_unknown") | "    [VM \(.vm)] \(.message)"' <<<"$cross")"
    [[ -z "$errlines" ]] || printf '  [ERROR] between the VMs, to fix before this can be confirmed:\n%s\n' "$errlines" >&2
    [[ -z "$warnlines" ]] || printf '  [WARN] between the VMs, to read before creating them:\n%s\n' "$warnlines" >&2
}

# --- Where the models are shown: the links, docs/spec-multi-vm.md#where-the-models-are-shown ----

LINK_CFG=""           # the configuration the questions of the links work on
LINK_INTRO_DONE=0     # the sentence that says what the question decides is printed once per session
LINK_TARGETS=()       # the models to ask about: "<vm> <TAB> <engine> <TAB> <model>"

# The model `$model` of engine `$engine` (implementation) of VM `$vm` is given its names, then every
# link it had is replaced by the one to chat interface `$chat` of VM `$chatvm` (none when `$chatvm`
# is empty). A link designates by name and is complete: the session writes the implementation as the
# `name` of the engine and of the chat interface and the `model` as the name of the instance, with no
# question, and keeps a name that was written.
# shellcheck disable=SC2016
readonly LINK_SET_JQ='
def name_comp($v; $k): .vms |= map(if .name == $v then .components |= map(if .component == $k and (has("name") | not) then . + {name: ($k | split("/")[1])} else . end) else . end);
def name_model: .vms |= map(if .name == $vm then .components |= map(
    if .component == "engine/\($engine)" and has("models") then .models |= map(if .model == $model and (has("name") | not) then . + {name: $model} else . end) else . end) else . end);
name_comp($vm; "engine/\($engine)") | name_model
| (first(.vms[] | select(.name == $vm) | .components[] | select(.component == "engine/\($engine)"))) as $en
| $en.name as $eref | (first($en.models[] | select(.model == $model)).name) as $mref
| .links = ((.links // []) | map(select((.model.vm_ref == $vm and .model.component_ref == $eref and .model.model_ref == $mref) | not)))
| if $chatvm != "" then
    name_comp($chatvm; "chat-interface/\($chat)")
    | (first(.vms[] | select(.name == $chatvm) | .components[] | select(.component == "chat-interface/\($chat)")).name) as $cref
    | .links += [{model: {vm_ref: $vm, component_ref: $eref, model_ref: $mref}, chat_interface: {vm_ref: $chatvm, component_ref: $cref}}]
  else . end
| if (.links | length) == 0 then del(.links) else . end'

# _link_targets <config> [<vm>]: the models of the file (of that VM when given), one per line.
_link_targets() {
    jq -r --arg vm "${2:-}" '.vms[] | .name as $v | select($vm == "" or $v == $vm) | .components[]
        | select(.component | startswith("engine/")) | (.component | split("/")[1]) as $e
        | (.models // [])[] | [$v, $e, .model] | @tsv' <<<"$1"
}

# _link_targets_unlinked <config>: the models that no link shows, one per line.
# shellcheck disable=SC2016
_link_targets_unlinked() {
    jq -r --argjson desc '{}' --argjson installed '{}' '. as $cfg | '"$APPLY_COMMON_JQ$APPLY_LINKS_JQ"'
        resolved_links as $rl
        | comps[] | select(.type == "engine") | . as $en | (.c.models // [])[]? | . as $m
        | select(([$rl[] | select(.mvi == $en.vi and .en.ci == $en.ci and .model.model == $m.model)] | length) == 0)
        | [$en.vname, $en.impl, $m.model] | @tsv' <<<"$1"
}

# _name_lone_vm: a file of one VM that has no name gets one (a link designates its VMs by name and
# the names become required with several), asked as the editor asks any name. Works on LINK_CFG.
_name_lone_vm() {
    [[ "$(jq -r '((.vms | type) == "array") and ((.vms | length) == 1) and (.vms[0].name == null)' <<<"$LINK_CFG")" == true ]] || return 0
    VM_NAMES=()
    _ask_vm_name vm-1
    LINK_CFG="$(jq -c --arg n "$REPLY" '.vms[0] = ({name: $n} + .vms[0])' <<<"$LINK_CFG")"
    printf 'the existing machine is now VM %s\n' "$REPLY" >&2
}

# _ask_link_one <vm> <engine> <model>: where this model is shown, in LINK_CFG. The answer is a VM
# with a chat interface (which one, when it holds several), or none; with one VM and one chat
# interface it is a yes or no. An answer that makes an error of the links is refused with its reason.
_ask_link_one() {
    local vm="$1" engine="$2" model="$3" cfg="$LINK_CFG" chatvm="" chat="" default answer cur candidate errs line
    local -a chats=() chatvms=() onvm=()
    local single=0 k
    mapfile -t chats < <(jq -r '.vms[] | .name as $v | .components[] | select(.component | startswith("chat-interface/")) | [$v, (.component | split("/")[1])] | @tsv' <<<"$cfg")
    ((${#chats[@]})) || return 0
    mapfile -t chatvms < <(printf '%s\n' "${chats[@]}" | cut -f1 | awk '!seen[$0]++')
    [[ "$(jq '.vms | length' <<<"$cfg")" == 1 && ${#chats[@]} == 1 ]] && single=1
    cur="$(jq -r --arg vm "$vm" --arg e "$engine" --arg m "$model" '
        (first(.vms[] | select(.name == $vm) | .components[] | select(.component == "engine/\($e)")) // {}) as $en
        | (first(($en.models // [])[]? | select(.model == $m)) // {}) as $mo
        | first((.links // [])[] | select(.model.vm_ref == $vm and .model.component_ref == ($en.name // "") and .model.model_ref == ($mo.name // "")) | .chat_interface.vm_ref) // empty' <<<"$cfg")"
    if [[ -n "$cur" && " ${chatvms[*]} " == *" $cur "* ]]; then
        default="$cur"
    elif [[ " ${chatvms[*]} " == *" $vm "* ]]; then
        default="$vm"
    elif ((${#chatvms[@]} == 1)); then
        default="${chatvms[0]}"
    else
        default=none
    fi
    ((LINK_INTRO_DONE)) || {
        printf '  a model is installed on an engine and shown in a chat interface; when the chat interface is on another VM,\n  the two machines are linked by hand once they are up, the steps are printed.\n' >&2
        LINK_INTRO_DONE=1
    }
    while :; do
        if ((single)); then
            _read "Show $model (on $vm) in ${chats[0]#*$'\t'}? (y/n)" y
            case "$REPLY" in
            y | Y) chatvm="${chatvms[0]}"; chat="${chats[0]#*$'\t'}" ;;
            n | N) chatvm=""; chat="" ;;
            *) log_warn "'$REPLY' is not y or n"; continue ;;
            esac
        else
            _read "Which chat interface shows $model (on $vm)? (a VM with a chat interface, none)" "$default"
            answer="$REPLY"
            if [[ "$answer" == none ]]; then
                chatvm=""
                chat=""
            elif [[ " ${chatvms[*]} " != *" $answer "* ]]; then
                log_warn "'$answer' is not a VM with a chat interface (${chatvms[*]})"
                continue
            else
                chatvm="$answer"
                onvm=()
                for k in "${chats[@]}"; do [[ "${k%%$'\t'*}" == "$chatvm" ]] && onvm+=("${k#*$'\t'}"); done
                chat="${onvm[0]}"
                if ((${#onvm[@]} > 1)); then
                    while :; do
                        _read "Which chat interface of $chatvm? (${onvm[*]})" "${onvm[0]}"
                        [[ " ${onvm[*]} " == *" $REPLY "* ]] && { chat="$REPLY"; break; }
                        log_warn "'$REPLY' is not one of: ${onvm[*]}"
                    done
                fi
            fi
        fi
        candidate="$(jq -c --arg vm "$vm" --arg engine "$engine" --arg model "$model" --arg chatvm "$chatvm" --arg chat "$chat" "$LINK_SET_JQ" <<<"$cfg")"
        errs="$(apply_problems "$candidate" "$(apply_describes "$candidate")" | jq -r '.[] | select(.path | startswith("$.links")) | .message')"
        if [[ -n "$errs" ]]; then
            while IFS= read -r line; do log_warn "$line"; done <<<"$errs"
            continue
        fi
        LINK_CFG="$candidate"
        return 0
    done
}

# _ask_links: the question of where each model of LINK_TARGETS is shown, when the file holds a chat
# interface; the answers are written in LINK_CFG. Not called through "$(...)" (the end of input
# ends the whole program from inside _read).
_ask_links() {
    local line vm engine model
    ((${#LINK_TARGETS[@]})) || return 0
    [[ "$(jq '[.vms[].components[] | select(.component | startswith("chat-interface/"))] | length' <<<"$LINK_CFG")" -gt 0 ]] || return 0
    _name_lone_vm
    # the targets were listed before the lone VM had a name
    local named i
    named="$(jq -r '.vms[0].name // empty' <<<"$LINK_CFG")"
    for i in "${!LINK_TARGETS[@]}"; do
        [[ "${LINK_TARGETS[$i]}" != $'	'* ]] || LINK_TARGETS[i]="$named${LINK_TARGETS[$i]}"
    done
    for line in "${LINK_TARGETS[@]}"; do
        IFS=$'\t' read -r vm engine model <<<"$line"
        _ask_link_one "$vm" "$engine" "$model"
    done
}

# _shown_lines <config>: where each model is shown, in words ("llama3.2:3b on gpu, shown in web",
# "shown nowhere"), never as a bare arrow.
# shellcheck disable=SC2016
_shown_lines() {
    jq -r --argjson desc '{}' --argjson installed '{}' '. as $cfg | '"$APPLY_COMMON_JQ$APPLY_LINKS_JQ"'
        resolved_links as $rl
        | comps[] | select(.type == "engine") | . as $en | (.c.models // [])[]? | select(type == "object") | . as $m
        | (first($rl[] | select(.mvi == $en.vi and .en.ci == $en.ci and .model.model == $m.model)) // null) as $l
        | "\($m.model) on \($en.vname // "this VM"), " + (if $l != null then "shown in \($l.cvn)" else "shown nowhere" end)' <<<"$1"
}

# run_session: for any number of VMs, a role, a name and a pass each, then where each model is shown
# (docs/spec-multi-vm.md#creating). Leaves the configuration in SESSION_CONFIG.
run_session() {
    local role name
    VM_NAMES=()
    PASS_DONE='[]'
    LINK_INTRO_DONE=0
    while :; do
        _ask_role
        role="$REPLY"
        _ask_vm_name "$(_default_vm_name "$role")"
        name="$REPLY"
        run_pass "$role" "$name"
        PASS_DONE="$(jq -c --argjson c "$PASS_CONFIG" --arg v "$name" '. + [{vm: $v, config: $c}]' <<<"$PASS_DONE")"
        # the question is asked when there is something to split: an engine and a chat interface
        if [[ -z "$(component_names engine)" || -z "$(component_names chat-interface)" ]]; then break; fi
        _read "Add another VM? (y/n)" n
        [[ "$REPLY" == y || "$REPLY" == Y ]] || break
    done
    LINK_CFG="$(_assemble_done)"
    mapfile -t LINK_TARGETS < <(_link_targets "$LINK_CFG")
    _ask_links
    # shellcheck disable=SC2034  # read by config.sh
    SESSION_CONFIG="$LINK_CFG"
}

# ======================================================================================
# The editor: config edit <file>, docs/spec-multi-vm.md#editing. Opens an existing
# configuration (or, at the end of a creation, the one just built), shows the summary of the
# whole thing and a letter menu, and keeps applying commands to EDIT_CONFIG until the person
# writes (y) or leaves (q, cancel, end of input).
# ======================================================================================

# shellcheck disable=SC2034  # read and written by run_editor of lib/generator.sh
EDIT_CONFIG=""     # the configuration as it stands, updated by each command
EDIT_ERRORS='[]'   # the errors of the last summary, see _editor_summary
EDIT_WARNINGS='[]' # the warnings of the last summary

# _editor_vm_label <vm>: "" (a VM with no name) prints as "the configuration" in messages.
_editor_vm_label() { [[ -n "$1" ]] && printf '%s\n' "$1" || printf 'the configuration\n'; }

# _editor_slice <config> <vm>: the slice of that VM, or of the only VM when it has no name.
_editor_slice() { apply_slice "$1" "$2"; }

# _editor_fmt_options <slice> <component>: "--k=v …", a secret (an object value) shown as
# "(secret)", never its source.
_editor_fmt_options() {
    jq -r --arg k "$2" '
        (.vms[0].components[] | select(.component == $k) | .options // {})
        | to_entries | map("--\(.key)=\(if (.value | type) == "object" then "(secret)" else (.value | tostring) end)") | join(" ")' <<<"$1"
}

# _editor_print_vm_body <slice>: components in install order (as written when the order is
# circular, which the editor still has to show), then its models, only when it has an engine.
_editor_print_vm_body() {
    local config="$1" desc order type name
    desc="$(apply_describes "$config")"
    if order="$(apply_order "$config" "$desc" 2>/dev/null)"; then
        while read -r type name; do
            [[ -n "$name" ]] || continue
            printf '    %s %s %s\n' "$type" "$name" "$(_editor_fmt_options "$config" "$type/$name")"
        done <<<"$order"
    else
        jq -r '.vms[0].components[]? | "    \(.component) (order unresolved: circular requirement)"' <<<"$config"
    fi
    if [[ "$(jq -r 'any(.vms[0].components[]?; (.component // "") | startswith("engine/"))' <<<"$config")" == true ]]; then
        printf '    models: %s\n' "$(jq -r '[.vms[0].components[] | .models[]? | .model] | if length == 0 then "none" else join(", ") end' <<<"$config")"
    fi
}

# _editor_compute <config>: leaves the errors and warnings of the whole configuration in
# EDIT_ERRORS / EDIT_WARNINGS, without printing anything: used by the summary and by the fix
# loop, which needs the current list without redrawing the screen.
_editor_compute() {
    local config="$1" desc cross
    desc="$(apply_describes "$config")"
    EDIT_ERRORS="$(apply_problems "$config" "$desc" true)"
    EDIT_WARNINGS="$(jq -c --argjson desc "$desc" --argjson installed '{}' "$CONFIG_WARNINGS_JQ" <<<"$config" 2>/dev/null)" || EDIT_WARNINGS='[]'
    cross="$(config_cross "$config" "$desc" 2>/dev/null)" || cross='{"errors":[],"warnings":[],"next_steps":[]}'
    EDIT_ERRORS="$(jq -c --argjson c "$cross" '. + $c.errors' <<<"$EDIT_ERRORS")"
    EDIT_WARNINGS="$(jq -c --argjson c "$cross" '. + $c.warnings' <<<"$EDIT_WARNINGS")"
}

# _editor_summary <config>: the summary of the whole configuration (VMs, components, options
# with secrets masked, models and where each is shown, platforms) then every warning and every
# numbered error, each with its code, its vm and the path. Leaves them in EDIT_ERRORS /
# EDIT_WARNINGS for the command loop (f, and refusing y while an error stands).
_editor_summary() {
    local config="$1" vm shown errors warnings
    local -a names=()
    _editor_compute "$config"
    errors="$EDIT_ERRORS"
    warnings="$EDIT_WARNINGS"
    mapfile -t names < <(jq -r '(.vms // []) | if type == "array" then .[] else empty end | if type == "object" then (.name // "") else "" end' <<<"$config")
    shown="$(_shown_lines "$config" 2>/dev/null || true)"
    {
        printf '\nConfiguration\n'
        for vm in "${names[@]}"; do
            if [[ -n "$vm" ]]; then printf '  VM %s\n' "$vm"; else printf '  VM (no name)\n'; fi
            _editor_print_vm_body "$(apply_slice "$config" "$vm" 2>/dev/null || printf '{}')"
        done
        if [[ -n "$shown" ]]; then
            printf '  models:\n'
            while IFS= read -r vm; do printf '    %s\n' "$vm"; done <<<"$shown"
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
        name="$(jq -r --arg t "$t" '[.vms[0].components[]? | select((.component // "") | startswith($t + "/"))][0].component // empty | split("/")[1]' <<<"$slice")"
        [[ -n "$name" ]] || continue
        SEL[$t]="$name"
        opts="$(jq -c --arg k "$t/$name" '(.vms[0].components[] | select(.component == $k) | .options) // {}' <<<"$slice")"
        OPTV[$name]="$opts"
    done
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        SESSION_MODELS+=("$name")
    done < <(jq -r '.vms[0].components[]? | .models[]? | .model' <<<"$slice")
}

# step_options_edit [<only>]: like step_options, but the default of each option is its current
# value (from OPTV, seeded by _editor_seed) rather than the describe's default.
step_options_edit() {
    local only="${1:-}" t name oname default secret descr cur
    for t in "${TYPES[@]}"; do
        [[ -z "$only" || "$t" == "$only" ]] || continue
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
        done 3< <(jq -r '.options[]? | [.name, (.default // ""), (.secret // false | tostring), (.description // "")] | join("\u001f")' <<<"${DESC[$name]}")
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
# custom (docs/spec-multi-vm.md#editing: "it never imposes a role"). Leaves the new one-VM file in
# PASS_CONFIG; SUMMARY_ERRORS says whether it still needs fixing.
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

# _editor_set_vm_slice <config> <vm> <new-slice>: the configuration with that VM's components
# replaced by those of the pass, each keeping what the pass does not show (its `name`, its
# `default`, a model's `name` and any key it has no question for), and the components the pass
# cannot hold (a second one of a type). Every other VM and the links are kept.
_editor_set_vm_slice() {
    jq -c --arg v "$2" --argjson s "$3" '
        ($s.vms[0].components) as $new
        | (.vms | to_entries | map(select(if $v == "" then .key == 0 else .value.name == $v end))[0].key) as $i
        | (.vms[$i].components // []) as $old
        | .vms[$i].components = (
            [$new[] | . as $c | (([$old[] | select(.component == $c.component)][0]) // {}) as $o
              | ($o + $c)
              | (if ($c | has("options")) then . else del(.options) end)
              | (if ($c | has("models")) then
                   .models = [$c.models[] | . as $m | ((([($o.models // [])[] | select(.model == $m.model)][0]) // {}) | del(.force)) + $m]
                 else del(.models) end)]
            + [range(0; $old | length) as $k | $old[$k] as $c | ($c.component | split("/")[0]) as $t
               | select(any($new[]; (.component | split("/")[0]) == $t)
                        and ([$old[0:$k][] | select((.component | split("/")[0]) == $t)] | length) > 0
                        and (any($new[]; .component == $c.component) | not))
               | $c])' <<<"$1"
}

# _editor_prune_links: the links that no longer designate anything are announced and removed
# (nothing is left dangling, docs/spec-multi-vm.md#editing). Works on EDIT_CONFIG.
# shellcheck disable=SC2016
_editor_prune_links() {
    local before after
    before="$(jq '(.links // []) | length' <<<"$EDIT_CONFIG")"
    EDIT_CONFIG="$(jq -c --argjson desc '{}' --argjson installed '{}' '. as $cfg | '"$APPLY_COMMON_JQ$APPLY_LINKS_JQ"'
        ([resolved_links[].i]) as $ok
        | if has("links") and (.links | type) == "array"
          then .links = [.links | to_entries[] | select(.key | IN($ok[])) | .value] else . end
        | if (.links // []) == [] then del(.links) else . end' <<<"$EDIT_CONFIG")"
    after="$(jq '(.links // []) | length' <<<"$EDIT_CONFIG")"
    if ((before > after)); then
        printf 'removing %d link(s) that designated what is gone\n' "$((before - after))" >&2
    fi
}

# _editor_name_lone_vm: a file of one VM that has no name is asked one, before a second VM is added
# or a link is written. Works on EDIT_CONFIG.
_editor_name_lone_vm() {
    LINK_CFG="$EDIT_CONFIG"
    _name_lone_vm
    EDIT_CONFIG="$LINK_CFG"
}

# _editor_ask_links <targets…>: where each of the models is shown, on EDIT_CONFIG.
_editor_ask_links() {
    LINK_CFG="$EDIT_CONFIG"
    LINK_TARGETS=("$@")
    _ask_links
    EDIT_CONFIG="$LINK_CFG"
}

# _editor_add_vm: `a`, a role, a name and a pass, then where the models are shown. A file of one VM
# with no name is named first. Reads and updates EDIT_CONFIG directly: called straight, never
# through "$(...)", since a session that ends on end of input exits the whole program from inside.
_editor_add_vm() {
    local role name
    local -a targets=()
    _editor_name_lone_vm
    mapfile -t VM_NAMES < <(apply_vms "$EDIT_CONFIG")
    _ask_role
    role="$REPLY"
    _ask_vm_name "$(_default_vm_name "$role")"
    name="$REPLY"
    run_pass "$role" "$name" || return 0
    EDIT_CONFIG="$(jq -c --arg v "$name" --argjson p "$PASS_CONFIG" '.vms += [{name: $v, components: $p.vms[0].components}]' <<<"$EDIT_CONFIG")"
    mapfile -t targets < <(_link_targets "$EDIT_CONFIG" "$name")
    if [[ "$(jq -r --arg v "$name" 'any(.vms[] | select(.name == $v) | .components[]; .component | startswith("chat-interface/"))' <<<"$EDIT_CONFIG")" == true ]]; then
        mapfile -t -O "${#targets[@]}" targets < <(_link_targets_unlinked "$EDIT_CONFIG" | grep -vF "$(printf '%s\t' "$name")" || true)
    fi
    _editor_ask_links "${targets[@]}"
}

# _editor_edit_vm <vm>: `e <vm>`, redo its pass from its current content. Cancelling (n) at its
# own confirm leaves that VM untouched. Updates EDIT_CONFIG directly (see _editor_add_vm).
_editor_edit_vm() {
    local vm="$1" slice label old
    local -a targets=() known=()
    slice="$(_editor_slice "$EDIT_CONFIG" "$vm")"
    mapfile -t known < <(_link_targets "$EDIT_CONFIG" "$vm")
    _editor_seed "$slice"
    label="$(_editor_vm_label "$vm")"
    if _editor_run_pass "$label"; then
        EDIT_CONFIG="$(_editor_set_vm_slice "$EDIT_CONFIG" "$vm" "$PASS_CONFIG")"
        _editor_prune_links
        # the models that were not there before are asked where they are shown
        while IFS= read -r old; do
            [[ -n "$old" ]] || continue
            [[ " ${known[*]} " == *"$old"* ]] || targets+=("$old")
        done < <(_link_targets "$EDIT_CONFIG" "$vm")
        _editor_ask_links "${targets[@]}"
    else
        log_info "unchanged"
    fi
}

# _editor_redo_models <vm>: `m <vm>`, redo its models only, keeping its components, each with where
# it is shown. Updates EDIT_CONFIG directly (never called through "$(...)").
_editor_redo_models() {
    local vm="$1" slice
    local -a targets=()
    slice="$(_editor_slice "$EDIT_CONFIG" "$vm")"
    _editor_seed "$slice"
    if [[ -z "${SEL[engine]:-}" ]]; then
        log_warn "VM $(_editor_vm_label "$vm") has no engine, nothing to size models for"
        return 0
    fi
    PASS_VM="$vm"
    step_models
    PASS_CONFIG="$(session_config)"
    print_summary "$PASS_CONFIG"
    _read "Confirm (y) or cancel (n)" y
    if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
        EDIT_CONFIG="$(_editor_set_vm_slice "$EDIT_CONFIG" "$vm" "$PASS_CONFIG")"
        _editor_prune_links
        mapfile -t targets < <(_link_targets "$EDIT_CONFIG" "$vm")
        _editor_ask_links "${targets[@]}"
    else
        log_info "unchanged"
    fi
}

# _editor_redo_links: `l`, the question of where each model is shown again, for every model, the
# current link offered as the default. Updates EDIT_CONFIG directly.
_editor_redo_links() {
    local -a targets=()
    mapfile -t targets < <(_link_targets "$EDIT_CONFIG")
    ((${#targets[@]})) || { log_warn "no model to show"; return 0; }
    _editor_ask_links "${targets[@]}"
}

# _editor_rename_vm <config> <old> <new>: `n <vm>`, the VM and the references of the links that
# designate it follow.
_editor_rename_vm() {
    jq -c --arg o "$2" --arg n "$3" '
        .vms |= map(if .name == $o then .name = $n else . end)
        | (if has("links") then .links |= map(
             (if .model.vm_ref == $o then .model.vm_ref = $n else . end)
             | (if .chat_interface.vm_ref == $o then .chat_interface.vm_ref = $n else . end)) else . end)' <<<"$1"
}

# _editor_remove_vm <config> <vm>: `r <vm>`, its components, its models and the links whose model or
# chat interface was on it; the last VM is refused by the caller before this runs.
_editor_remove_vm() {
    jq -c --arg v "$2" '
        .vms |= map(select(.name != $v))
        | (if has("links") then .links |= map(select(.model.vm_ref != $v and .chat_interface.vm_ref != $v)) else . end)
        | (if (.links // []) == [] then del(.links) else . end)' <<<"$1"
}

# _editor_set_path <path> <json>: the value at a path of the display form ("$.vms[0].name").
_editor_set_path() {
    EDIT_CONFIG="$(jq -c --arg p "$1" --argjson v "$2" '
        ($p | ltrimstr("$") | [match("\\.([^.\\[]+)|\\[([0-9]+)\\]"; "g") | if .captures[0].string != null then .captures[0].string else (.captures[1].string | tonumber) end]) as $path
        | setpath($path; $v)' <<<"$EDIT_CONFIG")"
}

# _editor_del_path <path>: remove what is at a path of the display form.
_editor_del_path() {
    EDIT_CONFIG="$(jq -c --arg p "$1" '
        ($p | ltrimstr("$") | [match("\\.([^.\\[]+)|\\[([0-9]+)\\]"; "g") | if .captures[0].string != null then .captures[0].string else (.captures[1].string | tonumber) end]) as $path
        | delpaths([$path])' <<<"$EDIT_CONFIG")"
}

# _editor_reask_option <path>: re-asks one option directly ("$.vms[N].components[M].options.OPT"),
# its current value as the default; used for an option outside its values and for
# duplicate_server_name. Returns 1 when the path is not that shape.
_editor_reask_option() {
    local path="$1" vi ci opt type name comp oname default secret descr cur
    [[ "$path" =~ ^\$\.vms\[([0-9]+)\]\.components\[([0-9]+)\]\.options\.(.+)$ ]] || return 1
    vi="${BASH_REMATCH[1]}"
    ci="${BASH_REMATCH[2]}"
    opt="${BASH_REMATCH[3]}"
    comp="$(jq -r ".vms[$vi].components[$ci].component // empty" <<<"$EDIT_CONFIG")"
    [[ "$comp" == */* ]] || return 1
    type="${comp%%/*}"
    name="${comp#*/}"
    _describe_of "$type" "$name"
    while IFS=$'\x1f' read -r oname default secret descr <&3; do
        [[ "$oname" == "$opt" ]] || continue
        cur="$(jq -r --argjson i "$vi" --argjson j "$ci" --arg k "$opt" '.vms[$i].components[$j].options[$k] // empty' <<<"$EDIT_CONFIG")"
        [[ -n "$cur" ]] || cur="$default"
        printf '  %s\n' "$descr" >&2
        _read "$name --$oname" "$cur"
        if [[ "$REPLY" == "$default" ]]; then
            EDIT_CONFIG="$(jq -c --argjson i "$vi" --argjson j "$ci" --arg k "$opt" '
                .vms[$i].components[$j].options |= ((. // {}) | del(.[$k]))' <<<"$EDIT_CONFIG")"
        else
            EDIT_CONFIG="$(jq -c --argjson i "$vi" --argjson j "$ci" --arg k "$opt" --arg v "$REPLY" '
                .vms[$i].components[$j].options |= ((. // {}) + {($k): $v})' <<<"$EDIT_CONFIG")"
        fi
        return 0
    done 3< <(jq -r '.options[]? | [.name, (.default // ""), (.secret // false | tostring), (.description // "")] | join("\u001f")' <<<"${DESC[$name]}")
    return 1
}

# _editor_reask_requirement <vm> <message>: `missing_requirement` proposes the component that is
# missing ("Add <proxy>? (y/n)", then its options, docs/spec-multi-vm.md#editing). Returns 1 when
# the message names neither a proxy nor a provisioning component.
_editor_reask_requirement() {
    local vm="$1" msg="$2" type names rank slice
    if [[ "$msg" == *"needs a proxy"* ]]; then
        type=proxy
    elif [[ "$msg" == *"provisioning component"* ]]; then
        type=provisioning
    else
        return 1
    fi
    names="$(component_names "$type" | tr '\n' ' ')"
    if [[ -z "${names// /}" ]]; then
        log_warn "this package ships no $type"
        return 0
    fi
    _read "Add a $type on VM $(_editor_vm_label "$vm")? (y/n)" y
    [[ "$REPLY" == y || "$REPLY" == Y ]] || return 0
    slice="$(_editor_slice "$EDIT_CONFIG" "$vm")"
    _editor_seed "$slice"
    rank="$(rank_lookup "$type")"
    [[ " $names " == *" $rank "* ]] || rank="${names%% *}"
    while :; do
        _read "$type (${names% })" "$rank"
        if [[ " $names " == *" $REPLY "* ]]; then
            SEL[$type]="$REPLY"
            break
        fi
        log_warn "'$REPLY' is not one of: $names"
    done
    step_options_edit "$type"
    PASS_VM="$vm"
    PASS_CONFIG="$(session_config)"
    EDIT_CONFIG="$(_editor_set_vm_slice "$EDIT_CONFIG" "$vm" "$PASS_CONFIG")"
}

# _editor_fix_link <index>: a link that does not resolve or is incomplete: where that model is shown
# is asked again when the model it designates can be found, else the link is offered for removal.
_editor_fix_link() {
    local i="$1" vm engine model
    read -r vm engine model < <(jq -r --argjson i "$i" '
        .links[$i] as $l | (first(.vms[]? | select(.name == $l.model.vm_ref)) // null) as $v
        | (first(($v.components // [])[] | select(.name == $l.model.component_ref and (.component | startswith("engine/"))) ) // null) as $en
        | (first(($en.models // [])[]? | select((.name // .model) == $l.model.model_ref)) // null) as $m
        | if $en != null and $m != null then "\($v.name) \($en.component | split("/")[1]) \($m.model)" else "" end' <<<"$EDIT_CONFIG" 2>/dev/null || true)
    if [[ -n "$model" ]]; then
        _editor_del_path "\$.links[$i]"
        EDIT_CONFIG="$(jq -c 'if (.links // []) == [] then del(.links) else . end' <<<"$EDIT_CONFIG")"
        _editor_ask_links "$(printf '%s\t%s\t%s' "$vm" "$engine" "$model")"
    else
        _read "Remove this link? (y/n)" y
        if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
            _editor_del_path "\$.links[$i]"
            EDIT_CONFIG="$(jq -c 'if (.links // []) == [] then del(.links) else . end' <<<"$EDIT_CONFIG")"
        fi
    fi
}

# _editor_fix: `f`, one pass over the errors EDIT_ERRORS held at the time it was chosen
# (docs/spec-multi-vm.md#editing). Each kind of error is handled the way the spec lists. Before
# showing an error, it is checked against the current configuration: one an earlier fix in this same
# pass already resolved is skipped silently. Updates EDIT_CONFIG directly.
_editor_fix() {
    local errors="$EDIT_ERRORS" i=0 err code path vm msg still li
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
        unknown_key | unknown_option)
            _read "Remove this entry? (y/n)" y
            [[ "$REPLY" != y && "$REPLY" != Y ]] || _editor_del_path "$path"
            ;;
        unknown_component | unknown_type)
            _read "Remove this component? (y/n)" y
            [[ "$REPLY" != y && "$REPLY" != Y ]] || { _editor_del_path "${path%.component}"; _editor_prune_links; }
            ;;
        models_on_non_engine)
            _read "Remove the models of this component? (y/n)" y
            [[ "$REPLY" != y && "$REPLY" != Y ]] || { _editor_del_path "$path"; _editor_prune_links; }
            ;;
        invalid_value | wrong_type | duplicate_server_name | missing_option)
            _editor_reask_option "$path" || {
                _read "Edit VM $(_editor_vm_label "$vm") now to fix this? (y/n)" y
                [[ "$REPLY" != y && "$REPLY" != Y || -z "$vm" ]] || _editor_edit_vm "$vm"
            }
            ;;
        missing_requirement)
            _editor_reask_requirement "$vm" "$msg" || {
                if [[ -n "$vm" ]]; then
                    _read "Edit VM $vm now to fix this? (y/n)" y
                    [[ "$REPLY" != y && "$REPLY" != Y ]] || _editor_edit_vm "$vm"
                else
                    log_warn "fix it by hand, or with e/m/l/n/r"
                fi
            }
            ;;
        missing_vm_name | duplicate_vm | duplicate_name)
            local target="$path" old
            [[ "$target" == *.name ]] || target="$path.name"
            old="$(jq -r --arg p "$target" '
                ($p | ltrimstr("$") | [match("\\.([^.\\[]+)|\\[([0-9]+)\\]"; "g") | if .captures[0].string != null then .captures[0].string else (.captures[1].string | tonumber) end]) as $path
                | getpath($path) // empty' <<<"$EDIT_CONFIG")"
            mapfile -t VM_NAMES < <(apply_vms "$EDIT_CONFIG")
            _read "Name" "${old:+$old-2}"
            if _vm_ok "$REPLY"; then
                _editor_set_path "$target" "$(jq -Rn --arg v "$REPLY" '$v')"
            else
                log_warn "'$REPLY' is not lowercase letters, digits and dashes, starting with a letter"
            fi
            ;;
        several_defaults)
            _read "Remove the default from this component? (y/n)" y
            [[ "$REPLY" != y && "$REPLY" != Y ]] || _editor_del_path "$path"
            ;;
        duplicate_link | unsupported_count)
            _read "Remove this link? (y/n)" y
            if [[ "$REPLY" == y || "$REPLY" == Y ]]; then
                _editor_del_path "$path"
                EDIT_CONFIG="$(jq -c 'if (.links // []) == [] then del(.links) else . end' <<<"$EDIT_CONFIG")"
            fi
            ;;
        missing_key | unknown_vm | unresolved_engine | unresolved_model | unresolved_chat_interface | protected_engine_other_vm)
            if [[ "$path" =~ ^\$\.links\[([0-9]+)\] ]]; then
                li="${BASH_REMATCH[1]}"
                _editor_fix_link "$li"
            elif [[ -n "$vm" ]]; then
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
    if (($(jq '.vms | length' <<<"$EDIT_CONFIG") <= 1)); then
        log_warn "the last VM cannot be removed"
    else
        EDIT_CONFIG="$(_editor_remove_vm "$EDIT_CONFIG" "$1")"
    fi
}
