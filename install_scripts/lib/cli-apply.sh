#!/usr/bin/env bash
# `apply` of the easy-cs-ai CLI, see docs/spec-config.md. Sourced by
# package/bin/easy-cs-ai, which provides fail, need_root, install_one,
# uninstall_one, uninstall_order, cmd_add, cmd_remove, is_type, is_installed,
# script_path, resolve_script and DRY.

readonly APPLY_SCHEMA_VERSION=1

# The validation program. Input: the configuration. Arguments: $desc (describe
# of every listed component, keyed "type/name"), $installed (installed
# component names by type), $reqs (also report the requirements nothing
# satisfies) and $hostids (the ids of this platform, [] to skip the platform
# check). Output: one {path, code, message} object per problem, see
# docs/spec-ai-interface.md for the codes.
# shellcheck disable=SC2016
readonly APPLY_VALIDATE_JQ='. as $cfg |
def types: ["engine", "chat-interface", "proxy", "provisioning"];
def e($p; $c; $m): {path: $p, code: $c, message: $m};
def only_keys($allowed; $p): to_entries[] | select(.key | IN($allowed[]) | not) | e("\($p).\(.key)"; "unknown_key"; "unknown key");
def listed($t): [(.components // [])[] | select(type == "object" and .type == $t) | .name];
def pick($t): (listed($t)) as $l
  | if ($l | length) == 1 then $l[0]
    else ([(.components // [])[] | select(type == "object" and .type == $t and .default == true) | .name][0]) end;
def known($t; $n): (($cfg | listed($t)) + ($installed[$t] // [])) | index($n) != null;
def satisfied($r): ((($cfg.components // []) | map(select(type == "object")) | any(.name == $r or .type == $r))
  or (([$installed[]?[]]) | index($r) != null) or (($installed[$r] // []) | length > 0));
def int_of($v): if ($v | type) == "number" and $v == ($v | floor) then $v
  elif ($v | type) == "string" and ($v | test("^-?[0-9]+$")) then ($v | tonumber) else null end;
def typed($o; $v): ($o.type // "string") as $t
  | if $t == "integer" then
      (int_of($v)) as $n
      | if $n == null or ($o.min != null and $n < $o.min) or ($o.max != null and $n > $o.max)
        then "an integer\(if $o.min != null and $o.max != null then " between \($o.min) and \($o.max)" elif $o.min != null then " of at least \($o.min)" elif $o.max != null then " of at most \($o.max)" else "" end) is expected"
        else empty end
    elif $t == "boolean" then (if ($v | type) == "boolean" or (($v | type) == "string" and ($v | IN("true", "false"))) then empty else "true or false is expected" end)
    elif $t == "enum" then (if ($v | tostring) | IN(($o.values // [])[]) then empty else "one of \(($o.values // []) | join(", ")) is expected" end)
    else empty end;

if type != "object" then e("$"; "wrong_type"; "an object is expected") else
  (only_keys(["schema_version", "components", "models"]; "$")),
  (if has("schema_version") | not then e("$.schema_version"; "wrong_type"; "required")
   elif (.schema_version | type) != "number" then e("$.schema_version"; "wrong_type"; "a number is expected")
   elif .schema_version > '"$APPLY_SCHEMA_VERSION"' then e("$.schema_version"; "unsupported_schema_version"; "\(.schema_version) is newer than the supported version '"$APPLY_SCHEMA_VERSION"'")
   else empty end),
  (if has("components") and (.components | type) != "array" then e("$.components"; "wrong_type"; "an array is expected") else empty end),
  (if has("models") and (.models | type) != "array" then e("$.models"; "wrong_type"; "an array is expected") else empty end),
  (if (.components | type) == "array" then
    (.components | to_entries[] | .key as $i | .value as $c | "$.components[\($i)]" as $p
     | if ($c | type) != "object" then e($p; "wrong_type"; "an object is expected") else
         ($c | only_keys(["type", "name", "default", "options"]; $p)),
         (if ($c.type | type) != "string" or ($c.type | IN(types[]) | not) then e("\($p).type"; "unknown_type"; "one of \(types | join(", ")) is expected")
          elif ($c.name | type) != "string" then e("\($p).name"; "wrong_type"; "a string is expected")
          elif $desc[$c.type + "/" + $c.name] == null then e("\($p).name"; "unknown_component"; "unknown \($c.type) \"\($c.name)\"")
          else
            $desc[$c.type + "/" + $c.name] as $d
            | ($d.options // []) as $opts
            | (if ($hostids | length) > 0 and (($d.platforms // []) | length) > 0 and ((($d.platforms // []) - (($d.platforms // []) - $hostids)) | length) == 0
               then e("\($p).name"; "unsupported_platform"; "\($c.name) supports \(($d.platforms) | join(", ")), this machine is \($hostids | join("/"))") else empty end),
              (if $reqs then ($d.requires // [])[] | . as $r | select(satisfied($r) | not)
                 | e($p; "missing_requirement"; "\($r) is required by \($c.name) and is neither installed nor in the file") else empty end),
              (($c.options // {}) | if type != "object" then e("\($p).options"; "wrong_type"; "an object is expected") else
                to_entries[] | .key as $k | .value as $v | ($opts | map(select(.name == $k))[0]) as $o
                | if $o == null then e("\($p).options.\($k)"; "unknown_option"; "unknown option (known: \($opts | map(.name) | join(", ")))")
                  elif $o.secret == true then
                    (if ($v | type) != "object" then e("\($p).options.\($k)"; "secret_literal"; "a secret is given as {\"file\": …}, {\"env\": …} or {\"generate\": true}, never as a plain value")
                     elif ($v | keys) == ["file"] and ($v.file | type) == "string" then empty
                     elif ($v | keys) == ["env"] and ($v.env | type) == "string" then empty
                     elif ($v | keys) == ["generate"] and $v.generate == true then empty
                     else e("\($p).options.\($k)"; "secret_source"; "exactly one of file, env or generate is expected") end)
                  elif ($v | type | IN("string", "number", "boolean") | not) then e("\($p).options.\($k)"; "wrong_type"; "a string, number or boolean is expected")
                  else (typed($o; $v) | e("\($p).options.\($k)"; "invalid_value"; .)) end
              end)
          end),
         (if ($c | has("default")) and ($c.default | type) != "boolean" then e("\($p).default"; "wrong_type"; "a boolean is expected") else empty end)
       end),
    ([.components[] | select(type == "object") | "\(.type)/\(.name)"] | group_by(.)[] | select(length > 1) | e("$.components"; "duplicate_component"; "\(.[0]) is listed more than once")),
    ([.components[] | select(type == "object" and .default == true) | .type] | group_by(.)[] | select(length > 1) | e("$.components"; "several_defaults"; "several defaults of type \(.[0])"))
   else empty end),
  (if (.models | type) == "array" then
    (.models | to_entries[] | .key as $i | .value as $m | "$.models[\($i)]" as $p
     | if ($m | type) != "object" then e($p; "wrong_type"; "an object is expected") else
         ($m | only_keys(["name", "engine", "chat_interface", "force"]; $p)),
         (if ($m.name | type) != "string" or $m.name == "" then e("\($p).name"; "wrong_type"; "a model name is expected") else empty end),
         (if ($m | has("force")) and ($m.force | type) != "boolean" then e("\($p).force"; "wrong_type"; "a boolean is expected") else empty end),
         (if ($m | has("engine")) then
            (if ($m.engine | type) != "string" or (known("engine"; $m.engine) | not) then e("\($p).engine"; "unresolved_engine"; "\"\($m.engine)\" is neither listed in components nor installed") else empty end)
          elif ($cfg | pick("engine")) == null then
            (if (($cfg | listed("engine")) | length) == 0 then e("\($p).engine"; "unresolved_engine"; "no engine is listed in components, name one")
             else e("\($p).engine"; "ambiguous_engine"; "several engines and none is the default, name one") end)
          else empty end),
         (if ($m | has("chat_interface")) then
            (if $m.chat_interface == null then empty
             elif ($m.chat_interface | type) != "string" or (known("chat-interface"; $m.chat_interface) | not) then e("\($p).chat_interface"; "unresolved_chat_interface"; "\"\($m.chat_interface)\" is neither listed in components nor installed")
             else empty end)
          elif (($cfg | listed("chat-interface")) | length) > 1 and ($cfg | pick("chat-interface")) == null then e("\($p).chat_interface"; "ambiguous_chat_interface"; "several chat interfaces and none is the default, name one or null")
          else empty end)
       end)
   else empty end)
end'

# apply_describes <config>: describe of every listed component that is shipped.
apply_describes() {
    local type name script out='{}' entry
    while IFS=$'\t' read -r type name; do
        [[ -n "$name" ]] || continue
        script="$(script_path "$type" "$name")"
        if is_type "$type" && [[ -f "$script" ]]; then
            entry="$(bash "$script" describe)" || fail "$?" "describe of $type $name failed"
            out="$(jq -c --arg k "$type/$name" --argjson e "$entry" '. + {($k): $e}' <<<"$out")"
        fi
    done < <(jq -r '(.components // []) | if type == "array" then .[] else empty end | select(type == "object" and (.type | type) == "string" and (.name | type) == "string") | [.type, .name] | @tsv' <<<"$1")
    printf '%s\n' "$out"
}

installed_by_type() {
    local t out='{}'
    if [[ -n "${EASY_CS_AI_ASSUME_EMPTY:-}" ]]; then
        printf '{}
'
        return 0
    fi
    for t in "${TYPES[@]}"; do
        out="$(jq -c --arg t "$t" --argjson l "$(state_list "$t" | jq -R . | jq -sc .)" '. + {($t): $l}' <<<"$out")"
    done
    printf '%s\n' "$out"
}

# apply_problems <config> <desc> [<reqs> [<hostids>]]: the problems as a JSON
# array of {path, code, message}. <reqs> (true or false, default false) also
# reports the requirements nothing satisfies, which `apply` and the generator
# check later with their own exit code (apply_order).
apply_problems() {
    jq -c --argjson desc "$2" --argjson installed "$(installed_by_type)" --argjson reqs "${3:-false}" \
        --argjson hostids "${4:-[]}" "$APPLY_VALIDATE_JQ" <<<"$1" | jq -sc .
}

# apply_validate <config> <desc>: print the problems, exit 2 when any.
apply_validate() {
    local problems line
    problems="$(apply_problems "$1" "$2" | jq -r '.[] | "\(.path): \(.message)"')"
    if [[ -n "$problems" ]]; then
        while IFS= read -r line; do log_error "$line"; done <<<"$problems"
        fail "$EXIT_USAGE" "the configuration is invalid"
    fi
}

# apply_order <config> <desc>: "type name" lines, requirements first. A
# requirement neither installed nor listed is exit 4.
apply_order() {
    local config="$1" desc="$2" pending=() placed=() line type name req ok progress i rtype
    while IFS= read -r line; do pending+=("$line"); done < <(jq -r '(.components // [])[] | "\(.type) \(.name)"' <<<"$config")
    reqs_of() { jq -r --arg k "$1/$2" '.[$k].requires[]?' <<<"$desc"; }
    # Fail early on a requirement that nothing satisfies.
    for line in "${pending[@]}"; do
        read -r type name <<<"$line"
        while IFS= read -r req; do
            [[ -n "$req" ]] || continue
            if is_installed "$req"; then continue; fi
            if jq -e --arg r "$req" '(.components // []) | any(.name == $r or .type == $r)' <<<"$config" >/dev/null; then continue; fi
            rtype="$req"
            is_type "$req" || rtype="$(type_of "$req" || printf '?')"
            fail "${APPLY_ORDER_FAIL_CODE:-$EXIT_PRECONDITION}" "$req is required by $name and is neither installed nor in the file" \
                "easy-cs-ai install $rtype $([[ "$rtype" == "$req" ]] && rank_lookup "$req" || printf '%s' "$req")"
        done < <(reqs_of "$type" "$name")
    done
    while ((${#pending[@]})); do
        progress=0
        for i in "${!pending[@]}"; do
            read -r type name <<<"${pending[$i]}"
            ok=1
            while IFS= read -r req; do
                [[ -n "$req" ]] || continue
                is_installed "$req" && continue
                # satisfied only once a listed component of that name/type is placed
                local found=0 p pt pn
                for p in "${placed[@]}"; do
                    read -r pt pn <<<"$p"
                    [[ "$pn" == "$req" || "$pt" == "$req" ]] && found=1
                done
                ((found)) || ok=0
            done < <(reqs_of "$type" "$name")
            if ((ok)); then
                placed+=("${pending[$i]}")
                unset "pending[$i]"
                pending=("${pending[@]}")
                progress=1
                break
            fi
        done
        ((progress)) || fail "$EXIT_ERROR" "the requirements of the listed components are circular"
    done
    printf '%s\n' "${placed[@]}"
}

# apply_install_args <config> <type> <name>: print the install arguments, one
# per line; secrets from the environment are exported by apply_export_secrets.
apply_install_args() {
    jq -r --arg t "$2" --arg n "$3" '
        (.components[] | select(.type == $t and .name == $n)) as $c
        | (if $c.default == true then ["--default"] else [] end)
          + [($c.options // {}) | to_entries[] | .key as $k | .value as $v
             | if ($v | type) == "object" then
                 (if $v.file then ["--\($k)-file", $v.file] else [] end)
               else ["--\($k)", ($v | tostring)] end | .[]]
        | .[]' <<<"$1"
}

# apply_export_secrets <config> <type> <name>: secrets given by environment
# variable reach the script through its own EASY_CS_AI_<COMPONENT>_<OPTION>.
apply_export_secrets() {
    local k src
    while IFS=$'\t' read -r k src; do
        [[ -n "$k" ]] || continue
        if [[ -z "${!src+x}" ]]; then
            fail "$EXIT_USAGE" "option $k of $3 reads the environment variable $src, which is not set"
        fi
        export "$(option_var "$3" "$k")=${!src}"
    done < <(jq -r --arg t "$2" --arg n "$3" '(.components[] | select(.type == $t and .name == $n) | (.options // {}) | to_entries[] | select((.value | type) == "object" and .value.env) | [.key, .value.env] | @tsv)' <<<"$1")
}

# apply_models <config>: "model<TAB>engine<TAB>chat-or-null<TAB>force" lines, resolved.
apply_models() {
    jq -r '
        def listed($t): [(.components // [])[] | select(.type == $t) | .name];
        def pick($t): (listed($t)) as $l
          | if ($l | length) == 1 then $l[0]
            else ([(.components // [])[] | select(.type == $t and .default == true) | .name][0]) end;
        . as $cfg | (.models // [])[]
        | [.name, (.engine // ($cfg | pick("engine"))),
           (if has("chat_interface") then (.chat_interface // "null") else (($cfg | pick("chat-interface")) // "null") end),
           (.force // false | tostring)] | @tsv' <<<"$1"
}

apply_prune() {
    local config="$1" t n m e
    local -A in_file=()
    while IFS= read -r n; do in_file["$n"]=1; done < <(jq -r '(.components // [])[] | .name' <<<"$config")
    # models of the listed engines that the file does not name
    for e in $(jq -r '(.components // [])[] | select(.type == "engine") | .name' <<<"$config"); do
        is_installed "$e" || continue
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            if ! jq -e --arg e "$e" --arg m "$m" '(.models // []) | any(.name == $m and (.engine // $e) == $e)' <<<"$config" >/dev/null; then
                log_info "prune: removing model $m from $e"
                (cmd_remove "$m" --engine "$e") || fail "$?" "apply: prune of model $m failed"
            fi
        done < <(state_read "$e" | jq -r '(.models // [])[].name')
    done
    while read -r t n; do
        [[ -n "$n" && -z "${in_file[$n]:-}" ]] || continue
        log_info "prune: uninstalling $t $n"
        uninstall_one "$t" "$n" || fail "$?" "apply: prune of $t $n failed"
    done < <(uninstall_order "")
}

cmd_apply() {
    local source="" prune=0 arg config desc order line type name start=$SECONDS rc=0 model engine chat force
    for arg in "$@"; do
        case "$arg" in
        --prune) prune=1 ;;
        -) source="-" ;;
        -*) fail "$EXIT_USAGE" "unknown option: $arg" ;;
        *) [[ -z "$source" ]] || fail "$EXIT_USAGE" "one configuration file at a time"; source="$arg" ;;
        esac
    done
    [[ -n "$source" ]] || fail "$EXIT_USAGE" "apply needs a configuration file" "easy-cs-ai apply <file|->"
    read_config "$source"
    config="$CONFIG_TEXT"
    if ((DRY && _OPT_JSON)); then
        # the document of `config validate --target this`; a requirement nothing satisfies keeps the exit code 4
        local doc
        if ((CONFIG_NOT_JSON)); then
            doc="$(not_json_document this)"
        else
            doc="$(config_report "$config" this "$( ((prune)) && printf true || printf false)")"
        fi
        printf '%s\n' "$doc"
        return "$(config_exit_code "$doc" "$EXIT_PRECONDITION")"
    fi
    ((!CONFIG_NOT_JSON)) || fail "$EXIT_USAGE" "the configuration is not valid JSON"
    desc="$(apply_describes "$config")"
    apply_validate "$config" "$desc"
    order="$(apply_order "$config" "$desc")"
    ((DRY)) || need_root apply "$source"
    local models
    models="$(apply_models "$config")"
    if ((DRY)); then
        while read -r type name; do
            [[ -n "$name" ]] && log_info "plan: install $type $name $(apply_install_args "$config" "$type" "$name" | tr '\n' ' ')"
        done <<<"$order"
        while IFS=$'\t' read -r model engine chat force; do
            [[ -n "$model" ]] && log_info "plan: add $model to $engine (chat interface: $chat)"
        done <<<"$models"
        ((prune)) && log_info "plan: prune what the file does not name"
        while IFS= read -r line; do
            log_warn "$line"
        done < <(jq -r --argjson desc "$desc" "$CONFIG_WARNINGS_JQ | .[] | \"\\(.component.name) --\\(.option)=\\(.value): \\(.message)\"" <<<"$config")
        return 0
    fi
    log_event "apply start components=$(jq '(.components // []) | length' <<<"$config") models=$(jq '(.models // []) | length' <<<"$config") prune=$( ((prune)) && printf true || printf false)"
    while read -r type name; do
        [[ -n "$name" ]] || continue
        local args=()
        mapfile -t args < <(apply_install_args "$config" "$type" "$name")
        (
            apply_export_secrets "$config" "$type" "$name"
            install_one "$type" "$name" 0 "${args[@]}"
        ) || {
            rc=$?
            log_error "apply: install $type $name failed (exit $rc)"
            break
        }
    done <<<"$order"
    if ((rc == 0)); then
        while IFS=$'\t' read -r model engine chat force; do
            [[ -n "$model" ]] || continue
            local add_args=("$model" --engine "$engine")
            if [[ "$chat" == null ]]; then add_args+=(--no-chat-interface); else add_args+=(--chat-interface "$chat"); fi
            [[ "$force" == true ]] && add_args+=(--force)
            (cmd_add "${add_args[@]}") || {
                rc=$?
                log_error "apply: add $model failed (exit $rc)"
                break
            }
        done <<<"$models"
    fi
    if ((rc == 0 && prune)); then
        (apply_prune "$config") || rc=$?
    fi
    log_event "apply end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}
