#!/usr/bin/env bash
# `add` and `remove` of the easy-cs-ai CLI, see docs/spec-cli.md. Sourced by
# package/bin/easy-cs-ai, which provides fail, need_root, run_script, slug,
# is_installed, install_one, rank_lookup, rank_one, GFLAGS and DRY.

INTERRUPTED=0

# --- Engine state accessors ---------------------------------------------------------

has_model() { state_read "$1" | jq -e --arg m "$2" '(.models // []) | any(.name == $m)' >/dev/null; }

# model_field <engine> <model> <jq-expression on the model entry>
model_field() { state_read "$1" | jq -r --arg m "$2" "(.models // [])[] | select(.name == \$m) | $3 // empty"; }

# model_url <engine> <model>: where the engine serves the model internally.
model_url() {
    state_read "$1" | jq -r --arg m "$2" '
        ([(.models // [])[] | select(.name == $m and .port != null) | "http://127.0.0.1:\(.port)"][0]) // .endpoint.url // empty'
}

# model_base_url <engine> <model>: the OpenAI base URL of the model on this
# machine, which the chat interface uses (it shares the machine with the engine,
# so the link needs neither HTTPS nor an API key, see docs/spec-cli.md, step 4).
model_base_url() {
    state_read "$1" | jq -r --arg m "$2" '
        ([(.models // [])[] | select(.name == $m and .port != null) | "http://127.0.0.1:\(.port)/v1"][0]) // .endpoint.openai_base_url // empty'
}

# add_wiring <engine> <model> <proxy-or-empty> <chat-or-empty>: record the
# relations in the engine state (the one place the CLI writes a component state).
add_wiring() {
    state_write "$1" "$(state_read "$1" | jq --arg m "$2" --arg p "$3" --arg c "$4" '{
        name: .name, type: .type,
        models: ((.models // []) | map(if .name == $m then
            (if $p != "" then .exposed_via = $p else . end)
            | .linked_to = ((.linked_to // []) + (if $c != "" and (((.linked_to // []) | index($c)) == null) then [$c] else [] end))
          else . end))}')"
}

# drop_wiring <engine> <model> proxy|chat <name>
drop_wiring() {
    state_write "$1" "$(state_read "$1" | jq --arg m "$2" --arg k "$3" --arg n "$4" '{
        name: .name, type: .type,
        models: ((.models // []) | map(if .name == $m then
            (if $k == "proxy" then .exposed_via = null else .linked_to = ((.linked_to // []) | map(select(. != $n))) end)
          else . end))}')"
}

# step <command…>: run a step; an interruption counts as a failure.
step() {
    local rc=0
    "$@" || rc=$?
    if ((rc == 0 && INTERRUPTED)); then
        rc=$INTERRUPTED
    fi
    return "$rc"
}

watch_signals() {
    INTERRUPTED=0
    trap 'INTERRUPTED=130' INT
    trap 'INTERRUPTED=143' TERM
}

# single_or_default <type> <explicit-name> <what>: the component to use.
single_or_default() {
    local type="$1" explicit="$2" names count
    if [[ -n "$explicit" ]]; then
        if [[ "$(state_read "$explicit" 2>/dev/null | jq -r '.type // empty')" != "$type" ]]; then
            fail "$EXIT_PRECONDITION" "$type '$explicit' is not installed"
        fi
        printf '%s\n' "$explicit"
        return 0
    fi
    names="$(state_list "$type")"
    count="$(grep -c . <<<"$names" || true)"
    if ((count == 0)); then
        return 1
    fi
    defaults_get "$type" 2>/dev/null && return 0
    if ((count == 1)); then
        printf '%s\n' "$names"
        return 0
    fi
    fail "$EXIT_PRECONDITION" "several ${type}s installed and none is the default: $(tr '\n' ' ' <<<"$names")" "use --$type <name>"
}

# --- add --------------------------------------------------------------------------------

A_MODEL="" A_ENGINE="" A_CHAT="" A_PROXY="" A_FORCE=0 A_FIT=""

# add_resolve <explicit-engine> <explicit-chat> <no-chat> <defaults>
add_resolve() {
    local want_engine="$1" want_chat="$2" no_chat="$3" defaults="$4" missing=() need_proxy=0 item
    A_ENGINE="$(single_or_default engine "$want_engine")" ||
        fail "$EXIT_PRECONDITION" "no engine installed" "install an engine first: easy-cs-ai install engine $(rank_one engine)"
    A_CHAT=""
    if ((!no_chat)); then
        if A_CHAT="$(single_or_default chat-interface "$want_chat")"; then
            :
        else
            A_CHAT=""
            [[ -z "$want_chat" ]] && log_info "no chat interface installed, the model is not linked to one"
        fi
    fi
    if [[ "$(state_read "$A_ENGINE" | jq -r '.endpoint.protected // false')" != true ]]; then
        need_proxy=1
        if ! A_PROXY="$(single_or_default proxy "")"; then
            A_PROXY="$(rank_one proxy)"
            missing+=("proxy $A_PROXY")
        fi
    else
        A_PROXY=""
    fi
    A_FIT=""
    if ((!A_FORCE)); then
        if ! A_FIT="$(single_or_default provisioning "")"; then
            A_FIT="$(rank_one provisioning)"
            missing+=("provisioning $A_FIT")
        fi
    fi
    for item in "${missing[@]}"; do
        if ((!defaults)); then
            fail "$EXIT_PRECONDITION" "${item#* } is required to add a model" "easy-cs-ai install $item"
        fi
        if ((!DRY)); then
            # shellcheck disable=SC2086
            log_info "installing ${item#* } (required by add)"
            # shellcheck disable=SC2086
            install_one $item 1 || fail "$?" "could not install ${item#* }"
        fi
    done
    log_info "plan: add $A_MODEL to $A_ENGINE$( ((need_proxy)) && printf ', expose through %s' "$A_PROXY")$([[ -n "$A_CHAT" ]] && printf ', link to %s' "$A_CHAT")$( ((A_FORCE)) && printf ' (fit check skipped)')"
}

add_rollback() {
    local upstream="$1" did2="$2" did3="$3" did4="$4" left=()
    if ((did4)); then
        run_script chat-interface "$A_CHAT" remove-endpoint "$upstream" || left+=("chat endpoint $upstream")
    fi
    if ((did3)); then
        run_script proxy "$A_PROXY" remove-upstream "$upstream" || left+=("proxy upstream $upstream")
    fi
    if ((did2)); then
        run_script engine "$A_ENGINE" remove-model "$A_MODEL" || left+=("engine model $A_MODEL")
    fi
    if ((${#left[@]})); then
        log_error "could not undo: ${left[*]}"
        return 7
    fi
    return 0
}

add_steps() {
    local did2=0 did3=0 did4=0 rc=0 out upstream url="" before_proxy before_chat
    upstream="$A_ENGINE-$(slug "$A_MODEL")"
    watch_signals

    # 1. fit check
    if ((A_FORCE)); then
        log_warn "fit check skipped (--force)"
    elif ! has_model "$A_ENGINE" "$A_MODEL"; then
        out="$(step run_script provisioning "$A_FIT" check "$A_MODEL")" || return "$?"
        if [[ "$(jq -r '.fits' <<<"$out")" != true ]]; then
            log_error "$A_MODEL does not fit this machine: $(jq -r '.reason // "no reason given"' <<<"$out")"
            return "$EXIT_PRECONDITION"
        fi
    fi

    # 2. engine
    if ! has_model "$A_ENGINE" "$A_MODEL"; then
        step run_script engine "$A_ENGINE" add-model "$A_MODEL" || return "$?"
        did2=1
    fi
    before_proxy="$(model_field "$A_ENGINE" "$A_MODEL" .exposed_via)"
    before_chat="$(model_field "$A_ENGINE" "$A_MODEL" '(.linked_to // []) | index("'"$A_CHAT"'")')"

    # 3. proxy: the access from outside the machine, independent of step 4.
    if [[ -n "$A_PROXY" && -z "$before_proxy" ]]; then
        step run_script proxy "$A_PROXY" add-upstream "$upstream" "$(model_url "$A_ENGINE" "$A_MODEL")" >/dev/null || rc=$?
        if ((rc)); then
            ((did2)) && add_rollback "$upstream" "$did2" 0 0
            return "$rc"
        fi
        did3=1
    fi

    # 4. chat interface: linked to the internal URL of the engine, not to the proxy.
    if [[ -n "$A_CHAT" && -z "$before_chat" ]]; then
        url="$(model_base_url "$A_ENGINE" "$A_MODEL")"
        step run_script chat-interface "$A_CHAT" add-endpoint "$upstream" "$url" >/dev/null || rc=$?
        if ((rc)); then
            add_rollback "$upstream" "$did2" "$did3" 0 || return "$?"
            return "$rc"
        fi
        did4=1
    fi

    # 5. record the wiring
    if ((did3 || did4)); then
        (add_wiring "$A_ENGINE" "$A_MODEL" "$([[ $did3 == 1 ]] && printf '%s' "$A_PROXY")" "$([[ $did4 == 1 ]] && printf '%s' "$A_CHAT")") || rc=$?
        if ((rc)); then
            add_rollback "$upstream" "$did2" "$did3" "$did4" || return "$?"
            return "$rc"
        fi
    fi
    if ((INTERRUPTED)); then
        add_rollback "$upstream" "$did2" "$did3" "$did4" || return "$?"
        return "$INTERRUPTED"
    fi
    if ((!did2 && !did3 && !did4)); then
        log_info "$A_MODEL: already added"
    else
        log_info "$A_MODEL is added to $A_ENGINE"
    fi
}

cmd_add() {
    local engine="" chat="" no_chat=0 defaults=0 arg start=$SECONDS rc=0
    A_MODEL="" A_FORCE=0
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
        --engine | --chat-interface)
            [[ $# -gt 0 ]] || fail "$EXIT_USAGE" "$arg needs a value"
            if [[ "$arg" == --engine ]]; then engine="$1"; else chat="$1"; fi
            shift
            ;;
        --no-chat-interface) no_chat=1 ;;
        --defaults) defaults=1 ;;
        --force) A_FORCE=1 ;;
        -*) fail "$EXIT_USAGE" "unknown option: $arg" ;;
        *) [[ -z "$A_MODEL" ]] || fail "$EXIT_USAGE" "one model at a time"; A_MODEL="$arg" ;;
        esac
    done
    [[ -n "$A_MODEL" ]] || fail "$EXIT_USAGE" "add needs a model name" "easy-cs-ai add <model>"
    ((DRY)) || need_root add "$A_MODEL"
    add_resolve "$engine" "$chat" "$no_chat" "$defaults"
    if ((DRY)); then
        return 0
    fi
    log_event "add start model=$A_MODEL engine=$A_ENGINE chat_interface=${A_CHAT:-none}"
    add_steps || rc=$?
    log_event "add end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}

# --- remove -----------------------------------------------------------------------------

# remove_resolve <model> <explicit-engine>: print the engine holding the model.
remove_resolve() {
    local model="$1" explicit="$2" e found=()
    if [[ -n "$explicit" ]]; then
        single_or_default engine "$explicit" >/dev/null
        has_model "$explicit" "$model" ||
            fail "$EXIT_PRECONDITION" "model $model not found on $explicit" "known: $(state_read "$explicit" | jq -r '[.models[]?.name] | join(" ")')"
        printf '%s\n' "$explicit"
        return 0
    fi
    for e in $(state_list engine); do
        has_model "$e" "$model" && found+=("$e")
    done
    if ((${#found[@]} == 0)); then
        local known=""
        for e in $(state_list engine); do known+="$(state_read "$e" | jq -r '[.models[]?.name] | join(" ")') "; done
        fail "$EXIT_PRECONDITION" "model $model not found" "known models: ${known:-none}"
    fi
    if ((${#found[@]} > 1)); then
        fail "$EXIT_PRECONDITION" "model $model is on several engines: ${found[*]}" "use --engine <name>"
    fi
    printf '%s\n' "${found[0]}"
}

# remove_model <engine> <model>: unwire, then delete. No rollback, resumable.
remove_model() {
    local engine="$1" model="$2" upstream via chat
    upstream="$engine-$(slug "$model")"
    while IFS= read -r chat; do
        [[ -n "$chat" ]] || continue
        if is_installed "$chat"; then
            step run_script chat-interface "$chat" remove-endpoint "$upstream" || return "$?"
        else
            log_warn "$chat is not installed, nothing to unlink"
        fi
        drop_wiring "$engine" "$model" chat "$chat"
    done < <(model_field "$engine" "$model" '(.linked_to // [])[]')
    via="$(model_field "$engine" "$model" .exposed_via)"
    if [[ -n "$via" ]]; then
        if is_installed "$via"; then
            step run_script proxy "$via" remove-upstream "$upstream" || return "$?"
        else
            log_warn "$via is not installed, nothing to unexpose"
        fi
        drop_wiring "$engine" "$model" proxy "$via"
    fi
    step run_script engine "$engine" remove-model "$model" || return "$?"
    log_info "$model is removed from $engine"
}

cmd_remove() {
    local model="" engine="" all=0 arg start=$SECONDS rc=0 e m
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
        --engine)
            [[ $# -gt 0 ]] || fail "$EXIT_USAGE" "--engine needs a value"
            engine="$1"
            shift
            ;;
        --all) all=1 ;;
        --defaults) fail "$EXIT_USAGE" "--defaults is not accepted by remove" ;;
        -*) fail "$EXIT_USAGE" "unknown option: $arg" ;;
        *) [[ -z "$model" ]] || fail "$EXIT_USAGE" "one model at a time"; model="$arg" ;;
        esac
    done
    if ((all)) && [[ -n "$model" ]]; then
        fail "$EXIT_USAGE" "--all cannot be combined with a model name"
    fi
    if ((!all)) && [[ -z "$model" ]]; then
        fail "$EXIT_USAGE" "remove needs a model name" "easy-cs-ai remove <model>, or easy-cs-ai remove --all"
    fi
    ((DRY)) || need_root remove "$@"
    watch_signals
    local pairs=()
    if ((all)); then
        for e in ${engine:-$(state_list engine)}; do
            while IFS= read -r m; do
                [[ -n "$m" ]] && pairs+=("$e"$'\t'"$m")
            done < <(state_read "$e" | jq -r '(.models // [])[].name')
        done
    else
        pairs+=("$(remove_resolve "$model" "$engine")"$'\t'"$model")
    fi
    local pair
    for pair in "${pairs[@]}"; do
        log_info "plan: remove ${pair#*$'\t'} from ${pair%%$'\t'*}"
    done
    if ((DRY)) || ((${#pairs[@]} == 0)); then
        return 0
    fi
    log_event "remove start model=${model:-all} engine=${engine:-any}"
    for pair in "${pairs[@]}"; do
        remove_model "${pair%%$'\t'*}" "${pair#*$'\t'}" || {
            rc=$?
            break
        }
        if ((INTERRUPTED)); then
            rc=$INTERRUPTED
            break
        fi
    done
    log_event "remove end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}
