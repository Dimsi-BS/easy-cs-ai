# Spec: capabilities of the CLI

[← Back to docs](README.md)

**Status:** accepted, implemented (`install_scripts/lib/cli-ai.sh`, tested in `tests/unit/cli_ai.bats`). What concerns several VMs (`--vm`, `plan.vms`, `next_steps`, `scripts`, the `engine_unreachable` warning, the `vm` of the schema) is **proposed, not implemented**, see [spec: two VMs](spec-two-vm.md).

## Purpose

The CLI is **self-describing and scriptable**: it can tell what exists, what is valid and what happened, to a person at a terminal as well as to a program, or to an AI agent with a shell on a machine where only the installed package exists (no repository, no docs). This spec lists those **capabilities**. Each one is a command with its inputs, **one document** as its result, its errors with a stable `code`, and its warnings. A capability does not know who reads it.

How a capability is shown is the [rendering](spec-rendering.md) (text and questions for a person, `--json` for a program). In which order the capabilities are called to take a user from a need to a stack is the [journey](spec-journey.md). Neither is repeated here. Every command below is read-only; the changing commands keep their behaviour and gain a [result document](#result-of-the-changing-commands).

The [configuration file](spec-config.md) is the single target the journey produces (JSON, never bash), `apply --dry-run` is its validator, `generate --config` turns it into a script.

It builds on the [CLI spec](spec-cli.md), the [script contract](spec-script-contract.md) (`describe`, exit codes) and the [configuration spec](spec-config.md); it does not repeat them. Everything is derived from the shipped scripts (their `describe`, `ranks.conf`, `default-models.conf`), never hardcoded, as for [dispatch](spec-cli.md#dispatch).

## Commands

| Command | Role | Root |
| --- | --- | --- |
| `catalog [--json]` | What can be installed: components, options, ranks, default models, platforms | no |
| `host [--json]` | What this machine is: platform, CPU, memory, disk, GPU | no |
| `config schema` | The configuration format, as a JSON Schema generated from the catalog | no |
| `config validate <file\|-> [--target this\|fresh] [--vm <name>] [--json]` | Validate a configuration and show its plan, without side effect. A file that describes several VMs is validated one VM at a time, see [spec: two VMs](spec-two-vm.md) | no |
| `guide` | The procedure of the [journey](spec-journey.md) as text, for a reader that is a model, see [rendering](spec-rendering.md#guide) | no |
| `apply <file\|-> --dry-run --json` | The same document as `config validate --target this` | no |
| `generate --config <file> [--dry-run] --json` | Validation (target `fresh`), then the script: the document of `config validate` with a `script` entry (`path`, `bytes`, `written`, `package_version`, `package_format`), `null` when the file is not valid. For a file that names several VMs, `script` is `null` and `scripts` lists one such entry per VM (with its `vm`), and `next_steps` gives the [instructions](spec-two-vm.md#next-steps) as an array of strings; for an invalid file, `scripts` and `next_steps` are `[]`; with one VM the document is unchanged. `--json` needs `--config` (a session is interactive, exit 2) | no |

`catalog`, `host`, `config` and `guide` join the reserved words of [spec: CLI](spec-cli.md#command-line).

### `catalog`

Without `--json`, a table (type, name, rank, description, platforms, requires). With `--json`:

```json
{
  "schema_version": 1,
  "cli_version": "0.1.0-rc2",
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

- the structure of [spec: config](spec-config.md#format) (`schema_version`, `components`, `models`, the fields and their rules);
- for each shipped component, its options: names, types and `values`/`default` as the schema's `enum`/`default`, the secret options as the `file` / `env` / `generate` object, and the option `description`s as the schema's `description`;
- the optional `vm` of a component and of a model ([spec: config](spec-config.md#several-vms)), as a string of the shape given there;
- the rules that cannot be expressed as a schema (one entry per component and per VM, `vm` on all components or none, at most one `default` per type and per VM, `requires`, the resolution of `engine` and `chat_interface`) as `description` text on the relevant node, and enforced by `config validate`.

The schema is a **help to write a file**, `config validate` is the judge: the schema may be less strict, never stricter.

### `config validate`

```text
easy-cs-ai config validate <file|-> [--target this|fresh] [--vm <name>] [--json]
```

The validation and the plan that `apply` runs before any side effect, as a command of its own. `-` reads stdin.

- `--target this` (default) validates against this machine: a component already installed satisfies a requirement, exactly as `apply` does. `--target fresh` validates as for a new VM, ignoring what is installed (the generator's `EASY_CS_AI_ASSUME_EMPTY` mode, see [spec: VM script generator](spec-vm-generator.md#implementation-notes)): **this is the one for a fleet**.
- `apply <file> --dry-run --json` prints the same document as `--target this`, so a program can use either.
- Exit code: 0 when `ok`, 2 when there is an error.
- **A file that names several VMs** ([spec: config](spec-config.md#several-vms)) is validated one slice at a time, each as for a fresh VM. `--vm <name>` validates that slice alone, and is required with `--target this` (which means "this machine", so one VM; exit 2 otherwise). A name no component has, and `--vm` on a file that names no VM, are exit 2 too, as for `apply`, with the VM names of the file in the message and no document. `plan` then becomes `{ "vms": [ { "vm": "engine", "components": […], "models": […], "prune": false } ] }`, each entry shaped like the `plan` of a one-VM file, in the order the VMs appear. Each model of `models` carries the `vm` and the `engine` it resolved to, the [place of the model](spec-config.md#where-a-model-goes), so a program reads where each model goes without redoing the resolution. Errors and warnings keep the paths of the file as written, and carry the `vm` they are about. The document also gains `next_steps`, an array of strings: what the administrator still has to do by hand once the VMs are up, computed by the validation from the file and the shipped `describe`s, with no script written, so it holds no script name ([spec: two VMs](spec-two-vm.md#next-steps)). They are computed on the whole file: with `--vm`, which validates one slice alone, `next_steps` is `[]` and the `engine_unreachable` warning, which needs the other VMs too, is not given. With one VM, the document is unchanged. For a file with errors `next_steps` is `[]`, as `scripts` is for `generate`: nothing is planned from a file that is not valid.

Without `--json`, the problems and the plan in human form (the lines `apply --dry-run` prints today); for a file that names several VMs, the [next steps](spec-two-vm.md#next-steps) follow the plan, from `What is left to do` on, the same lines as `next_steps`. With `--json`:

```json
{
  "schema_version": 1,
  "ok": false,
  "target": "fresh",
  "errors": [
    { "path": "$.components[2].options.port", "code": "wrong_type", "message": "an integer is expected" }
  ],
  "warnings": [
    {
      "path": "$.components[3]",
      "component": { "type": "chat-interface", "name": "librechat" },
      "option": "allow-registration",
      "value": "true",
      "message": "Registration is open: the first account becomes the administrator…"
    }
  ],
  "plan": {
    "components": [
      { "order": 1, "type": "provisioning", "name": "llmfit", "options": {}, "default": false }
    ],
    "models": [
      { "name": "llama3.2:3b", "engine": "ollama", "chat_interface": "librechat", "force": false }
    ],
    "prune": false
  }
}
```

- `errors` lists **every** problem at once, each with its JSON `path` (the same paths as today), a stable `code` and the `message` (the text the human form prints). `plan` is `null` when there is an error: nothing is planned from a file that is not valid.
- `warnings` are the `warn` entries of `describe` whose condition holds for the **effective** value (a default included), as in the summary of a session, so that they can be shown to the user before anything is applied. They do not change the exit code. A warning may also come from the validation itself, and then carries a `code` (`engine_unreachable`, see [spec: two VMs](spec-two-vm.md#validation), and `models_not_checked`, a model with `force` and no llmfit in its slice, see [spec: model fit](spec-model-fit.md#llmfit-is-optional); the second is built by the session's summary today and moves here, proposed) in place of `option` and `value`; for a file that names several VMs it carries the `vm` too.
- `plan.components` is in install order, with the options as written in the file, a secret shown as its source; when the target is `this`, each entry also says whether it is already installed (`"installed": true | false`, absent for `fresh`); whether an installed one is left alone or reconfigured is the script's own [idempotence](spec-script-contract.md#idempotence), which the CLI does not compare. The order is the install order of `apply`: a component comes after the ones it requires, otherwise in the order of the file. `plan.models` has the names already resolved (`engine`, `chat_interface`).
- **Codes** (closed list, a new one is not a bump of `schema_version`): `not_json`, `wrong_type`, `unknown_key`, `unknown_type`, `unknown_component`, `unknown_option`, `secret_literal`, `secret_source`, `unsupported_schema_version`, `duplicate_component`, `several_defaults`, `unresolved_engine`, `unresolved_chat_interface`, `ambiguous_engine`, `ambiguous_chat_interface`, `missing_requirement` (also for a model whose proxy or llmfit is not in the file, at the path of the model, see [spec: config](spec-config.md#what-a-model-needs)), `unsupported_platform`, `invalid_value` (an option outside `values`, not an integer…), `circular_requirement`, and for a file that names several VMs `missing_vm`, `chat_interface_other_vm`, `engine_other_vm` and `duplicate_model`, plus `unknown_vm`, which a file that names **no** VM raises too when a model carries a `vm`. The implementation attaches a code to each message of the validation program; the human text does not change.
- `unsupported_platform` compares the `platforms` of the component with `ID` and `ID_LIKE` of `/etc/os-release`, only for `--target this`, and not in test mode (`EASY_CS_AI_ROOT`), as the scripts' own platform check. `EASY_CS_AI_HOST_IDS` (space separated) replaces the detection, for the tests.
- With `apply`, a requirement that nothing satisfies keeps its exit code 4 (see [spec: config](spec-config.md#semantics-converge)): `apply --dry-run --json` prints the same document and exits 4 when `missing_requirement` is the only kind of error, 2 otherwise. `config validate` and `generate --config` exit 2 for it.
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

The scripts already validate these values at run time; `type` makes it available beforehand to `catalog`, `config schema` and `config validate` (code `invalid_value`). Every shipped script gets its options typed with this change. In the configuration, a typed option accepts the JSON type that matches (`11434` or `"11434"` for an integer, `true` or `"true"` for a boolean): the CLI passes the text.

## Secrets

Whoever writes the configuration, a person or a program, for one machine or a fleet: **a literal secret is never allowed in it**. Only the three sources of [spec: config](spec-config.md#secrets) exist (`file`, `env`, `generate`); a plain value is the validation error `secret_literal`, as it is today, and this becomes the rule rather than the open question. It settles in the same way the [question of the generator](spec-vm-generator.md#open-questions), and the user-data caveat of the [contract](spec-script-contract.md#secrets): what the agent writes into a script is readable by anyone who reads the user-data.

A program that needs a secret known in advance (rare) asks the user and uses `env` or `file`, never a value in the file nor on a command line. Generated secrets are retrieved with the dedicated actions (`proxy nginx show-key`), which a program does not run unless the user asks, since it prints a secret.

## Definition of done

- `bats` tests in `EASY_CS_AI_ROOT` mode with fake components: `catalog` (shipped only, ranks, default model, order, `describe` verbatim, unranked, no root), `host` (fake `/proc` and `/etc/os-release`, a fact that cannot be read is `null`, no GPU), `config schema` (valid JSON Schema, options typed from `describe`, secret objects), `config validate` (every `code`, every path, several errors at once, `plan` null on error, warnings on a default value, `--target this` versus `fresh`, stdin, exit codes, no root), the result document of each changing command for success, a failing step, exit 7 and interruption, the dry-run plans.
- A schema check: a configuration accepted by `config validate` is accepted by `config schema`'s schema, and vice versa for every error code except those the schema cannot express.
- Every shipped `describe` validates against the typed-option rules.
- Integration test on a VM: the [journey](spec-journey.md) run end to end by a script that plays a program (catalog, host, validate, apply with `--json`, status).
- `bats` tests of the `vm` field in `config schema` and `config validate` (the errors and codes of [spec: config](spec-config.md#several-vms), `--vm`, `plan.vms`, the `engine_unreachable` warning, the `missing_requirement` of a model, `next_steps` (`[]` for an invalid file, printed after the plan without `--json`), `--vm` with an unknown name, the `models_not_checked` warning per slice) and of the `scripts` and `next_steps` of `generate --json`, as listed in [spec: two VMs](spec-two-vm.md#definition-of-done).
- `shellcheck` clean; the `--help` of each command and `guide` consistent with this spec.

## Open questions

- **Large catalog.** `catalog --json` embeds every `describe`; if it grows too large for a model's context, add `catalog --json <type> [<name>]` to narrow it. Not needed with four components.
- **Hardware detection on a GPU machine** is untested (the project has only run on CPU, see the [status](../README.md)); `host` reports what `nvidia-smi` / `lspci` give and `null` otherwise.
