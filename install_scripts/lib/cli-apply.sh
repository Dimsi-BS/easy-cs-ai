#!/usr/bin/env bash
# `apply` of the easy-cs-ai CLI, see docs/spec-config.md. Sourced by
# package/bin/easy-cs-ai, which provides fail, need_root, install_one,
# uninstall_one, uninstall_order, cmd_add, cmd_remove, is_type, is_installed,
# script_path, resolve_script and DRY.

readonly APPLY_SCHEMA_VERSION=2

# The definitions shared by the validation and the slicing of a file, format of
# version 2 (docs/spec-config.md#format): a list of VMs that hold their
# components, an engine component holding its models, a `links` array. They read
# the configuration as $cfg and the installed components as $installed. A VM is
# designated by its index in `vms` (`vi`), its `name` being optional.
# shellcheck disable=SC2016
readonly APPLY_COMMON_JQ='
def vm_ok: type == "string" and test("^[a-z][a-z0-9-]*$");
def vmlist: [($cfg | if type == "object" and (.vms | type) == "array" then .vms else [] end) | to_entries[]
  | select(.value | type == "object")
  | {vi: .key, vm: .value, vname: (if (.value.name | type) == "string" then .value.name else null end)}];
def comps: [vmlist[] | . as $x
  | ($x.vm.components | if type == "array" then to_entries[] else empty end) | select(.value | type == "object")
  | .value as $c
  | ($c.component | if type == "string" then split("/") else [] end) as $p
  | {vi: $x.vi, vname: $x.vname, ci: .key, c: $c,
     comp: (if ($p | length) == 2 then $c.component else null end), type: $p[0], impl: $p[1],
     name: (if ($c.name | type) == "string" then $c.name else null end)}];
def vnames: [vmlist[] | .vname | strings];
def named: (vnames | length) > 0;
def several: (vmlist | length) > 1;
def installed_has($r): (([$installed[]?[]]) | index($r) != null) or (($installed[$r] // []) | length > 0);
def satisfied($r; $vi): any(comps[]; .vi == $vi and (.impl == $r or .type == $r)) or installed_has($r);
def vmtag($vname): if $vname != null then {vm: $vname} else {} end;
'

# The VM names of a file, in the order they appear: empty for a file whose VMs
# have none.
# shellcheck disable=SC2016
readonly APPLY_VMS_JQ='. as $cfg | '"$APPLY_COMMON_JQ"' vnames[]'

# Whether a file names its VMs (at least one has a `name`).
# shellcheck disable=SC2016
readonly APPLY_NAMED_JQ='. as $cfg | '"$APPLY_COMMON_JQ"' named'

# The number of VMs of a file.
# shellcheck disable=SC2016
readonly APPLY_VMCOUNT_JQ='. as $cfg | '"$APPLY_COMMON_JQ"' vmlist | length'

# The slice of one VM, argument $vm (its name, "" for the only VM of a file that
# has one): a file of the same format with that VM, the models it holds with
# their engine, and the links whose two ends are on it, see
# docs/spec-config.md#slices.
# shellcheck disable=SC2016
readonly APPLY_SLICE_JQ='. as $cfg | '"$APPLY_COMMON_JQ"'
  (first(vmlist[] | select($vm == "" or .vname == $vm)) // null) as $x
  | {schema_version: $cfg.schema_version, vms: (if $x == null then [] else [$x.vm] end)}
  + (if $x == null or $x.vname == null then {}
     else ([($cfg.links // [])[]? | select(type == "object" and .model.vm_ref == $x.vname and .chat_interface.vm_ref == $x.vname)]
           | if length == 0 then {} else {links: .} end) end)'

# The validation program. Input: the configuration. Arguments: $desc (describe
# of every listed component, keyed "type/implementation"), $installed (installed
# component names by type), $reqs (also report the requirements nothing
# satisfies, and what a model needs), $hostids (the ids of this platform, [] to
# skip the platform check) and $ranks (the proxy and provisioning component the
# messages suggest). Output: one {path, code, message} object per problem, plus
# the `vm` it is about when that VM has a name, see docs/spec-capabilities.md
# for the codes.
# shellcheck disable=SC2016
readonly APPLY_VALIDATE_JQ='. as $cfg |
def types: ["engine", "chat-interface", "proxy", "provisioning"];
def e($p; $c; $m): {path: $p, code: $c, message: $m};
def vmtag($vname): if $vname != null then {vm: $vname} else {} end;
def ev($p; $c; $m; $v): e($p; $c; $m) + vmtag($v);
def only_keys($allowed; $p): to_entries[] | select(.key | IN($allowed[]) | not) | e("\($p).\(.key)"; "unknown_key"; "unknown key");
'"$APPLY_COMMON_JQ"'
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
def name_shape($x; $p): if ($x | has("name")) then
    (if ($x.name | type) != "string" then e("\($p).name"; "wrong_type"; "a string is expected")
     elif ($x.name | vm_ok | not) then e("\($p).name"; "invalid_value"; "lowercase letters, digits and dashes, starting with a letter, are expected")
     else empty end)
  else empty end;
def conds($c): if ($c | type) == "array" then $c else [$c] end;
def cond_holds($given; $decl; $c): all(conds($c)[]; . as $k
  | (if $given | has($k.option) then $given[$k.option] else (first($decl[] | select(.name == $k.option)).default // null) end) as $v
  | any(($k.values // [])[]; tostring == ($v | tostring)));
def cond_text($c): [conds($c)[] | "\(.option) is \((.values // []) | map(tostring) | join(" or "))"] | join(" and ");
def missing_opts($p; $vname; $c; $decl): (if ($c.options | type) == "object" then $c.options else {} end) as $given
  | $decl[]? | select(.required_when != null) | . as $o
  | select(($given | has($o.name) | not) and cond_holds($given; $decl; $o.required_when))
  | ev("\($p).options"; "missing_option"; "option \($o.name) is required when \(cond_text($o.required_when))"; $vname);
def opts_errs($p; $o; $opts): ($o // {}) | if type != "object" then e("\($p).options"; "wrong_type"; "an object is expected") else
    to_entries[] | .key as $k | .value as $v | ($opts | map(select(.name == $k))[0]) as $d
    | if $d == null then e("\($p).options.\($k)"; "unknown_option"; "unknown option (known: \($opts | map(.name) | join(", ")))")
      elif $d.secret == true then
        (if ($v | type) != "object" then e("\($p).options.\($k)"; "secret_literal"; "a secret is given as {\"file\": …}, {\"env\": …} or {\"generate\": true}, never as a plain value")
         elif (($v | keys) == ["file"] and ($v.file | type) == "string") or (($v | keys) == ["env"] and ($v.env | type) == "string") or (($v | keys) == ["generate"] and $v.generate == true) then
           (($v | keys)[0]) as $src
           | if (($d.sources // ["file", "env", "generate"]) | index($src)) == null
             then e("\($p).options.\($k)"; "secret_source"; "this secret cannot be given as \($src), the allowed sources are: \(($d.sources // ["file", "env", "generate"]) | join(", "))")
             else empty end
         else e("\($p).options.\($k)"; "secret_source"; "exactly one of file, env or generate is expected") end)
      elif ($v | type | IN("string", "number", "boolean") | not) then e("\($p).options.\($k)"; "wrong_type"; "a string, number or boolean is expected")
      else (typed($d; $v) | e("\($p).options.\($k)"; "invalid_value"; .)) end
  end;
def needs($vi; $vname; $p; $m; $c): ($m.model | tostring) as $n
  | ($desc[$c.component].endpoint.protected // false) as $prot
  | (if $prot or satisfied("proxy"; $vi) then empty
     else ev($p; "missing_requirement"; "model \($n) needs a proxy to be reached from outside the VM (the engine listens on the loopback only) and none is installed or in the file\(if $ranks.proxy != null then ": add proxy \($ranks.proxy)" else "" end)"; $vname) end),
    (if ($m.force // false) == true or satisfied("provisioning"; $vi) then empty
     else ev($p; "missing_requirement"; "model \($n) needs a provisioning component to check that it fits and none is installed or in the file\(if $ranks.provisioning != null then ": add provisioning \($ranks.provisioning), or set force" else " (or set force)" end)"; $vname) end);
def model_errs($vi; $vname; $p; $m; $c):
  if ($m | type) != "object" then e($p; "wrong_type"; "an object is expected") else
    ($m | only_keys(["model", "name", "force", "options"]; $p)),
    (if ($m | has("model") | not) then e("\($p).model"; "missing_key"; "the model, as the engine knows it, is required")
     elif ($m.model | type) != "string" then e("\($p).model"; "wrong_type"; "a string is expected")
     elif $m.model == "" then e("\($p).model"; "invalid_value"; "a model name is expected") else empty end),
    (if ($m | has("name")) then
       (if ($m.name | type) != "string" then e("\($p).name"; "wrong_type"; "a string is expected")
        elif $m.name == "" or ($m.name | test("[[:cntrl:]]")) then e("\($p).name"; "invalid_value"; "a non-empty string with no control character is expected")
        else empty end) else empty end),
    (if ($m | has("force")) and ($m.force | type) != "boolean" then e("\($p).force"; "wrong_type"; "a boolean is expected") else empty end),
    (if ($m | has("options")) then opts_errs($p; $m.options; ($desc[$c.component].action_options["add-model"] // [])) else empty end),
    (if $reqs and ($m.model | type) == "string" and $m.model != "" then needs($vi; $vname; $p; $m; $c) else empty end)
  end;
def models_errs($vi; $vname; $p; $c):
  if ($c.models | type) != "array" then e("\($p).models"; "wrong_type"; "an array is expected") else
    ($c.models | to_entries[] | model_errs($vi; $vname; "\($p).models[\(.key)]"; .value; $c)),
    ([$c.models | to_entries[] | select((.value | type) == "object" and (.value.model | type) == "string") | {i: .key, k: .value.model}]
      | group_by(.k)[] | select(length > 1) | .[1:][]
      | ev("\($p).models[\(.i)].model"; "duplicate_model"; "\(.k) is listed more than once in this engine"; $vname)),
    ([$c.models | to_entries[] | select((.value | type) == "object" and (.value.name | type) == "string" and .value.name != "") | {i: .key, k: .value.name}]
      | group_by(.k)[] | select(length > 1) | .[1:][]
      | ev("\($p).models[\(.i)].name"; "duplicate_name"; "the name \(.k) is used by several models of this engine"; $vname))
  end;
def comp_errs($vi; $vname; $p; $c):
  if ($c | type) != "object" then e($p; "wrong_type"; "an object is expected") else
    ($c | only_keys(["component", "name", "default", "options", "models"]; $p)),
    name_shape($c; $p),
    (if ($c | has("default")) and ($c.default | type) != "boolean" then e("\($p).default"; "wrong_type"; "a boolean is expected") else empty end),
    (if ($c | has("component") | not) then e("\($p).component"; "missing_key"; "required: <type>/<implementation>, e.g. engine/ollama")
     elif ($c.component | type) != "string" then e("\($p).component"; "wrong_type"; "a string is expected")
     else
       ($c.component | split("/")) as $s
       | if ($s | length) != 2 or $s[0] == "" or $s[1] == "" then e("\($p).component"; "invalid_value"; "<type>/<implementation> is expected, e.g. engine/ollama")
         elif ($s[0] | IN(types[]) | not) then e("\($p).component"; "unknown_type"; "one of \(types | join(", ")) is expected")
         elif $desc[$c.component] == null then e("\($p).component"; "unknown_component"; "unknown \($s[0]) \"\($s[1])\"")
         else
           $desc[$c.component] as $d
           | (if ($hostids | length) > 0 and (($d.platforms // []) | length) > 0 and ((($d.platforms // []) - (($d.platforms // []) - $hostids)) | length) == 0
              then e("\($p).component"; "unsupported_platform"; "\($c.component) supports \(($d.platforms) | join(", ")), this machine is \($hostids | join("/"))") else empty end),
             (if $reqs then ($d.requires // [])[] | . as $r | select(satisfied($r; $vi) | not)
                | ev($p; "missing_requirement"; "\($r) is required by \($c.component) and is neither installed nor in the file\(if $vname != null then " of VM \($vname)" else "" end)"; $vname) else empty end),
             (if ($c | has("options")) then opts_errs($p; $c.options; ($d.options // [])) else empty end),
             missing_opts($p; $vname; $c; ($d.options // []))
         end
     end),
    (if ($c | has("models")) then
       (if ($c.component | type) == "string" and ($c.component | startswith("engine/") | not) then e("\($p).models"; "models_on_non_engine"; "only an engine component holds models")
        else models_errs($vi; $vname; $p; $c) end)
     else empty end)
  end;
def vm_errs: ($cfg.vms | to_entries[]) | .key as $i | .value as $v | "$.vms[\($i)]" as $p
  | (if ($v | type) == "object" and ($v.name | type) == "string" then $v.name else null end) as $vname
  | if ($v | type) != "object" then e($p; "wrong_type"; "an object is expected") else
      ($v | only_keys(["name", "components"]; $p)),
      (if ($v | has("name")) then
         (if ($v.name | type) != "string" then e("\($p).name"; "wrong_type"; "a string is expected")
          elif ($v.name | vm_ok | not) then e("\($p).name"; "invalid_value"; "lowercase letters, digits and dashes, starting with a letter, are expected")
          else empty end)
       elif ($cfg.vms | length) > 1 then e($p; "missing_vm_name"; "a file with several VMs needs the name of each one") else empty end),
      (if ($v | has("components") | not) then e("\($p).components"; "missing_key"; "required: the components installed on the VM")
       elif ($v.components | type) != "array" then e("\($p).components"; "wrong_type"; "an array is expected")
       elif ($v.components | length) == 0 then ev($p; "empty_vm"; "a VM holds at least one component"; $vname)
       else
         ($v.components | to_entries[] | comp_errs($i; $vname; "\($p).components[\(.key)]"; .value)),
         ([comps[] | select(.vi == $i and .name != null) | {ci, k: .name}] | group_by(.k)[] | select(length > 1) | .[1:][]
           | ev("\($p).components[\(.ci)].name"; "duplicate_name"; "the name \(.k) is used by several components of this VM"; $vname)),
         ([comps[] | select(.vi == $i and .comp != null) | {ci, k: .comp}] | group_by(.k)[] | select(length > 1) | .[1:][]
           | ev("\($p).components[\(.ci)]"; "duplicate_component"; "\(.k) is listed more than once on this VM"; $vname)),
         ([comps[] | select(.vi == $i and .c.default == true) | {ci, t: .type}] | group_by(.t)[] | select(length > 1) | .[1:][]
           | ev("\($p).components[\(.ci)].default"; "several_defaults"; "several defaults of type \(.t) on this VM"; $vname))
       end)
    end;
def dup_vms: [vmlist[] | select(.vname != null)] | group_by(.vname)[] | select(length > 1) | .[1:][]
  | e("$.vms[\(.vi)].name"; "duplicate_vm"; "the VM name \(.vname) is used more than once");
def ref_errs($p; $r; $fields): if ($r | type) != "object" then e($p; "wrong_type"; "an object is expected") else
    ($r | only_keys($fields; $p)),
    ($fields[] as $f | if ($r | has($f) | not) then e($p; "missing_key"; "\($f) is required")
       elif ($r[$f] | type) != "string" then e("\($p).\($f)"; "wrong_type"; "a string is expected") else empty end)
  end;
def link_errs: ($cfg.links // []) as $links
  | if ($links | type) != "array" then empty else
      ($links | to_entries[] | .key as $i | .value as $l | "$.links[\($i)]" as $p
       | if ($l | type) != "object" then e($p; "wrong_type"; "an object is expected") else
           ($l | only_keys(["model", "chat_interface"]; $p)),
           (if ($l | has("model") | not) then e("\($p).model"; "missing_key"; "required: the reference to the model")
            else ref_errs("\($p).model"; $l.model; ["vm_ref", "component_ref", "model_ref"]) end),
           (if ($l | has("chat_interface") | not) then e("\($p).chat_interface"; "missing_key"; "required: the reference to the chat interface")
            else ref_errs("\($p).chat_interface"; $l.chat_interface; ["vm_ref", "component_ref"]) end),
           (if ($l.model | type) == "object" and ($l.model.vm_ref | type) == "string" then
              ($l.model.vm_ref) as $mv
              | (first(vmlist[] | select(.vname == $mv)) // null) as $x
              | if $x == null then e("\($p).model.vm_ref"; "unknown_vm"; "no VM is named \"\($mv)\" (the file names: \(vnames | join(", ")))")
                elif ($l.model.component_ref | type) == "string" then
                  ($l.model.component_ref) as $cr
                  | (first(comps[] | select(.vi == $x.vi and .name == $cr and .type == "engine")) // null) as $en
                  | if $en == null then
                      e("\($p).model.component_ref"; "unresolved_engine"; "VM \"\($mv)\" has no engine named \"\($cr)\"\(if any(comps[]; .vi == $x.vi and .name == $cr) then " (that name is another type of component)" elif any(comps[]; .vi == $x.vi and .type == "engine") then " (an engine of that VM has no name written, or another one)" else "" end)")
                    elif ($l.model.model_ref | type) == "string" then
                      ($l.model.model_ref) as $mr
                      | if ([($en.c.models // [])[]? | select(type == "object" and .name == $mr)] | length) == 0 then
                          e("\($p).model.model_ref"; "unresolved_model"; "engine \"\($cr)\" of VM \"\($mv)\" holds no model instance named \"\($mr)\"\(if any(($en.c.models // [])[]?; type == "object" and .model == $mr and has("name") | not) then " (an instance of that model has no name written)" else "" end)")
                        else empty end
                    else empty end
                else empty end
            else empty end),
           (if ($l.chat_interface | type) == "object" and ($l.chat_interface.vm_ref | type) == "string" then
              ($l.chat_interface.vm_ref) as $cv
              | (first(vmlist[] | select(.vname == $cv)) // null) as $x
              | if $x == null then e("\($p).chat_interface.vm_ref"; "unknown_vm"; "no VM is named \"\($cv)\" (the file names: \(vnames | join(", ")))")
                elif ($l.chat_interface.component_ref | type) == "string" then
                  ($l.chat_interface.component_ref) as $cr
                  | if any(comps[]; .vi == $x.vi and .name == $cr and .type == "chat-interface") then empty
                    else e("\($p).chat_interface.component_ref"; "unresolved_chat_interface"; "VM \"\($cv)\" has no chat interface named \"\($cr)\"\(if any(comps[]; .vi == $x.vi and .name == $cr) then " (that name is another type of component)" elif any(comps[]; .vi == $x.vi and .type == "chat-interface") then " (a chat interface of that VM has no name written, or another one)" else "" end)") end
                else empty end
            else empty end),
           (if ($l.model | type) == "object" and ($l.chat_interface | type) == "object"
               and ($l.model.vm_ref | type) == "string" and ($l.chat_interface.vm_ref | type) == "string"
               and $l.model.vm_ref != $l.chat_interface.vm_ref then
              (first(vmlist[] | select(.vname == $l.model.vm_ref)) // null) as $x
              | (first(comps[] | select(.vi == $x.vi and .name == $l.model.component_ref and .type == "engine")) // null) as $en
              | if $x != null and $en != null and ($desc[$en.comp].endpoint.protected // false) then
                  e($p; "protected_engine_other_vm"; "the engine \"\($l.model.component_ref)\" is protected: it enforces HTTPS and its key itself and has no proxy to publish its URL, so its models cannot be linked to a chat interface of another VM")
                else empty end
            else empty end)
         end),
      ([$links | to_entries[] | select((.value | type) == "object"
          and ((.value.model | type) == "object") and ((.value.chat_interface | type) == "object")
          and ([.value.model.vm_ref, .value.model.component_ref, .value.model.model_ref, .value.chat_interface.vm_ref, .value.chat_interface.component_ref] | all(type == "string")))
        | {i: .key, m: [.value.model.vm_ref, .value.model.component_ref, .value.model.model_ref], c: [.value.chat_interface.vm_ref, .value.chat_interface.component_ref]}]
       | (reduce .[] as $l ({seen: [], models: [], errs: []};
            if (.seen | index([[$l.m, $l.c]])) != null then .errs += [e("$.links[\($l.i)]"; "duplicate_link"; "this link is already written")]
            elif (.models | index([$l.m])) != null then .errs += [e("$.links[\($l.i)]"; "unsupported_count"; "a model is shown in one chat interface for now: this one has a second link")]
            else .seen += [[$l.m, $l.c]] | .models += [$l.m] end)).errs[])
    end;
def addvm: if has("vm") then . else ((.path | select(startswith("$.vms[")) | ltrimstr("$.vms[") | split("]")[0] | tonumber) // null) as $i
  | if $i == null then . else ((first(vmlist[] | select(.vi == $i)).vname) // null) as $n | if $n == null then . else . + {vm: $n} end end end;
(if type != "object" then e("$"; "wrong_type"; "an object is expected") else
  (only_keys(["schema_version", "vms", "links"]; "$")),
  (if has("schema_version") | not then e("$.schema_version"; "missing_key"; "required")
   elif (.schema_version | type) != "number" or .schema_version != (.schema_version | floor) then e("$.schema_version"; "wrong_type"; "an integer is expected")
   elif .schema_version < '"$APPLY_SCHEMA_VERSION"' then e("$.schema_version"; "unsupported_schema_version"; "the format changed: this version reads schema_version '"$APPLY_SCHEMA_VERSION"' only, a list of VMs that hold their components (see docs/spec-config.md#compatibility)")
   elif .schema_version > '"$APPLY_SCHEMA_VERSION"' then e("$.schema_version"; "unsupported_schema_version"; "\(.schema_version) is newer than the supported version '"$APPLY_SCHEMA_VERSION"'")
   else empty end),
  (if has("vms") | not then e("$.vms"; "missing_key"; "required: the list of VMs")
   elif (.vms | type) != "array" then e("$.vms"; "wrong_type"; "an array is expected")
   else vm_errs, dup_vms end),
  (if has("links") and (.links | type) != "array" then e("$.links"; "wrong_type"; "an array is expected") else empty end),
  link_errs
end) | addvm'

# The definitions on top of APPLY_COMMON_JQ for the links of the file, see
# docs/spec-config.md#links: `resolved_links` (the links whose two references
# resolve, with what they designate) and `steps_links` (the ones whose chat
# interface is on another VM than the engine of their model, and whose engine is
# not protected: the next steps of docs/spec-multi-vm.md are given for these). The
# errors of the links themselves are in APPLY_VALIDATE_JQ. Needs `$desc`, like it.
# Used by install_scripts/lib/cli-ai.sh.
# shellcheck disable=SC2016,SC2034
readonly APPLY_LINKS_JQ='
def fld($o; $k): if ($o | type) == "object" then $o[$k] else null end;
def protected($en): ($desc[$en.comp].endpoint.protected // false);
def resolved_links: [(($cfg.links // []) | if type == "array" then to_entries[] else empty end) | .key as $i | .value as $l
  | select($l | type == "object")
  | (first(vmlist[] | select(.vname != null and .vname == fld($l.model; "vm_ref"))) // null) as $mx
  | (first(vmlist[] | select(.vname != null and .vname == fld($l.chat_interface; "vm_ref"))) // null) as $cx
  | select($mx != null and $cx != null)
  | (first(comps[] | select(.vi == $mx.vi and .name != null and .name == fld($l.model; "component_ref") and .type == "engine")) // null) as $en
  | (first(comps[] | select(.vi == $cx.vi and .name != null and .name == fld($l.chat_interface; "component_ref") and .type == "chat-interface")) // null) as $ch
  | select($en != null and $ch != null)
  | (first(($en.c.models // [])[]? | select(type == "object" and .name != null and .name == fld($l.model; "model_ref"))) // null) as $m
  | select($m != null)
  | {i: $i, mvi: $mx.vi, mvn: $mx.vname, en: $en, model: $m, mref: $l.model.model_ref, cvi: $cx.vi, cvn: $cx.vname, ch: $ch, l: $l}];
def steps_links: [resolved_links[] | select(.mvi != .cvi and (protected(.en) | not))];
'

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
    done < <(jq -r '(.vms // []) | if type == "array" then .[] else empty end | select(type == "object") | (.components // []) | if type == "array" then .[] else empty end
        | select(type == "object" and (.component | type) == "string") | .component | split("/") | select(length == 2) | [.[0], .[1]] | @tsv' <<<"$1")
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

# apply_ranks: the rank 1 proxy and provisioning component, as {proxy, provisioning}
# (null when none is shipped), for the messages that say what to add.
apply_ranks() {
    local p="" f=""
    if declare -F rank_lookup >/dev/null; then
        p="$(rank_lookup proxy)"
        f="$(rank_lookup provisioning)"
    fi
    jq -nc --arg p "$p" --arg f "$f" '{proxy: (if $p == "" then null else $p end), provisioning: (if $f == "" then null else $f end)}'
}

# apply_problems <config> <desc> [<reqs> [<hostids>]]: the problems as a JSON
# array of {path, code, message} (plus the `vm` they are about when it has a
# name). <reqs> (true or false, default false) also reports the
# requirements nothing satisfies and what a model needs (a proxy, a provisioning
# component), which `apply` and the generator check later with their own exit
# code (apply_order, add).
apply_problems() {
    jq -c --argjson desc "$2" --argjson installed "$(installed_by_type)" --argjson reqs "${3:-false}" \
        --argjson hostids "${4:-[]}" --argjson ranks "$(apply_ranks)" "$APPLY_VALIDATE_JQ" <<<"$1" | jq -sc .
}

# apply_vms <config>: the VM names of a file, one per line, in the order they
# appear. Nothing for a file whose VMs have none.
apply_vms() {
    jq -r --argjson installed '{}' "$APPLY_VMS_JQ" <<<"$1" 2>/dev/null || true
}

# apply_vmcount <config>: the number of VMs of a file.
apply_vmcount() {
    jq -r --argjson installed '{}' "$APPLY_VMCOUNT_JQ" <<<"$1" 2>/dev/null || printf 0
}

# apply_named <config>: succeeds when the file names its VMs (at least one has a `name`).
apply_named() {
    [[ "$(jq -r --argjson installed '{}' "$APPLY_NAMED_JQ" <<<"$1" 2>/dev/null || true)" == true ]]
}

# apply_slice <config> <vm>: the file of that VM (<vm> empty: the only VM of the
# file), see spec-config.md#slices.
apply_slice() {
    jq -c --arg vm "$2" --argjson installed '{}' "$APPLY_SLICE_JQ" <<<"$1"
}

# apply_select_vm <config> <vm> <need-vm>: exit 2 when --vm does not fit the file: a name
# no VM has, or (when <need-vm> is 1, the machine is this one) missing for a file that
# has several VMs. A file with one VM needs no --vm.
apply_select_vm() {
    local config="$1" vm="$2" need="$3" names
    names="$(apply_vms "$config" | paste -sd, - | sed 's/,/, /g')"
    if [[ -n "$vm" ]]; then
        grep -qxF -- "$vm" < <(apply_vms "$config") || fail "$EXIT_USAGE" "--vm $vm: no VM has that name (the file names: ${names:-none})"
    elif ((need)) && (($(apply_vmcount "$config") > 1)); then
        fail "$EXIT_USAGE" "the configuration has several VMs (${names:-none}): select one with --vm <name>"
    fi
}

# apply_validate <config> <desc> [<vm>]: print the problems, exit 2 when any. With
# <vm> only the problems of that VM, and those of no VM, are reported.
apply_validate() {
    local problems line
    problems="$(apply_problems "$1" "$2" | jq -r --arg vm "${3:-}" '.[] | select($vm == "" or .vm == null or .vm == $vm) | "\(.path): \(.message)"')"
    if [[ -n "$problems" ]]; then
        while IFS= read -r line; do log_error "$line"; done <<<"$problems"
        fail "$EXIT_USAGE" "the configuration is invalid"
    fi
}

# apply_validate_models_need <config> <desc>: print what a model needs and the
# file does not give (a proxy, a provisioning component, see spec-config.md), exit
# 2 when any. `script` refuses such a file before writing a script,
# where `apply` leaves it to the model step and its exit 4.
apply_validate_models_need() {
    local problems line
    problems="$(apply_problems "$1" "$2" true | jq -r '.[] | select(.code == "missing_requirement" and (.path | test("\\.models\\[[0-9]+\\]$"))) | "\(.path): \(.message)"')"
    if [[ -n "$problems" ]]; then
        while IFS= read -r line; do log_error "$line"; done <<<"$problems"
        fail "$EXIT_USAGE" "the configuration is invalid"
    fi
}

# apply_components <config>: "type implementation" lines of the components of the
# (one-VM) configuration, in the order of the file.
apply_components() {
    jq -r '(.vms[0].components // [])[] | .component | split("/") | "\(.[0]) \(.[1])"' <<<"$1"
}

# apply_order <config> <desc>: "type implementation" lines, requirements first. A
# requirement neither installed nor listed is exit 4. <config> is the slice of one VM.
apply_order() {
    local config="$1" desc="$2" pending=() placed=() line type name req ok progress i rtype
    while IFS= read -r line; do pending+=("$line"); done < <(apply_components "$config")
    reqs_of() { jq -r --arg k "$1/$2" '.[$k].requires[]?' <<<"$desc"; }
    # Fail early on a requirement that nothing satisfies.
    for line in "${pending[@]}"; do
        read -r type name <<<"$line"
        while IFS= read -r req; do
            [[ -n "$req" ]] || continue
            if is_installed "$req"; then continue; fi
            if jq -e --arg r "$req" '(.vms[0].components // []) | any((.component | split("/")) as $p | $p[1] == $r or $p[0] == $r)' <<<"$config" >/dev/null; then continue; fi
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

# apply_install_args <config> <type> <implementation>: print the install arguments,
# one per line; secrets from the environment are exported by apply_export_secrets.
apply_install_args() {
    jq -r --arg k "$2/$3" '
        (.vms[0].components[] | select(.component == $k)) as $c
        | (if $c.default == true then ["--default"] else [] end)
          + [($c.options // {}) | to_entries[] | .key as $k | .value as $v
             | if ($v | type) == "object" then
                 (if $v.file then ["--\($k)-file", $v.file] else [] end)
               else ["--\($k)", ($v | tostring)] end | .[]]
        | .[]' <<<"$1"
}

# apply_export_secrets <config> <type> <implementation>: secrets given by environment
# variable reach the script through its own EASY_CS_AI_<COMPONENT>_<OPTION>.
apply_export_secrets() {
    local k src
    while IFS=$'\t' read -r k src; do
        [[ -n "$k" ]] || continue
        if [[ -z "${!src+x}" ]]; then
            fail "$EXIT_USAGE" "option $k of $3 reads the environment variable $src, which is not set"
        fi
        export "$(option_var "$3" "$k")=${!src}"
    done < <(jq -r --arg k "$2/$3" '(.vms[0].components[] | select(.component == $k) | (.options // {}) | to_entries[] | select((.value | type) == "object" and .value.env) | [.key, .value.env] | @tsv)' <<<"$1")
}

# apply_models <config>: "model<TAB>engine<TAB>chat-or-null<TAB>force" lines for the
# (one-VM) configuration: the models held by its engines, the implementation of the
# engine that holds each one, of the chat interface its link designates ("null" with
# no link in the slice), and `force`. The free names of a file are resolved here,
# `add` knows the implementations only (spec-config.md#apply, step 4).
apply_models() {
    jq -r --argjson links "$(jq -c '.links // []' <<<"$1")" '
        (.vms[0] // {}) as $vm | ($vm.name // null) as $vn | ($vm.components // []) as $cs
        | $cs[] | select(.component | startswith("engine/")) | . as $en
        | (.models // [])[] | . as $m
        | ([$links[] | select(.model.component_ref == $en.name and .model.model_ref == $m.name and .model.vm_ref == $vn)
            | .chat_interface.component_ref] [0]) as $cr
        | ((if $cr == null then null else ([$cs[] | select(.name == $cr and (.component | startswith("chat-interface/"))) | .component | split("/")[1]][0]) end) // "null") as $chat
        | [$m.model, ($en.component | split("/")[1]), $chat, (($m.force // false) | tostring)] | @tsv' <<<"$1"
}

# apply_prune <config>: <config> is the slice of the VM.
apply_prune() {
    local config="$1" t n m e
    local -A in_file=()
    while read -r t n; do [[ -n "$n" ]] && in_file["$n"]=1; done < <(apply_components "$config")
    # models of the listed engines that the file does not name
    for e in $(jq -r '(.vms[0].components // [])[] | select(.component | startswith("engine/")) | .component | split("/")[1]' <<<"$config"); do
        is_installed "$e" || continue
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            if ! jq -e --arg e "engine/$e" --arg m "$m" '(.vms[0].components // []) | any(.component == $e and ((.models // []) | any(.model == $m)))' <<<"$config" >/dev/null; then
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
    local source="" prune=0 vm="" arg config desc order line type name start=$SECONDS rc=0 model engine chat force
    while [[ $# -gt 0 ]]; do
        arg="$1"
        shift
        case "$arg" in
        --prune) prune=1 ;;
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
    [[ -n "$source" ]] || fail "$EXIT_USAGE" "apply needs a configuration file" "easy-cs-ai apply <file|->"
    read_config "$source"
    config="$CONFIG_TEXT"
    ((CONFIG_NOT_JSON)) || apply_select_vm "$config" "$vm" 1
    if ((DRY && _OPT_JSON)); then
        # the document of `config validate --target this`; a requirement nothing satisfies keeps the exit code 4
        local doc
        if ((CONFIG_NOT_JSON)); then
            doc="$(not_json_document this)"
        else
            doc="$(config_report "$config" this "$( ((prune)) && printf true || printf false)" "$vm")"
        fi
        printf '%s\n' "$doc"
        return "$(config_exit_code "$doc" "$EXIT_PRECONDITION")"
    fi
    ((!CONFIG_NOT_JSON)) || fail "$EXIT_USAGE" "the configuration is not valid JSON"
    desc="$(apply_describes "$config")"
    apply_validate "$config" "$desc" "$vm"
    # the file goes on as the slice of the selected VM
    config="$(apply_slice "$config" "$vm")"
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
        done < <(jq -r --argjson desc "$desc" "$CONFIG_WARNINGS_JQ | .[] | \"\\(.component) --\\(.option)=\\(.value): \\(.message)\"" <<<"$config")
        return 0
    fi
    log_event "apply start components=$(apply_components "$config" | grep -c .) models=$(printf '%s\n' "$models" | grep -c .) prune=$( ((prune)) && printf true || printf false)$([[ -z "$vm" ]] || printf " vm=%s" "$vm")"
    local step=0 steps
    steps=$(($(apply_components "$config" | grep -c . || true) + $(printf '%s\n' "$models" | grep -c . || true)))
    while read -r type name; do
        [[ -n "$name" ]] || continue
        local args=()
        mapfile -t args < <(apply_install_args "$config" "$type" "$name")
        step=$((step + 1))
        progress "$step" "$steps" "install $type $name"
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
            step=$((step + 1))
            progress "$step" "$steps" "add $model to $engine"
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
    if ((rc == 0)); then
        printf '%s %s %s\n' "$(sym ok)" "$(style ok applied)" "$(style dim "$step steps")" >&2
    else
        printf '%s %s %s\n' "$(sym error)" "$(style error stopped)" "$(style dim "at step $step of $steps")" >&2
    fi
    log_event "apply end exit=$rc duration=$((SECONDS - start))s"
    return "$rc"
}
