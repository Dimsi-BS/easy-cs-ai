#!/usr/bin/env bash
# The machine interface of the CLI (catalog, host, config, guide, result
# documents), see docs/spec-capabilities.md. Sourced by package/bin/easy-cs-ai,
# and by vm_script/lib/generator.sh for config_report. Needs common.sh, cli-base.sh
# and cli-apply.sh. With --json (_OPT_JSON) stdout is exactly one JSON
# document; without it a command with a human rendering prints that, one that
# only returns data prints JSON anyway.

readonly AI_SCHEMA_VERSION=1
# the document of `config validate` (and of `script --json`, `apply --dry-run --json`) is at version 2
readonly CONFIG_DOC_VERSION=2

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
       {oneOf: ([
         {type: "object", properties: {file: {type: "string"}}, required: ["file"], additionalProperties: false},
         {type: "object", properties: {env: {type: "string"}}, required: ["env"], additionalProperties: false},
         {type: "object", properties: {generate: {const: true}}, required: ["generate"], additionalProperties: false}]
         | map(select(.required[0] | IN(($o.sources // ["file", "env", "generate"])[]))))}
     elif $o.type == "integer" then
       {anyOf: [
         ({type: "integer"} + (if $o.min != null then {minimum: $o.min} else {} end) + (if $o.max != null then {maximum: $o.max} else {} end)),
         {type: "string", pattern: "^-?[0-9]+$"}]}
     elif $o.type == "boolean" then {anyOf: [{type: "boolean"}, {enum: ["true", "false"]}]}
     elif $o.type == "enum" then {enum: $o.values}
     else {type: ["string", "number", "boolean"]} end)
    + (if $d != "" then {description: $d} else {} end);
def options_schema($list): {type: "object", additionalProperties: false,
  properties: (reduce ($list // [])[] as $o ({}; .[$o.name] = ($o | opt_schema)))};
def name_schema($what): {type: "string", pattern: "^[a-z][a-z0-9-]*$", description: $what};
def model_schema($c): {
  type: "object", required: ["model"], additionalProperties: false,
  description: "one instance of a model on this engine; unique `model` and `name` in the engine",
  properties: {
    model: {type: "string", minLength: 1, description: "the AI model, as the engine knows it (its identity)"},
    name: {type: "string", minLength: 1, pattern: "^[^\\u0000-\\u001f\\u007f]+$", description: "free name of the instance, needed to be the target of a link (the session writes the model)"},
    force: {type: "boolean", description: "true skips the llmfit fit check"},
    options: options_schema($c.describe.action_options["add-model"])}};
def required_node($o): ($o.required_when | if type == "array" then . else [.] end) as $cs
  | {"if": {required: ["options"], properties: {options: {required: [$cs[].option],
        properties: (reduce $cs[] as $k ({}; .[$k.option] = {enum: $k.values}))}}},
     "then": {required: ["options"], properties: {options: {required: [$o.name]}}},
     description: "option \($o.name) is required when \([$cs[] | "\(.option) is \(.values | join(" or "))"] | join(" and "))"};
def comp_schema:
  . as $c
  | ("\($c.type)/\($c.name)") as $k
  | {type: "object", required: ["component"], additionalProperties: false,
     description: "\($k)\(if $c.rank != null then ", rank \($c.rank)" else "" end)\(if ($c.describe.requires // []) | length > 0 then ", requires \($c.describe.requires | join(", "))" else "" end)",
     properties: ({
       component: {const: $k},
       name: name_schema("how the component is called in its VM, needed only to be designated by a link; unique in the VM"),
       default: {type: "boolean", description: "make it the default of its type, at most one per type and per VM"},
       options: options_schema($c.describe.options)}
       + (if $c.type == "engine" then {models: {type: "array", items: model_schema($c)}} else {} end))}
     + (([($c.describe.options // [])[] | select(.required_when != null) | required_node(.)]) as $rn | if ($rn | length) > 0 then {allOf: $rn} else {} end);
. as $cat
| ([$cat.components[] | "\(.type)/\(.name)"]) as $kinds
| {"$schema": "https://json-schema.org/draft/2020-12/schema",
   title: "easy-cs-ai configuration",
   description: $rules,
   type: "object", required: ["schema_version", "vms"], additionalProperties: false,
   properties: {
     schema_version: {const: $maxver},
     vms: {type: "array",
           description: "the machines, each holding its components; the name of a VM is required when the file has several, unique in the file, and required when a link designates the VM",
           items: {type: "object", required: ["components"], additionalProperties: false,
                   properties: {
                     name: name_schema("the name of the VM, needed to be designated (a link) and when the file has several VMs"),
                     components: {type: "array", minItems: 1,
                                  description: "the components installed on the VM: one per implementation for now, at most one default per type, unique names; the install order comes from requires",
                                  items: {properties: {component: {enum: $kinds}}, oneOf: [$cat.components[] | comp_schema]}}}}},
     links: {type: "array",
             description: "the wiring: each entry says that a model is shown in a chat interface; every reference is complete and designates by name. One link per model for now, no link written twice; a model of a protected engine is not linked to a chat interface of another VM",
             items: {type: "object", required: ["model", "chat_interface"], additionalProperties: false,
                     properties: {
                       model: {type: "object", required: ["vm_ref", "component_ref", "model_ref"], additionalProperties: false,
                               properties: {vm_ref: {type: "string"}, component_ref: {type: "string"}, model_ref: {type: "string"}}},
                       chat_interface: {type: "object", required: ["vm_ref", "component_ref"], additionalProperties: false,
                                        properties: {vm_ref: {type: "string"}, component_ref: {type: "string"}}}}}}},
   allOf: [{"if": {required: ["vms"], properties: {vms: {minItems: 2}}}, "then": {properties: {vms: {items: {required: ["name"]}}}}}]}'

readonly CONFIG_RULES='A deployment: a list of VMs that hold their components, an engine component holding the models installed on it, and links saying which model is shown in which chat interface. At most one entry per implementation on a VM, at most one default per type and per VM, the order of the entries carries no meaning (the install order comes from requires). A component required by another (see its description) must be listed on the same VM or already installed. A secret option is never a plain value: give {"file": path} (mode 0600), {"env": NAME} or {"generate": true}. A link designates by name and is always complete: the VM, the engine and the model instance, the VM and the chat interface must have their name written. Validate with: easy-cs-ai config validate FILE --target fresh|this --json'

config_schema_json() {
    catalog_json | jq -c --arg rules "$CONFIG_RULES" --argjson maxver "$APPLY_SCHEMA_VERSION" "$CONFIG_SCHEMA_JQ"
}

# --- config validate -----------------------------------------------------------------

# The warnings that come from the `warn` entries of the describes, for the effective
# value of an option (a default included). Arguments: $desc and $installed.
# shellcheck disable=SC2016
readonly CONFIG_WARNINGS_JQ='. as $cfg | '"$APPLY_COMMON_JQ"'
  [comps[] | . as $x | $desc[($x.comp | tostring)] as $d | select($d != null)
   | (if ($x.c.options | type) == "object" then $x.c.options else {} end) as $o
   | $d.options[]? | select(.warn != null) | . as $opt
   | (if ($o | has($opt.name)) then $o[$opt.name] else $opt.default end | tostring) as $v
   | select($v == $opt.warn.when)
   | {path: "$.vms[\($x.vi)].components[\($x.ci)]", component_ref: $x.name, component: $x.comp, option: $opt.name, value: $v, message: $opt.warn.message}
     + vmtag($x.vname)]'

# The plan of one slice. Arguments: $order ({type, name} of each component, name being
# the implementation, in install order), $models, $installed (null for a fresh target)
# and $prune. Input: the slice.
# shellcheck disable=SC2016
readonly CONFIG_PLAN_JQ='. as $cfg | ($cfg.vms[0] // {}) as $vm
  | {name: ($vm.name // null),
     components: [$order | to_entries[] | .key as $i | .value as $k
      | ($vm.components[] | select(.component == "\($k.type)/\($k.name)")) as $c
      | {order: ($i + 1), component: $c.component, name: ($c.name // null), options: ($c.options // {}), default: ($c.default // false)}
        + (if $installed != null then {installed: ($installed | index($k.name) != null)} else {} end)],
     models: $models, prune: $prune}'

# The models of a slice, flat, each with the engine that holds it as resolved.
# shellcheck disable=SC2016
readonly CONFIG_MODELS_JQ='(.vms[0] // {}) as $vm
  | [($vm.components // [])[] | select(.component | startswith("engine/")) | . as $en
     | (.models // [])[] | {model: .model, name: (.name // null),
        engine: {vm_ref: ($vm.name // null), component_ref: ($en.name // null), component: $en.component},
        force: (.force // false)}]'

# The links of a file as written and resolved, for plan.links. Argument: $desc.
# shellcheck disable=SC2016
readonly CONFIG_LINKS_JQ='. as $cfg | '"$APPLY_COMMON_JQ$APPLY_LINKS_JQ"'
  [resolved_links[] | {model: {vm_ref: .mvn, component_ref: .l.model.component_ref, model_ref: .mref, component: .en.comp},
                       chat_interface: {vm_ref: .cvn, component_ref: .l.chat_interface.component_ref, component: .ch.comp}}]'

# The errors and warnings that come from the validation itself and the next steps of a file,
# see docs/spec-multi-vm.md: `models_not_checked` (per VM), `duplicate_server_name` (error) and
# `engine_address_unknown` (warning), all computed on the whole file so never by a validation of
# one slice, and the instructions the administrator follows once the VMs are up, from the steps
# links (docs/spec-config.md#links). Arguments: $desc and $installed, like the validation.
# Output: {errors, warnings, next_steps}. The text of a step names only actions and options the
# `describe` of the scripts declares, so the CLI never gives a command that fails.
# shellcheck disable=SC2016
readonly CONFIG_CROSS_JQ='. as $cfg | '"$APPLY_COMMON_JQ$APPLY_LINKS_JQ"'
def has_comp($vi; $t): any(comps[]; .vi == $vi and .type == $t);
def proxy_of($vi): first(comps[] | select(.vi == $vi and .type == "proxy")) // null;
def vname_of($vi): first(vmlist[] | select(.vi == $vi)).vname;
def tls_of($p): ($p.c.options.tls // ($desc[$p.comp].options[]? | select(.name == "tls") | .default) // "self-signed");
def not_checked: [vmlist[] | . as $x
  | select(any(comps[]; .vi == $x.vi and .type == "engine" and any((.c.models // [])[]?; type == "object" and .force == true)) and (has_comp($x.vi; "provisioning") | not))
  | {path: "$.vms[\($x.vi)]", code: "models_not_checked", message: "models not checked for fit on the VM: llmfit is not part of the stack"} + vmtag($x.vname)];
def exposed: [steps_links[] | .mvi] | unique;
def address_unknown: [exposed[] as $vi | select(has_comp($vi; "proxy"))
  | proxy_of($vi) as $p
  | select(($p.c.options // {} | has("server-name") | not) and (tls_of($p) == "self-signed"))
  | {path: "$.vms[\($vi)].components[\($p.ci)]", code: "engine_address_unknown",
     message: "The address of the engine VM is not known yet: its proxy will take the host name of the machine as its server name, and a self-signed certificate will also cover the addresses the machine has when it is installed. The VM that shows the models must reach the engine VM by one of those names or addresses. If none does, re-run `install proxy \($p.impl)` on the engine VM with the options it was installed with and `--server-name <name or address>` (an option left out returns to its default), before linking the models"} + vmtag($p.vname)];
def server_names: [comps[] | select(.type == "proxy" and ((.c.options // {}) | has("server-name")))
  | {vi, ci, vname, name: ((.c.options["server-name"]) | tostring | ascii_downcase)}];
def dup_server_name: [server_names | group_by(.name)[] | select((map(.vi) | unique | length) > 1)
  | . as $g | ($g[0].vi) as $first | $g[1:][] | select(.vi != $first)
  | {path: "$.vms[\(.vi)].components[\(.ci)].options.server-name", code: "duplicate_server_name",
     message: "VM \"\(.vname // "")\" repeats the server-name of VM \"\(vname_of($first) // "")\": two machines cannot answer to the same name. Give each VM its own name, or leave it out"} + vmtag(.vname)];
def slug: ascii_downcase | gsub("[^a-z0-9.-]"; "-");
def full: (steps_links | length) > 0 and all(steps_links[];
    (proxy_of(.mvi)) as $p | .ch as $c
    | $p != null
      and (["install", "status", "show-key", "list-upstreams"] - ($desc[$p.comp].actions // []) | length) == 0
      and (["model", "api-key-file", "ca-file"] - (($desc[$c.comp].action_options["add-endpoint"] // []) | map(.name)) | length) == 0);
def steps: steps_links as $sl | if ($sl | length) == 0 then ["Run each script as root on its VM."]
  else
    full as $full
    | if ($full | not) then ["Run each script as root on its VM."]
      else
        exposed as $evis
        | ["Run each script as root on its VM, the engine VMs first."]
          + [$evis[] as $ev | proxy_of($ev) as $p
             | "On the engine VM \(vname_of($ev)), read the API key, the URL of each model and the names\nand addresses its certificate covers:\n  sudo easy-cs-ai component proxy \($p.impl) show-key\n  easy-cs-ai component proxy \($p.impl) list-upstreams\n  easy-cs-ai component proxy \($p.impl) status          (certificate_names)"]
          + [$evis[] as $ev | ([$sl[] | select(.mvi == $ev) | .cvn] | unique) as $wvms
             | "Let the VM\(if ($wvms | length) > 1 then "s" else "" end) \($wvms | join(", ")) reach the VM \(vname_of($ev)) on the HTTPS port of its proxy\n(443 unless you set --port): firewall, security group."]
          + [$evis[] as $ev | ([$sl[] | select(.mvi == $ev) | .cvi] | unique)[] as $cv
             | ([$sl[] | select(.mvi == $ev and .cvi == $cv)]) as $g | $g[0] as $f | proxy_of($ev) as $p
             | "On the VM \($f.cvn), link each model of the VM \($f.mvn):\n"
               + ([$g[] | "  sudo easy-cs-ai component chat-interface \(.ch.impl) add-endpoint \(.mvn)-\(.en.name)-\(.model.model | slug) <url> \\\n    --model \(.model.model) --api-key-file <file>"] | join("\n"))
               + "\n<url> is the one read in step 2, <file> holds the key (mode 0600, or - for\nstdin), and the endpoint name is suggested unique on the VM (a chat\ninterface may link several engine VMs and several engines).\nWith the default self-signed certificate, copy the certificate of the\nVM \($f.mvn) (/etc/easy-cs-ai/nginx/server.crt) to the VM \($f.cvn) and add\n--ca-file <file>. The host in <url> must be one the certificate covers\n(certificate_names, step 2): the server name printed by list-upstreams,\nor, when no server name was given, an address of the VM \($f.mvn), which\nyou put in place of the host. If the VM \($f.cvn) can reach neither, or the\naddress changed since the proxy was installed, re-run on the VM \($f.mvn)\n  sudo easy-cs-ai install proxy \($p.impl) <the options it was installed with> \\\n    --server-name <name or address>\n(an option left out returns to its default) which renews a self-signed\ncertificate (copy it again), then read step 2 again."]
      end
  end;
{errors: dup_server_name, warnings: (not_checked + address_unknown), next_steps: steps}'

# config_cross <config> <desc>: {errors, warnings, next_steps}, see CONFIG_CROSS_JQ.
config_cross() {
    jq -c --argjson desc "$2" --argjson installed '{}' "$CONFIG_CROSS_JQ" <<<"$1"
}

# config_validate_cross <config> <desc>: print the errors that need the whole file
# (`duplicate_server_name`, see docs/spec-multi-vm.md#validation) and exit 2 when any.
# `script` calls this before writing any script, as `config validate` does through
# `config_report`'s exit code; `apply` does not, see docs/spec-config.md#links.
config_validate_cross() {
    local problems line
    problems="$(config_cross "$1" "$2" | jq -r '.errors[] | "\(.path): \(.message)"')"
    if [[ -n "$problems" ]]; then
        while IFS= read -r line; do log_error "$line"; done <<<"$problems"
        fail "$EXIT_USAGE" "the configuration is invalid"
    fi
}

# next_steps_text <next_steps-json>: what a person reads after the scripts are written. The title,
# the numbering and the closing line are the rendering's, the steps are the validation's.
next_steps_text() {
    local steps="$1" n i line total
    total="$(jq 'length' <<<"$steps")"
    ((total > 0)) || return 0
    printf '\nWhat is left to do once the VMs are up:\n'
    for ((i = 0; i < total; i++)); do
        n=$((i + 1))
        jq -r --argjson i "$i" '.[$i]' <<<"$steps" | {
            local first=1
            while IFS= read -r line; do
                if ((first)); then printf '  %s. %s\n' "$n" "$line"; first=0; else printf '     %s\n' "$line"; fi
            done
        }
    done
    ((total < 2)) || printf 'Until step %s is done, the model list of the chat interface stays empty.\n' "$total"
}

# config_report <config> <target> [<prune> [<vm>]]: print the document of `config validate`
# (see docs/spec-capabilities.md): errors, warnings, the plan and the next steps. <config> is
# valid JSON. The target is this (this machine) or fresh (a new VM, what is installed here is
# ignored). A file is validated in whole, then planned one slice at a time (`plan.vms`, one entry
# for a file of one VM); <vm> keeps that slice alone, with its errors and warnings and those of
# no VM.
config_report() {
    local config="$1" target="$2" prune="${3:-false}" vm="${4:-}" desc errors warnings plan=null order models installed=null hostids='[]'
    local v slice vmplans='[]' cross steps='[]' names=() links
    if [[ "$target" == fresh ]]; then
        export EASY_CS_AI_ASSUME_EMPTY=1
    else
        hostids="$(host_ids_json)"
    fi
    desc="$(apply_describes "$config")"
    errors="$(apply_problems "$config" "$desc" true "$hostids")"
    warnings="$(jq -c --argjson desc "$desc" --argjson installed '{}' "$CONFIG_WARNINGS_JQ" <<<"$config" 2>/dev/null)" || warnings='[]'
    # what the validation itself refuses or warns about, and the steps left once the VMs are up
    cross="$(config_cross "$config" "$desc" 2>/dev/null)" || cross='{"errors":[],"warnings":[],"next_steps":[]}'
    if [[ -n "$vm" ]]; then
        # a validation of one slice gives none of the errors, warnings or steps that need the other VMs
        cross='{"errors":[],"warnings":[],"next_steps":["Run each script as root on its VM."]}'
        errors="$(jq -c --arg vm "$vm" 'map(select(.vm == null or .vm == $vm))' <<<"$errors")"
        warnings="$(jq -c --arg vm "$vm" 'map(select(.vm == null or .vm == $vm))' <<<"$warnings")"
    fi
    warnings="$(jq -c --argjson c "$cross" '. + $c.warnings' <<<"$warnings")"
    errors="$(jq -c --argjson c "$cross" '. + $c.errors' <<<"$errors")"
    [[ "$target" != this ]] || installed="$(state_list | jq -R . | jq -sc .)"
    if [[ "$errors" == '[]' ]]; then
        if [[ -n "$vm" ]]; then names=("$vm"); else mapfile -t names < <(apply_vms "$config"); fi
        ((${#names[@]})) || names=("")
        for v in "${names[@]}"; do
            slice="$(apply_slice "$config" "$v")"
            if order="$(apply_order "$slice" "$desc" 2>/dev/null)"; then
                models="$(jq -c "$CONFIG_MODELS_JQ" <<<"$slice")"
                plan="$(jq -c --argjson order "$(jq -R 'select(length > 0) | split(" ") | {type: .[0], name: .[1]}' <<<"$order" | jq -sc .)" \
                    --argjson models "$models" --argjson installed "$installed" --argjson prune "$prune" "$CONFIG_PLAN_JQ" <<<"$slice")"
                vmplans="$(jq -c --argjson p "$plan" '. + [$p]' <<<"$vmplans")"
            else
                errors="$(jq -c --arg v "$v" '. + [{path: "$.vms", code: "circular_requirement", message: "the requirements of the listed components are circular"} + (if $v != "" then {vm: $v} else {} end)]' <<<"$errors")"
            fi
        done
        if [[ "$errors" == '[]' ]]; then
            if [[ -n "$vm" ]]; then links="$(apply_slice "$config" "$vm")"; else links="$config"; fi
            links="$(jq -c --argjson desc "$desc" --argjson installed '{}' "$CONFIG_LINKS_JQ" <<<"$links")"
            plan="$(jq -c --argjson links "$links" '{vms: ., links: $links}' <<<"$vmplans")"
            steps="$(jq -c '.next_steps' <<<"$cross")"
        else
            plan=null
        fi
    fi
    # the document names a VM `vm_ref` (null for a lone VM that has no name)
    errors="$(jq -c 'map((.vm // null) as $v | del(.vm) | . + {vm_ref: $v})' <<<"$errors")"
    warnings="$(jq -c 'map((.vm // null) as $v | del(.vm) | . + {vm_ref: $v})' <<<"$warnings")"
    jq -nc --argjson sv "$CONFIG_DOC_VERSION" --arg target "$target" --argjson e "$errors" --argjson w "$warnings" --argjson p "$plan" \
        --argjson ns "$steps" \
        '{schema_version: $sv, ok: ($e | length == 0), target: $target, errors: $e, warnings: $w, plan: $p, next_steps: $ns}'
}

# config_report_text <document>: the human form of a report, on stderr.
config_report_text() {
    local doc="$1" line
    while IFS= read -r line; do
        log_error "$line"
    done < <(jq -r '.errors[] | "\(.path): \(.message)\(if .vm_ref then " (VM \(.vm_ref))" else "" end)"' <<<"$doc")
    while IFS= read -r line; do
        log_info "$line"
    done < <(jq -r '.plan // empty | .vms[] | (if .name then "[\(.name)] " else "" end) as $t
        | (.components[] | "plan: \($t)install \(.component) \(.options | to_entries | map("--\(.key) \(.value)") | join(" "))"),
        (.models[] | "plan: \($t)add \(.model) to \(.engine.component_ref // .engine.component)"),
        (if .prune then "plan: \($t)prune what the file does not name" else empty end)' <<<"$doc")
    while IFS= read -r line; do
        log_warn "$line"
    done < <(jq -r '.warnings[] | (if .code then .message else "\(.component) --\(.option)=\(.value): \(.message)" end) + (if .vm_ref then " (VM \(.vm_ref))" else "" end)' <<<"$doc")
    next_steps_text "$(jq -c '.next_steps // []' <<<"$doc")" >&2
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
    jq -nc --argjson sv "$CONFIG_DOC_VERSION" --arg target "$1" \
        '{schema_version: $sv, ok: false, target: $target, errors: [{path: "$", code: "not_json", message: "the configuration is not valid JSON"}], warnings: [], plan: null, next_steps: []}'
}

cmd_config() {
    local sub="${1:-}" source="" target=this vm="" arg doc rc
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
            --vm)
                [[ $# -gt 0 ]] || fail "$EXIT_USAGE" "--vm needs a VM name"
                vm="$1"
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
            # a file that names VMs: --this is one machine, so it needs --vm; --vm must fit the file
            apply_select_vm "$CONFIG_TEXT" "$vm" "$([[ "$target" == this ]] && printf 1 || printf 0)"
            doc="$(config_report "$CONFIG_TEXT" "$target" false "$vm")"
        fi
        if ((_OPT_JSON)); then
            printf '%s\n' "$doc"
        else
            config_report_text "$doc"
        fi
        rc="$(config_exit_code "$doc")"
        return "$rc"
        ;;
    "") fail "$EXIT_USAGE" "config needs a subcommand" "easy-cs-ai config new, easy-cs-ai config edit <file>, easy-cs-ai config validate <file|-> or easy-cs-ai config schema" ;;
    *) fail "$EXIT_USAGE" "unknown config subcommand '$sub'" "easy-cs-ai config new, easy-cs-ai config edit <file>, easy-cs-ai config validate <file|-> or easy-cs-ai config schema" ;;
    esac
}

# --- guide ----------------------------------------------------------------------------

cmd_guide() {
    (($# == 0)) || fail "$EXIT_USAGE" "guide takes no argument (got '$1')"
    [[ -r "$HOME_DIR/guide.txt" ]] || fail "$EXIT_PRECONDITION" "guide.txt is missing from the package (looked in $HOME_DIR)"
    cat "$HOME_DIR/guide.txt"
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
