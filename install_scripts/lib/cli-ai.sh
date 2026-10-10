#!/usr/bin/env bash
# The machine interface of the CLI (catalog, host, config, guide, result
# documents), see docs/spec-ai-interface.md. Sourced by package/bin/easy-cs-ai,
# and by vm_script/generate.sh for config_report. Needs common.sh, cli-base.sh
# and cli-apply.sh. With --json (_OPT_JSON) stdout is exactly one JSON
# document; without it the output is for humans.

readonly AI_SCHEMA_VERSION=1

# --- host ---------------------------------------------------------------------------

# _num_or_null <text>: the text when it is an integer, else null.
_num_or_null() { [[ "${1:-}" =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf null; }

# _str_or_null <text>: the text as a JSON string, null when empty.
_str_or_null() { [[ -n "${1:-}" ]] && jq -n --arg v "$1" '$v' || printf null; }

# host_ids_json: the ids of this platform (ID and ID_LIKE of os-release, lower
# case), [] when unknown or in test mode, where the platform is not checked.
# EASY_CS_AI_HOST_IDS (space separated) replaces the detection, for the tests.
host_ids_json() {
    local osr
    if [[ -n "${EASY_CS_AI_HOST_IDS:-}" ]]; then
        # shellcheck disable=SC2086
        printf '%s\n' $EASY_CS_AI_HOST_IDS | jq -R . | jq -sc .
        return 0
    fi
    if is_test_root; then
        printf '[]\n'
        return 0
    fi
    osr="$(root_path /etc/os-release)"
    [[ -r "$osr" ]] || {
        printf '[]\n'
        return 0
    }
    { sed -n 's/^ID=//p;s/^ID_LIKE=//p' "$osr" | tr -d '"' | tr ' ' '\n' | tr '[:upper:]' '[:lower:]' | grep . || true; } |
        jq -R . | jq -sc 'unique'
}

# host_gpus_json: GPUs as [{vendor, name, vram_mb}], [] when none is found.
host_gpus_json() {
    local line name mem vendor out='[]'
    if command -v nvidia-smi >/dev/null 2>&1; then
        while IFS=, read -r name mem; do
            name="${name#"${name%%[![:space:]]*}"}"
            mem="${mem//[[:space:]]/}"
            [[ -n "$name" ]] || continue
            out="$(jq -c --arg n "$name" --argjson m "$(_num_or_null "$mem")" '. + [{vendor: "nvidia", name: $n, vram_mb: $m}]' <<<"$out")"
        done < <(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || true)
        if [[ "$out" != '[]' ]]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    if command -v lspci >/dev/null 2>&1; then
        while IFS= read -r line; do
            name="${line#*: }"
            case "${name,,}" in
            *nvidia*) vendor=nvidia ;; *amd* | *radeon* | *advanced\ micro*) vendor=amd ;; *intel*) vendor=intel ;; *) vendor=other ;;
            esac
            out="$(jq -c --arg n "$name" --arg v "$vendor" '. + [{vendor: $v, name: $n, vram_mb: null}]' <<<"$out")"
        done < <(lspci 2>/dev/null | grep -E 'VGA compatible|3D controller|Display controller' || true)
    fi
    printf '%s\n' "$out"
}

# host_json: the facts of this machine. What cannot be read is null, never guessed.
host_json() {
    local osr id="" id_like="" ver="" cores="" cpu_model="" ram="" free="" path systemd=false docker=false root=false
    osr="$(root_path /etc/os-release)"
    if [[ -r "$osr" ]]; then
        id="$(sed -n 's/^ID=//p' "$osr" | tr -d '"')"
        id_like="$(sed -n 's/^ID_LIKE=//p' "$osr" | tr -d '"')"
        ver="$(sed -n 's/^VERSION_ID=//p' "$osr" | tr -d '"')"
    fi
    if [[ -r "$(root_path /proc/cpuinfo)" ]]; then
        cores="$(grep -c '^processor' "$(root_path /proc/cpuinfo)" || true)"
        [[ "$cores" != 0 ]] || cores=""
        cpu_model="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "$(root_path /proc/cpuinfo)" | head -n 1)"
    fi
    if [[ -r "$(root_path /proc/meminfo)" ]]; then
        ram="$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' "$(root_path /proc/meminfo)")"
    fi
    path="$(state_dir)"
    while [[ ! -d "$path" && "$path" != / ]]; do path="$(dirname "$path")"; done
    free="$(df -Pm "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')" || free=""
    [[ -d "$(root_path /run/systemd/system)" ]] && systemd=true
    command -v docker >/dev/null 2>&1 && docker=true
    ((EUID == 0)) && root=true
    jq -nc --argjson sv "$AI_SCHEMA_VERSION" --arg id "$id" --arg like "$id_like" --arg ver "$ver" --arg arch "$(uname -m)" \
        --argjson systemd "$systemd" --argjson cores "$(_num_or_null "$cores")" --argjson cpu "$(_str_or_null "$cpu_model")" \
        --argjson ram "$(_num_or_null "$ram")" --arg path "$(logical_state_dir)" --argjson free "$(_num_or_null "$free")" \
        --argjson gpus "$(host_gpus_json)" --argjson root "$root" --argjson docker "$docker" '{
        schema_version: $sv,
        platform: { id: (if $id == "" then null else $id end), id_like: (if $like == "" then null else $like end),
                    version: (if $ver == "" then null else $ver end), arch: $arch, systemd: $systemd },
        cpu: { cores: $cores, model: $cpu },
        ram_mb: $ram,
        disk: { path: $path, free_mb: $free },
        gpus: $gpus,
        root: $root,
        docker: { installed: $docker }
      }'
}

# logical_state_dir: the data directory as the machine sees it.
logical_state_dir() { printf '%s\n' "${EASY_CS_AI_STATE_DIR:-/var/lib/easy-cs-ai}"; }

cmd_host() {
    local arg json
    for arg in "$@"; do
        fail "$EXIT_USAGE" "host takes no argument (got '$arg')"
    done
    json="$(host_json)"
    if ((_OPT_JSON)); then
        printf '%s\n' "$json"
        return 0
    fi
    jq -r '"platform: \(.platform.id // "unknown") \(.platform.version // "") (\(.platform.arch)), systemd: \(.platform.systemd)",
        "cpu:      \(.cpu.cores // "unknown") cores \(.cpu.model // "")",
        "memory:   \(.ram_mb // "unknown") MB",
        "disk:     \(.disk.free_mb // "unknown") MB free under \(.disk.path)",
        "gpu:      \(if (.gpus | length) == 0 then "none found" else (.gpus | map("\(.name) (\(.vram_mb // "?") MB)") | join(", ")) end)",
        "docker:   \(if .docker.installed then "installed" else "not installed" end)",
        "root:     \(.root)"' <<<"$json"
}

# --- catalog ------------------------------------------------------------------------

# rank_of <type> <name>: the position in ranks.conf among the components of the type
# that are shipped (a ranked component without a script does not count), empty when unranked.
rank_of() {
    local t n r=0
    [[ -r "$HOME_DIR/ranks.conf" ]] || return 0
    while read -r t n _; do
        n="${n%$'\r'}"
        [[ -n "$n" && "$t" != "#"* && "$t" == "$1" && -f "$(script_path "$t" "$n")" ]] || continue
        r=$((r + 1))
        if [[ "$n" == "$2" ]]; then
            printf '%s\n' "$r"
            return 0
        fi
    done <"$HOME_DIR/ranks.conf"
}

# catalog_json: the shipped components, in install order of their types, then by rank.
catalog_json() {
    local t n desc rank dm comps='[]'
    for t in "${TYPES[@]}"; do
        for n in $(component_names "$t"); do
            desc="$(bash "$(script_path "$t" "$n")" describe)" || fail "$?" "describe of $t $n failed"
            rank="$(rank_of "$t" "$n")"
            dm=""
            [[ "$t" != engine ]] || dm="$(default_model "$n")"
            comps="$(jq -c --arg t "$t" --arg n "$n" --argjson r "$(_num_or_null "$rank")" --argjson dm "$(_str_or_null "$dm")" \
                --argjson d "$desc" --argjson isengine "$([[ "$t" == engine ]] && printf true || printf false)" \
                '. + [{type: $t, name: $n, rank: $r} + (if $isengine then {default_model: $dm} else {} end) + {describe: $d}]' <<<"$comps")"
        done
    done
    jq -nc --argjson sv "$AI_SCHEMA_VERSION" --arg cv "$CLI_VERSION" --argjson types "$(printf '%s\n' "${TYPES[@]}" | jq -R . | jq -sc .)" \
        --argjson c "$comps" '{
        schema_version: $sv, cli_version: $cv, types: $types,
        components: ($c | to_entries | sort_by(. as $x | [($types | index($x.value.type)), ($x.value.rank // 1000000), $x.key]) | map(.value))
      }'
}

cmd_catalog() {
    local arg json
    for arg in "$@"; do
        fail "$EXIT_USAGE" "catalog takes no argument (got '$arg')"
    done
    json="$(catalog_json)"
    if ((_OPT_JSON)); then
        printf '%s\n' "$json"
        return 0
    fi
    {
        printf '%-16s%-12s%-6s%-24s%-16s%-18s%s\n' TYPE NAME RANK VERSION REQUIRES PLATFORMS DEFAULT-MODEL
        jq -r '.components[] | [.type, .name, (.rank // "-" | tostring), (.describe.component_version // "?"),
            ((.describe.requires // []) | if length == 0 then "-" else join(",") end),
            ((.describe.platforms // []) | if length == 0 then "-" else join(",") end), (.default_model // "-")] | @tsv' <<<"$json" |
            while IFS=$'\t' read -r t n r v rq p dm; do
                printf '%-16s%-12s%-6s%-24s%-16s%-18s%s\n' "$t" "$n" "$r" "$v" "$rq" "$p" "$dm"
            done
    }
}

# --- config schema -------------------------------------------------------------------

# shellcheck disable=SC2016
readonly CONFIG_SCHEMA_JQ='
def opt_schema:
  . as $o
  | (($o.description // "")
     + (if $o.warn != null then " WARNING: " + $o.warn.message else "" end)
     + (if ($o.default // "") != "" and $o.secret != true then " (default: \($o.default))" else "" end)) as $d
  | (if $o.secret == true then
       {oneOf: [
         {type: "object", properties: {file: {type: "string"}}, required: ["file"], additionalProperties: false},
         {type: "object", properties: {env: {type: "string"}}, required: ["env"], additionalProperties: false},
         {type: "object", properties: {generate: {const: true}}, required: ["generate"], additionalProperties: false}]}
     elif $o.type == "integer" then
       {anyOf: [
         ({type: "integer"} + (if $o.min != null then {minimum: $o.min} else {} end) + (if $o.max != null then {maximum: $o.max} else {} end)),
         {type: "string", pattern: "^-?[0-9]+$"}]}
     elif $o.type == "boolean" then {anyOf: [{type: "boolean"}, {enum: ["true", "false"]}]}
     elif $o.type == "enum" then {enum: $o.values}
     else {type: ["string", "number", "boolean"]} end)
    + (if $d != "" then {description: $d} else {} end);
def comp_schema:
  . as $c
  | {type: "object", required: ["type", "name"], additionalProperties: false,
     description: "\($c.type) \($c.name)\(if $c.rank != null then ", rank \($c.rank)" else "" end)\(if ($c.describe.requires // []) | length > 0 then ", requires \($c.describe.requires | join(", "))" else "" end)",
     properties: {
       type: {const: $c.type}, name: {const: $c.name},
       default: {type: "boolean", description: "make it the default of its type"},
       options: {type: "object", additionalProperties: false,
                 properties: (reduce ($c.describe.options // [])[] as $o ({}; .[$o.name] = ($o | opt_schema)))}}};
. as $cat
| ([.components[] | select(.type == "engine") | .name]) as $engines
| ([.components[] | select(.type == "chat-interface") | .name]) as $chats
| {"$schema": "https://json-schema.org/draft/2020-12/schema",
   title: "easy-cs-ai configuration",
   description: $rules,
   type: "object", required: ["schema_version"], additionalProperties: false,
   properties: {
     schema_version: {type: "integer", minimum: 1, maximum: $maxver},
     components: {type: "array", items: {oneOf: [$cat.components[] | comp_schema]}},
     models: {type: "array", items: {
       type: "object", required: ["name"], additionalProperties: false,
       properties: {
         name: {type: "string", minLength: 1, description: "model name, as the engine knows it"},
         engine: ({type: "string", description: "default: the only engine listed, else the one with default true"} + (if ($engines | length) > 0 then {enum: $engines} else {} end)),
         chat_interface: ({type: ["string", "null"], description: "default: like engine, none when no chat interface is listed; null for none"} + (if ($chats | length) > 0 then {enum: ($chats + [null])} else {} end)),
         force: {type: "boolean", description: "true skips the llmfit fit check"}}}}}}'

readonly CONFIG_RULES='A deployment: which components, with which options, and which models. At most one entry per component, at most one default per type, the order of the entries carries no meaning (the install order comes from requires). A component required by another (see its description) must be listed or already installed. A secret option is never a plain value: give {"file": path} (mode 0600), {"env": NAME} or {"generate": true}. Validate with: easy-cs-ai config validate FILE --target fresh|this --json'

config_schema_json() {
    catalog_json | jq -c --arg rules "$CONFIG_RULES" --argjson maxver "$APPLY_SCHEMA_VERSION" "$CONFIG_SCHEMA_JQ"
}

# --- config validate -----------------------------------------------------------------

# shellcheck disable=SC2016
readonly CONFIG_WARNINGS_JQ='. as $cfg
  | [($cfg.components // []) | if type == "array" then to_entries[] else empty end | .key as $i | .value as $c
     | select($c | type == "object") | $desc[($c.type | tostring) + "/" + ($c.name | tostring)] as $d | select($d != null)
     | (if ($c.options | type) == "object" then $c.options else {} end) as $o
     | $d.options[]? | select(.warn != null) | . as $opt
     | (if ($o | has($opt.name)) then $o[$opt.name] else $opt.default end | tostring) as $v
     | select($v == $opt.warn.when)
     | {path: "$.components[\($i)]", component: {type: $c.type, name: $c.name}, option: $opt.name, value: $v, message: $opt.warn.message}]'

# shellcheck disable=SC2016
readonly CONFIG_PLAN_JQ='. as $cfg
  | {components: [$order | to_entries[] | .key as $i | .value as $k
      | ($cfg.components[] | select(.type == $k.type and .name == $k.name)) as $c
      | {order: ($i + 1), type: $c.type, name: $c.name, options: ($c.options // {}), default: ($c.default // false)}
        + (if $installed != null then {installed: ($installed | index($c.name) != null)} else {} end)],
     models: $models, prune: $prune}'

# config_report <config> <target> [<prune>]: print the document of `config validate`
# (see docs/spec-ai-interface.md): errors, warnings and the plan. <config> is
# valid JSON. The target is this (this machine) or fresh (a new VM, what is
# installed here is ignored).
config_report() {
    local config="$1" target="$2" prune="${3:-false}" desc errors warnings plan=null order models installed=null hostids='[]'
    if [[ "$target" == fresh ]]; then
        export EASY_CS_AI_ASSUME_EMPTY=1
    else
        hostids="$(host_ids_json)"
    fi
    desc="$(apply_describes "$config")"
    errors="$(apply_problems "$config" "$desc" true "$hostids")"
    warnings="$(jq -c --argjson desc "$desc" "$CONFIG_WARNINGS_JQ" <<<"$config" 2>/dev/null)" || warnings='[]'
    if [[ "$errors" == '[]' ]]; then
        if order="$(apply_order "$config" "$desc" 2>/dev/null)"; then
            models="$(apply_models "$config" | jq -R 'select(length > 0) | split("\t") | {name: .[0], engine: .[1], chat_interface: (if .[2] == "null" then null else .[2] end), force: (.[3] == "true")}' | jq -sc .)"
            [[ "$target" != this ]] || installed="$(state_list | jq -R . | jq -sc .)"
            plan="$(jq -c --argjson order "$(jq -R 'select(length > 0) | split(" ") | {type: .[0], name: .[1]}' <<<"$order" | jq -sc .)" \
                --argjson models "$models" --argjson installed "$installed" --argjson prune "$prune" "$CONFIG_PLAN_JQ" <<<"$config")"
        else
            errors='[{"path":"$.components","code":"circular_requirement","message":"the requirements of the listed components are circular"}]'
        fi
    fi
    jq -nc --argjson sv "$AI_SCHEMA_VERSION" --arg target "$target" --argjson e "$errors" --argjson w "$warnings" --argjson p "$plan" \
        '{schema_version: $sv, ok: ($e | length == 0), target: $target, errors: $e, warnings: $w, plan: $p}'
}

# config_report_text <document>: the human form of a report, on stderr.
config_report_text() {
    local doc="$1" line
    while IFS= read -r line; do
        log_error "$line"
    done < <(jq -r '.errors[] | "\(.path): \(.message)"' <<<"$doc")
    while IFS= read -r line; do
        log_info "$line"
    done < <(jq -r '.plan // empty | (.components[] | "plan: install \(.type) \(.name) \(.options | to_entries | map("--\(.key) \(.value)") | join(" "))"),
        (.models[] | "plan: add \(.name) to \(.engine) (chat interface: \(.chat_interface // "none"))"),
        (if .prune then "plan: prune what the file does not name" else empty end)' <<<"$doc")
    while IFS= read -r line; do
        log_warn "$line"
    done < <(jq -r '.warnings[] | "\(.component.name) --\(.option)=\(.value): \(.message)"' <<<"$doc")
}

# config_exit_code <document> [<missing-requirement-code>]: 0 when ok, else 2;
# `apply` passes 4 to keep its exit code for a requirement nothing satisfies.
config_exit_code() {
    local doc="$1" req_code="${2:-2}"
    if [[ "$(jq -r '.ok' <<<"$doc")" == true ]]; then
        printf 0
    elif jq -e '.errors | all(.code == "missing_requirement")' >/dev/null <<<"$doc"; then
        printf '%s' "$req_code"
    else
        printf 2
    fi
}

# read_config <file|->: read a configuration into CONFIG_TEXT; CONFIG_NOT_JSON
# is 1 when it is not valid JSON. Not to be called in a command substitution.
CONFIG_TEXT=""
CONFIG_NOT_JSON=0
read_config() {
    local source="$1"
    CONFIG_NOT_JSON=0
    if [[ "$source" == "-" ]]; then
        CONFIG_TEXT="$(cat)"
    else
        [[ -r "$source" ]] || fail "$EXIT_USAGE" "cannot read $source"
        CONFIG_TEXT="$(cat "$source")"
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$CONFIG_TEXT"; then
        CONFIG_NOT_JSON=1
    fi
}

# not_json_document <target>: the report of a file that is not JSON.
not_json_document() {
    jq -nc --argjson sv "$AI_SCHEMA_VERSION" --arg target "$1" \
        '{schema_version: $sv, ok: false, target: $target, errors: [{path: "$", code: "not_json", message: "the configuration is not valid JSON"}], warnings: [], plan: null}'
}

cmd_config() {
    local sub="${1:-}" source="" target=this arg doc rc
    case "$sub" in
    schema)
        shift
        (($# == 0)) || fail "$EXIT_USAGE" "config schema takes no argument (got '$1')"
        config_schema_json
        ;;
    validate)
        shift
        while [[ $# -gt 0 ]]; do
            arg="$1"
            shift
            case "$arg" in
            --target)
                [[ $# -gt 0 ]] || fail "$EXIT_USAGE" "--target needs a value (this or fresh)"
                target="$1"
                shift
                ;;
            -) source="-" ;;
            -*) fail "$EXIT_USAGE" "unknown option: $arg" ;;
            *) [[ -z "$source" ]] || fail "$EXIT_USAGE" "one configuration file at a time"; source="$arg" ;;
            esac
        done
        [[ "$target" == this || "$target" == fresh ]] || fail "$EXIT_USAGE" "unknown target '$target' (this or fresh)"
        [[ -n "$source" ]] || fail "$EXIT_USAGE" "config validate needs a configuration file" "easy-cs-ai config validate <file|-> [--target this|fresh]"
        read_config "$source"
        if ((CONFIG_NOT_JSON)); then
            doc="$(not_json_document "$target")"
        else
            doc="$(config_report "$CONFIG_TEXT" "$target")"
        fi
        if ((_OPT_JSON)); then
            printf '%s\n' "$doc"
        else
            config_report_text "$doc"
        fi
        rc="$(config_exit_code "$doc")"
        return "$rc"
        ;;
    "") fail "$EXIT_USAGE" "config needs a subcommand" "easy-cs-ai config schema, or easy-cs-ai config validate <file|->" ;;
    *) fail "$EXIT_USAGE" "unknown config subcommand '$sub'" "easy-cs-ai config schema, or easy-cs-ai config validate <file|->" ;;
    esac
}

# --- guide ----------------------------------------------------------------------------

cmd_guide() {
    (($# == 0)) || fail "$EXIT_USAGE" "guide takes no argument (got '$1')"
    cat <<'EOF'
easy-cs-ai: guide for an AI agent (or any program) acting for a user

Rule: with --json, stdout is exactly one JSON document and stderr holds the
logs; without it, the output is for humans and is not a stable interface. The
exit code is the first success signal (0 = ok, 2 = usage or invalid input,
3 platform, 4 precondition, 5 network, 6 verification, 7 incomplete rollback).

Procedure
 1. Ask before assuming. Nothing is chosen on the user's behalf: the stack
    (install --defaults included) is the user's decision; the ranks of the
    catalog are only a suggestion.
 2. Discover:   easy-cs-ai catalog --json    what can be installed, options,
                                             ranks, default models
               easy-cs-ai host --json       this machine (CPU, RAM, disk, GPU)
    For another machine (a VM to provision), ask the user for its specs.
    To choose a model: easy-cs-ai provisioning llmfit recommend --json
    (add --target-ram GB, --target-vram GB, --target-cpu-cores N to size it
    for another machine). llmfit must be installed: ask before installing it.
 3. Draft a configuration (JSON). Its format: easy-cs-ai config schema
    A secret option is never a plain value: {"file": path}, {"env": NAME} or
    {"generate": true}. Never put a secret on a command line or in a file.
 4. Validate:   easy-cs-ai config validate FILE --target fresh --json
    (--target this for this machine). Fix every entry of "errors" using its
    "path" and "code", and validate again until "ok" is true.
 5. Show the user the "plan" and EVERY entry of "warnings" (open registration,
    ...) and get a yes before going further.
 6. Produce, as the user chose:
      - a VM post-install script:
          easy-cs-ai generate --config FILE --output SCRIPT [--package-version V ...]
        the user reviews it and runs it on the VM;
      - or the change on this machine, only with the user's explicit
        agreement: sudo easy-cs-ai apply FILE --json
 7. Read the result document of the command and `easy-cs-ai status --json`,
    and report in plain words. A failure is reported with its "message" and
    "failed_step"; a second apply resumes where it stopped, do not retry blindly.
 8. Never run uninstall, remove, apply --prune, --purge, `exec` or
    `proxy nginx show-key` on your own initiative: exec runs any command of a
    component's program, outside the state, the lock and the journal.
EOF
}

# --- result documents of the changing commands ----------------------------------------

# record_step <label> <exit>: append to the steps file of a run with a result document.
# PLAN_ONLY is 1 when the arguments of install or uninstall hold --dry-run, which the
# components handle themselves: the document then holds the plan they print.
PLAN_ONLY=0

record_step() {
    [[ -z "${EASY_CS_AI_STEPS_FILE:-}" ]] || printf '%s\t%s\n' "$1" "$2" >>"$EASY_CS_AI_STEPS_FILE"
}

# run_with_result <command> <function> <args…>: with --json, run the function and
# print the result document at the end, whatever the outcome; the command's own
# stdout is dropped (the document is the only thing on stdout), stderr is kept.
# With --dry-run the document holds the plan, taken from the plan lines.
run_with_result() {
    local command="$1" rc=0 steps errf doc
    shift
    steps="$(mktemp)"
    errf="$(mktemp)"
    export EASY_CS_AI_STEPS_FILE="$steps"
    set +e
    { ("$@") 2>&1 >/dev/null | tee "$errf" >&2; rc=${PIPESTATUS[0]}; }
    set -e
    if ((DRY || PLAN_ONLY)); then
        doc="$(jq -Rnc --argjson sv "$AI_SCHEMA_VERSION" --arg c "$command" --argjson exit "$rc" '
            [inputs | select(test("^\\[INFO\\] (plan|dry run): ")) | sub("^\\[INFO\\] (plan: |dry run: )"; "") | {step: .}] as $p
            | {schema_version: $sv, command: $c, dry_run: true, ok: ($exit == 0), exit: $exit, plan: $p}' <"$errf")"
    else
        doc="$(jq -Rnc --argjson sv "$AI_SCHEMA_VERSION" --arg c "$command" --argjson exit "$rc" --rawfile steps "$steps" '
            [inputs | select(startswith("[ERROR] ")) | sub("^\\[ERROR\\] "; "")] as $errors
            | ($steps | split("\n") | map(select(length > 0) | split("\t") | {step: .[0], exit: (.[1] | tonumber)})) as $s
            | {schema_version: $sv, command: $c, ok: ($exit == 0), exit: $exit,
               failed_step: (if $exit == 0 then null else
                   (([$s[] | select(.exit != 0)] | last | .step)
                    // ([$errors[] | select(startswith("apply: ")) | capture("^apply: (?<s>.*) failed \\(exit") | .s] | first)) end),
               message: (if $exit == 0 then null else ($errors[0] // null) end),
               steps: $s, rollback_complete: ($exit != 7)}' <"$errf")"
    fi
    rm -f "$steps" "$errf"
    unset EASY_CS_AI_STEPS_FILE
    printf '%s\n' "$doc"
    return "$rc"
}
