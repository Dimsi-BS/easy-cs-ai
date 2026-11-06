# Spec: capabilities of the CLI

[← Back to docs](README.md)

**Status:** accepted, implemented for the format of version 1 (`install_scripts/lib/cli-ai.sh`, tested in `tests/unit/cli_ai.bats`). **Format version 2 of the configuration is decided, not implemented** ([spec: config](spec-config.md#format)): the documents below are written for it (`plan.vms` always, models with their resolved engine, `plan.links` made of the new links (a model shown in a chat interface), the codes of the new format), and what the implementation still does for version 1 (`plan.links` made of pairs of VMs, the `vm` of the schema, the `link_*`, `unlinked_vm`, `engine_unreachable`, `missing_vm`, `engine_other_vm` and `chat_interface_other_vm` codes) goes away with it. The `next_steps` and the cross-VM warnings are computed per link whose two VMs differ; the `missing_requirement` of a model whose proxy or provisioning component is not in the file ([spec: config](spec-config.md#what-a-model-needs); `apply` keeps its exit 4 at the model step), and the `models_not_checked` warning of the validation, are proposed.

## Purpose

The CLI is **self-describing and scriptable**: it can tell what exists, what is valid and what happened, to a person at a terminal as well as to a program, or to an AI agent with a shell on a machine where only the installed package exists (no repository, no docs). This spec lists those **capabilities**. Each one is a command with its inputs, **one document** as its result, its errors with a stable `code`, and its warnings. A capability does not know who reads it.

How a capability is shown is the [rendering](spec-rendering.md) (text and questions for a person, `--json` for a program). In which order the capabilities are called to take a user from a need to a stack is the [journey](spec-journey.md). Neither is repeated here. Every command below is read-only; the changing commands keep their behaviour and gain a [result document](#result-of-the-changing-commands).

The [configuration file](spec-config.md) is the single target the journey produces (JSON, never bash), `apply --dry-run` is its validator, `script` turns it into scripts.

It builds on the [CLI spec](spec-cli.md), the [script contract](spec-script-contract.md) (`describe`, exit codes) and the [configuration spec](spec-config.md); it does not repeat them. Everything is derived from the shipped scripts (their `describe`, `ranks.conf`, `default-models.conf`), never hardcoded, as for [dispatch](spec-cli.md#dispatch).

## Commands

| Command | Role | Root |
| --- | --- | --- |
| `catalog [--json]` | What can be installed: components, options, ranks, default models, platforms | no |
| `host [--json]` | What this machine is: platform, CPU, memory, disk, GPU | no |
| `config schema` | The configuration format, as a JSON Schema generated from the catalog | no |
| `config validate <file\|-> [--target this\|fresh] [--vm <name>] [--json]` | Validate a configuration and show its plan, without side effect. The file is validated one VM at a time, see [spec: several VMs](spec-multi-vm.md) | no |
| `guide` | The procedure of the [journey](spec-journey.md) as text, for a reader that is a model, see [rendering](spec-rendering.md#guide) | no |
| `apply <file\|-> --dry-run --json` | The same document as `config validate --target this` | no |
| `script <file> [--dry-run] --json` | Validation (target `fresh`), then the script: the document of `config validate` with a `script` entry (`path`, `bytes`, `written`, `package_version`, `package_format`), `null` when the file is not valid. `script` is `null` and `scripts` lists one such entry per VM (with its `vm_ref`, one entry for a file of one VM), and `next_steps` gives the [instructions](spec-multi-vm.md#next-steps) as an array of strings (`[]` with one VM); for an invalid file, `scripts` and `next_steps` are `[]`. `config` has no `--json` (a session is interactive, exit 2) | no |

`catalog`, `host`, `config` and `guide` join the reserved words of [spec: CLI](spec-cli.md#command-line).

### `catalog`

Without `--json`, a table (type, name, rank, description, platforms, requires). With `--json`:

```json
{
  "schema_version": 1,
  "cli_version": "0.1.0-rc3",
  "types": ["provisioning", "proxy", "engine", "chat-interface"],
  "components": [
    {
      "type": "engine",
      "name": "ollama",
      "rank": 1,
      "default_model": "llama3.2:3b",
      "describe": { "...": "the describe of the script, verbatim" }
    }
  ]
}
```

- `components` lists the scripts **shipped** (`<libdir>/<type>/<name>.sh`). A component that has a rank in `ranks.conf` but no script (vLLM, AnythingLLM today) is absent: the catalog is what can be installed now.
- `rank` is the position in `ranks.conf` within its type (1 = what `install --defaults` picks), `null` when not ranked. `default_model` is present for engines with a line in `default-models.conf`.
- `describe` is the script's own output, so options, `secret`, `warn`, `requires`, `platforms` and `provides` have one source ([contract](spec-script-contract.md#describe)).
- The order is the types in install order (`provisioning`, `proxy`, `engine`, `chat-interface`), then by rank. The `rank` counts the shipped components of the type only, so a ranked component that has no script yet leaves no hole.
- The catalog says nothing about the machine: whether a component is installed is `status --json`, and whether a model fits is [model fit](spec-model-fit.md#model-fit-for-a-machine-that-is-not-this-one).

### `host`

Facts to choose components and models. Without `--json`, a few readable lines.

```json
{
  "schema_version": 1,
  "platform": { "id": "ubuntu", "version": "24.04", "arch": "x86_64", "systemd": true },
  "cpu": { "cores": 4, "model": "…" },
  "ram_mb": 7936,
  "disk": { "path": "/var/lib/easy-cs-ai", "free_mb": 48210 },
  "gpus": [ { "vendor": "nvidia", "name": "…", "vram_mb": 24576 } ],
  "root": false,
  "docker": { "installed": false }
}
```

- Best effort and read-only: `/etc/os-release`, `/proc`, `df`, `nvidia-smi` / `lspci` when present. A fact that cannot be determined is `null`, **never guessed**. `gpus` is `[]` when there is none.
- `disk.path` is the path where data would live (the data directory of the CLI; `/var` when it does not exist yet).
- These are the facts of the machine running the command. For another machine, the user gives its specs (see the [journey](spec-journey.md#1-discover)), and the models are sized for them by [model fit](spec-model-fit.md#model-fit-for-a-machine-that-is-not-this-one).

### `config schema`

Prints the JSON Schema (draft 2020-12) of the configuration, **generated at run time** from the shipped `describe`s, so it is true for this version of the package and needs no repository:

- the structure of [spec: config](spec-config.md#format) (`schema_version` 2, `vms`, the `models` held by the `engine` components, the fields and their rules);
- for `component`, an `enum` of the values `<type>/<implementation>` of the shipped scripts (`engine/ollama`, `proxy/nginx`…), so that a program validates the notation without parsing it;
- for each shipped component, its options: names, types and `values`/`default` as the schema's `enum`/`default`, the secret options as the `file` / `env` / `generate` object, and the option `description`s as the schema's `description`; an option with a `required_when` is encoded as a conditional requirement (`if` / `then` / `required`) on the entry, so that a program learns before writing a file which options a choice makes mandatory (`tls: letsencrypt` makes `tls-accept-terms` and `server-name` required, `tls: provided` makes `tls-cert` and `tls-key` required, the latter as a `file` or an `env` only since the option declares `"sources": ["file", "env"]`, which `config schema` encodes as the allowed forms of the secret object); a `relevant_when` is carried as an annotation only;
- the name of a VM and the `name` of a component (both optional, the name of a VM being required by a conditional node when the file has several VMs), as strings of the shape given in [spec: config](spec-config.md#vms); the `links` array (each entry `{ "model": { "vm_ref", "component_ref", "model_ref" }, "chat_interface": { "vm_ref", "component_ref" } }`, the references of [spec: config](spec-config.md#references), **all fields required**, so the schema lists them as `required` and a reference with a field missing is refused before any rule is run); the `models` array only on the `engine/*` components (a conditional node, as for `required_when`), each model with `model` (required), `name` (a free string: any non-empty string without control characters, the form of the instance's name being freer than that of a VM or a component), `force` and a reserved `options` (no property while no engine declares model options, see [spec: config](spec-config.md#models));
- the rules that cannot be expressed as a schema (unique names of VMs and of components in a VM, one component per implementation on a VM for now, at most one `default` per type and per VM, `requires`, at most one link per model for now, unique links, unique names of models in an engine, the resolution of the references) as `description` text on the relevant node, and enforced by `config validate`.

The schema is a **help to write a file**, `config validate` is the judge: the schema may be less strict, never stricter.

### `config validate`

```text
easy-cs-ai config validate <file|-> [--target this|fresh] [--vm <name>] [--json]
```

The validation and the plan that `apply` runs before any side effect, as a command of its own. `-` reads stdin.

- `--target this` (default) validates against this machine: a component already installed satisfies a requirement, exactly as `apply` does. `--target fresh` validates as for a new VM, ignoring what is installed (the generator's `EASY_CS_AI_ASSUME_EMPTY` mode, see [spec: VM script generator](spec-vm-generator.md#implementation-notes)): **this is the one for a fleet**.
- `apply <file> --dry-run --json` prints the same document as `--target this`, so a program can use either.
- Exit code: 0 when `ok`, 2 when there is an error.
- **A file is validated one slice at a time**, each as for a fresh VM ([spec: config](spec-config.md#slices)). `--vm <name>` validates that slice alone, and is required with `--target this` when the file has several VMs (which means "this machine", so one VM; exit 2 otherwise); with one VM it is not needed. A name no VM has is exit 2 too, as for `apply`, with the VM names of the file in the message and no document. `plan` is `{ "vms": [ { "name": "gpu", "components": […], "models": […], "prune": false } ] }`, one entry per VM, each entry shaped like the plan of one machine, in the order of the file (one entry for a file of one VM). Each component of `components` carries its `component` and its `name` (`null` when it is unnamed: the `component` is then its label), and each model of `models` carries its `model` and its `engine` (the component that holds it) **as resolved**, and `plan.links` lists the links **as resolved**, each as `{ "model": { "vm_ref", "component_ref", "model_ref", "component" }, "chat_interface": { "vm_ref", "component_ref", "component" } }`, every reference being a **complete reference**, `{ "vm_ref", "component_ref", "component" }` (with `model_ref` for a model) (the same fields as in the file: `vm_ref` the name of the VM, `null` for a lone VM that has none; `component_ref` the `name` of the component, `null` when it has none; and `component`, the `<type>/<implementation>`, an addition of the output that says what it is when it has no name; the component) ([spec: config](spec-config.md#references)), so a program reads where each model goes and where it is shown without redoing the resolution. `plan` is `{ "vms": […], "links": […] }`: the links are at the root of the plan, as in the file. Errors and warnings keep the paths of the file as written, and carry the `vm_ref` of the VM they are about (`null` for a lone VM that has no name). The document also gains `next_steps`, an array of strings: what the administrator still has to do by hand once the VMs are up, computed by the validation from the links whose chat interface is on another VM than the model's engine and the shipped `describe`s, with no script written, so it holds no script name ([spec: several VMs](spec-multi-vm.md#next-steps)). They are computed on the whole file: with `--vm`, which validates one slice alone, `next_steps` is `[]` and the `engine_address_unknown` warning, which needs the other VMs, is not given. A file whose links all stay on the VM of their engine (or that has none) has `next_steps` `[]`. For a file with errors `next_steps` is `[]`, as `scripts` is for `script`: nothing is planned from a file that is not valid.

Without `--json`, the problems and the plan in human form (the lines `apply --dry-run` prints today); the [next steps](spec-multi-vm.md#next-steps) follow the plan, as that section renders them. With `--json`:

```json
{
  "schema_version": 1,
  "ok": false,
  "target": "fresh",
  "errors": [
    { "path": "$.vms[0].components[2].options.port", "vm_ref": "gpu", "code": "wrong_type", "message": "an integer is expected" }
  ],
  "warnings": [
    {
      "path": "$.vms[1].components[1]",
      "vm_ref": "web",
      "component_ref": "librechat",
      "component": "chat-interface/librechat",
      "option": "allow-registration",
      "value": "true",
      "message": "Registration is open: the first account becomes the administrator…"
    }
  ],
  "plan": {
    "vms": [
      {
        "name": "gpu",
        "components": [
          { "order": 1, "component": "provisioning/llmfit", "name": null, "options": {}, "default": false }
        ],
        "models": [
          { "model": "llama3.2:3b",
            "engine": { "vm_ref": "gpu", "component_ref": null, "component": "engine/ollama" },
            "force": false }
        ],
        "prune": false
      }
    ],
    "links": [
      { "model": { "vm_ref": "gpu", "component_ref": null, "model_ref": "llama3.2:3b", "component": "engine/ollama", "model": "llama3.2:3b" },
        "chat_interface": { "vm_ref": "web", "component_ref": "librechat", "component": "chat-interface/librechat" } }
    ]
  }
}
```

- `errors` lists **every** problem at once, each with its JSON `path` (the same paths as today), a stable `code` and the `message` (the text the human form prints). `plan` is `null` when there is an error: nothing is planned from a file that is not valid.
- `warnings` are the `warn` entries of `describe` whose condition holds for the **effective** value (a default included), as in the summary of a session, so that they can be shown to the user before anything is applied. They do not change the exit code. A warning may also come from the validation itself, and then carries a `code` (`engine_address_unknown`, see [spec: several VMs](spec-multi-vm.md#validation), and `models_not_checked`, see [spec: model fit](spec-model-fit.md#llmfit-is-optional), which is built by the session's summary today and moves here, proposed) in place of `option` and `value`; it carries the `vm` too.
- `plan.components` is in install order, with the options as written in the file, a secret shown as its source; when the target is `this`, each entry also says whether it is already installed (`"installed": true | false`, absent for `fresh`); whether an installed one is left alone or reconfigured is the script's own [idempotence](spec-script-contract.md#idempotence), which the CLI does not compare. The order is the install order of `apply`: a component comes after the ones it requires, otherwise in the order of the file. `plan.vms[].models` is **a flat list** of the models of the VM, taken from the `models` of its engines, each with its engine as resolved (`engine`, `{ "vm_ref", "component_ref", "component" }`) (the links are in `plan.links`): it is an output document, the file holds each model inside its engine and the links apart.
- **Codes** (closed list, a new one is not a bump of `schema_version`): `not_json`, `wrong_type`, `unknown_key`, `unknown_type`, `unknown_component`, `unknown_option`, `secret_literal`, `secret_source`, `unsupported_schema_version` (also for a file of version 1, whose format is no longer read, [spec: config](spec-config.md#compatibility)), `duplicate_vm`, `missing_vm_name` (a VM with no `name` in a file of several VMs), `empty_vm`, `duplicate_name`, `duplicate_component`, `several_defaults`, `unknown_vm`, `models_on_non_engine` (a `models` on a component that is not of type `engine`), `protected_engine_other_vm` (a link of a model of a `protected` engine to a chat interface of another VM), `unresolved_chat_interface`, `unresolved_engine`, `unresolved_model` (the engine of a link does not hold that model), `missing_key` (a required field that is not written, in a reference of a link among others: [References](spec-config.md#references)), `duplicate_link` (the same pair of model and chat interface, once resolved, written twice), `unsupported_count` (a second link of the same model: more than the validation accepts for now), `missing_option` (an option that the component requires, by its `required_when`, left out of the entry's `options`), `duplicate_model` (the same `model` twice in one engine), `missing_requirement` (also, proposed, for a model whose proxy or provisioning component is not in the file, at the path of the model, see [spec: config](spec-config.md#what-a-model-needs)), `unsupported_platform`, `invalid_value` (an option outside `values`, not an integer…), `circular_requirement`, and for the validation of several VMs `duplicate_server_name`. The implementation attaches a code to each message of the validation program; the human text does not change.
- `unsupported_platform` compares the `platforms` of the component with `ID` and `ID_LIKE` of `/etc/os-release`, only for `--target this`, and not in test mode (`EASY_CS_AI_ROOT`), as the scripts' own platform check. `EASY_CS_AI_HOST_IDS` (space separated) replaces the detection, for the tests.
- With `apply`, a requirement that nothing satisfies keeps its exit code 4 (see [spec: config](spec-config.md#semantics-converge)): `apply --dry-run --json` prints the same document and exits 4 when `missing_requirement` is the only kind of error, 2 otherwise. `config validate` and `script` exit 2 for it (for a model whose proxy or provisioning component is missing, proposed: until then they accept such a file).
- Not covered, as today: a `file` secret whose path is checked at run time only.

## Result of the changing commands

`install`, `uninstall`, `add`, `remove` and `apply` (not dry-run), run with `--json`, print one document **at the end, whatever the outcome**, so a program never has to parse stderr to know what happened:

```json
{
  "schema_version": 1,
  "command": "apply",
  "ok": false,
  "exit": 5,
  "failed_step": "install engine ollama",
  "message": "download failed (exit 5: network or download failure)",
  "steps": [
    { "step": "install provisioning llmfit", "exit": 0 },
    { "step": "install proxy nginx", "exit": 0 },
    { "step": "install engine ollama", "exit": 5 }
  ],
  "rollback_complete": true
}
```

- `exit` is the process exit code, `message` the first stderr line of the failure, `failed_step` and `message` are `null` on success, `rollback_complete` is `false` for exit 7 (see [spec: CLI](spec-cli.md#exit-codes)). `steps` lists what ran, in order, with the labels the journal uses.
- With `--dry-run`, these commands print their **plan** as the document: `{ "schema_version": 1, "command": "...", "dry_run": true, "plan": [ { "step": "…" } ] }`; for `apply` it is the `config validate` document.
- `steps` are the actions run on the components (what `run_script` ran, labelled `<action> <type> <name>`, e.g. `add-upstream proxy nginx`), recorded as they run. A failure that happens outside a component action (a missing requirement of `add`) names, for `apply`, the step of the file that failed (`add m1`) in `failed_step`.
- The dry-run plan is made of the plan lines of the CLI and of the components (`plan: …`, `dry run: …`). `--dry-run` given **after** `install` or `uninstall` is the components' own (they print their own plan); given before the command, or after the other commands, it is the CLI's.
- Interruption (130, 143) prints the same document with `ok: false`.
- Not changed: a component action keeps the JSON of the script (`status`, `list-models`…), and `status --json` stays as specified.

## Model fit and VM sizing

Which models fit a machine, and what VM some models need, are capabilities too: the actions `suggest`, `check`, `plan` and `size` of `provisioning llmfit`, with the `--target-*` options to size for a machine that is not this one. They are specified in [spec: model fit](spec-model-fit.md), and their documents follow the same conventions as the ones above. `plan` sizes a stack from the `resources` each component declares in its `describe` (proposed, see [declared resources](spec-model-fit.md#declared-resources)), which `catalog` therefore carries as it carries the rest of the `describe`.

## Contract addition: typed options in `describe`

`describe` options carry today a `default` that is always a string (`"11434"`, `"true"`), so a program cannot tell an integer or a boolean from a text, and validation can only say "a string, number or boolean". Each option gains, additively (no bump of `schema_version`, like `warn`):

| Field | Meaning |
| --- | --- |
| `type` | `string` (default when absent), `integer`, `boolean`, `enum` |
| `values` | The allowed values, for `enum` |
| `min`, `max` | Bounds, for `integer` |
| `relevant_when`, `required_when` | `{ "option": …, "values": […] }` or a list of them: when the option matters, and when it is required, see the [contract](spec-script-contract.md#describe). `catalog` carries them verbatim. `required_when` is checked by `config validate` (code `missing_option`) and encoded by `config schema`; `relevant_when` is read by the session only, it never refuses a file |
| `repeatable` | `true` when an **action** option may be given several times (default `false`; never on an option of the configuration), see the [contract](spec-script-contract.md#describe). `catalog` carries it verbatim; it has no `config schema` or `config validate` effect, since those concern the options of the configuration |

The scripts already validate these values at run time; `type` makes it available beforehand to `catalog`, `config schema` and `config validate` (code `invalid_value`). Every shipped script gets its options typed with this change. In the configuration, a typed option accepts the JSON type that matches (`11434` or `"11434"` for an integer, `true` or `"true"` for a boolean): the CLI passes the text.

## Secrets

Whoever writes the configuration, a person or a program, for one machine or a fleet: **a literal secret is never allowed in it**. Only the three sources of [spec: config](spec-config.md#secrets) exist (`file`, `env`, `generate`); a plain value is the validation error `secret_literal`, as it is today, and this becomes the rule rather than the open question. It settles in the same way the [question of the generator](spec-vm-generator.md#open-questions), and the user-data caveat of the [contract](spec-script-contract.md#secrets): what the agent writes into a script is readable by anyone who reads the user-data.

A program that needs a secret known in advance (rare) asks the user and uses `env` or `file`, never a value in the file nor on a command line. Generated secrets are retrieved with the dedicated actions (`component proxy nginx show-key`), which a program does not run unless the user asks, since it prints a secret.

## Definition of done

- `bats` tests in `EASY_CS_AI_ROOT` mode with fake components: `catalog` (shipped only, ranks, default model, order, `describe` verbatim, unranked, no root), `host` (fake `/proc` and `/etc/os-release`, a fact that cannot be read is `null`, no GPU), `config schema` (valid JSON Schema, options typed from `describe`, secret objects), `config validate` (every `code`, every path, several errors at once, `plan` null on error, warnings on a default value, `--target this` versus `fresh`, stdin, exit codes, no root), the result document of each changing command for success, a failing step, exit 7 and interruption, the dry-run plans.
- A schema check: a configuration accepted by `config validate` is accepted by `config schema`'s schema, and vice versa for every error code except those the schema cannot express.
- Every shipped `describe` validates against the typed-option rules.
- Integration test on a VM: the [journey](spec-journey.md) run end to end by a script that plays a program (catalog, host, validate, apply with `--json`, status).
- `bats` tests of the format of version 2 in `config schema` (the `enum` of `component`, `models` only on engines, the references) and `config validate` (the errors and codes of [spec: config](spec-config.md#format), `--vm`, `plan.vms` and `plan.links` with the resolved references, the `engine_address_unknown` warning, not given with `--vm`, the `missing_requirement` of a model, `missing_option` for each `required_when` of the shipped components (and not raised when the condition does not hold, so `tls-cert` with the default `self-signed` is accepted), the encoding of `required_when` in `config schema`, `next_steps` (`[]` for an invalid file or when every link stays on its engine's VM, printed after the plan without `--json`), `--vm` with an unknown name, the `models_not_checked` warning per slice) and of the `scripts` and `next_steps` of `script --json`, as listed in [spec: several VMs](spec-multi-vm.md#definition-of-done).
- `shellcheck` clean; the `--help` of each command and `guide` consistent with this spec.

## Open questions

- **Large catalog.** `catalog --json` embeds every `describe`; if it grows too large for a model's context, add `catalog --json <type> [<name>]` to narrow it. Not needed with four components.
- **Hardware detection on a GPU machine** is untested (the project has only run on CPU, see the [status](../README.md)); `host` reports what `nvidia-smi` / `lspci` give and `null` otherwise.
