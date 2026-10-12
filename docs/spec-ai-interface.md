# Spec: machine interface of the CLI (for an AI agent or any program)

[← Back to docs](README.md)

**Status:** accepted, implemented (`install_scripts/lib/cli-ai.sh`, tested in `tests/unit/cli_ai.bats`)

## Purpose

An AI agent, with a shell on a machine where **only the installed package exists** (no repository, no docs), helps a user to build a configuration or a VM script and to run it. Nothing but the CLI can tell it what exists, what is valid and what happened. This spec makes the CLI **self-describing and scriptable**, and adds no capability: every new command is read-only, and the changing commands keep their behaviour.

The rule that governs all of it:

> **`--json` is accepted by every command that outputs data, and then stdout carries one JSON document and nothing else.**
> A command that only returns a data structure (`config schema`, the component actions `status`, `list-models`, `check`…) prints JSON by default and takes `--json` as a no-op. A command with a human rendering (tables, plans, hints) prints it without `--json`, and that rendering is not a stable interface. The `provisioning llmfit` actions `suggest` and `plan` are of the second kind: a person reads their text, a program or an agent passes `--json`.

Why the rule is not "no `--json` is always for humans": [decision](decision-json-output-rule.md).

The agent builds on what exists: the [configuration file](spec-config.md) is the single target it produces (JSON, never bash), `apply --dry-run` is its validator, `generate --config` turns the file into a script. This spec fills what it cannot do today, see [Gaps closed](#gaps-closed).

It builds on the [CLI spec](spec-cli.md), the [script contract](spec-script-contract.md) (`describe`, exit codes) and the [configuration spec](spec-config.md); it does not repeat them.

## Conventions of `--json`

- **stdout**: exactly one JSON document, terminated by a newline. **stderr**: unchanged, the human logs (`[LEVEL] message`), also with `--json`. A program reads stdout, and shows stderr to the user when it wants the story.
- **Every document carries `schema_version`** (a number, `1` for all the documents below), like `describe` and `status`. A reader refuses a higher version rather than guessing.
- **Exit codes are unchanged** ([spec: CLI](spec-cli.md#exit-codes)) and remain the primary success signal. `--json` never turns a failure into exit 0.
- **A result is printed even when it is negative.** For the commands below that validate or plan, the document is printed with exit 2 when the input is invalid (the list of problems *is* the result). For anything else that fails (usage error, missing root, network…), stdout stays empty and stderr says why, as today; the changing commands print a [result document](#result-of-the-changing-commands).
- **Secrets are never in a document**, as everywhere ([contract](spec-script-contract.md#secrets)). A secret option appears as its source (`{"env": "NAME"}`…), `"generate"` or `"masked"`, never as a value.
- **Read-only commands need no root and no installed state**: they run on the administrator's machine as well as on the target, which is what the agent needs to prepare a fleet.
- Everything is derived from the shipped scripts (their `describe`, `ranks.conf`, `default-models.conf`), never hardcoded, as for [dispatch](spec-cli.md#dispatch).

- **Where `--json` goes.** Before the command (`easy-cs-ai --json status`) for every command; after it for `status`, `add`, `remove`, `apply`, `catalog`, `host`, `config` and `guide` (the CLI takes it, as it takes `--dry-run` and `--verbose` there), for `install` and `uninstall` (the CLI takes `--json`; `--dry-run` stays with the components, see [Result of the changing commands](#result-of-the-changing-commands)) and for `generate` (the generator takes it, with `--config`). A component command (`engine ollama list-models`) is forwarded as it is, and prints the JSON of the script.

## Commands

| Command | Role | Root |
| --- | --- | --- |
| `catalog [--json]` | What can be installed: components, options, ranks, default models, platforms | no |
| `host [--json]` | What this machine is: platform, CPU, memory, disk, GPU | no |
| `config schema` | The configuration format, as a JSON Schema generated from the catalog | no |
| `config validate <file\|-> [--target this\|fresh] [--json]` | Validate a configuration and show its plan, without side effect | no |
| `guide` | The recommended procedure for an agent, as text | no |
| `apply <file\|-> --dry-run --json` | The same document as `config validate --target this` | no |
| `generate --config <file> [--dry-run] --json` | Validation (target `fresh`), then the script: the document of `config validate` with a `script` entry (`path`, `bytes`, `written`, `package_version`, `package_format`), `null` when the file is not valid. `--json` needs `--config` (a session is interactive, exit 2) | no |

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
- The catalog says nothing about the machine: whether a component is installed is `status --json`, and whether a model fits is [model fit](#model-fit-for-a-machine-that-is-not-this-one).

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
- These are the facts of the machine running the command. For another machine, the agent asks the user, see [below](#model-fit-for-a-machine-that-is-not-this-one).

### `config schema`

Prints the JSON Schema (draft 2020-12) of the configuration, **generated at run time** from the shipped `describe`s, so it is true for this version of the package and needs no repository:

- the structure of [spec: config](spec-config.md#format) (`schema_version`, `components`, `models`, the fields and their rules);
- for each shipped component, its options: names, types and `values`/`default` as the schema's `enum`/`default`, the secret options as the `file` / `env` / `generate` object, and the option `description`s as the schema's `description`;
- the rules that cannot be expressed as a schema (one entry per component, at most one `default` per type, `requires`, the resolution of `engine` and `chat_interface`) as `description` text on the relevant node, and enforced by `config validate`.

The schema is a **help to write a file**, `config validate` is the judge: the schema may be less strict, never stricter.

### `config validate`

```text
easy-cs-ai config validate <file|-> [--target this|fresh] [--json]
```

The validation and the plan that `apply` runs before any side effect, as a command of its own. `-` reads stdin.

- `--target this` (default) validates against this machine: a component already installed satisfies a requirement, exactly as `apply` does. `--target fresh` validates as for a new VM, ignoring what is installed (the generator's `EASY_CS_AI_ASSUME_EMPTY` mode, see [spec: VM script generator](spec-vm-generator.md#implementation-notes)): **this is the one for a fleet**.
- `apply <file> --dry-run --json` prints the same document as `--target this`, so an agent can use either.
- Exit code: 0 when `ok`, 2 when there is an error.

Without `--json`, the problems and the plan in human form (the lines `apply --dry-run` prints today). With `--json`:

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
- `warnings` are the `warn` entries of `describe` whose condition holds for the **effective** value (a default included), as in the summary of the generator, so that the agent can relay them to the user before anything is applied. They do not change the exit code.
- `plan.components` is in install order, with the options as written in the file, a secret shown as its source; when the target is `this`, each entry also says whether it is already installed (`"installed": true | false`, absent for `fresh`); whether an installed one is left alone or reconfigured is the script's own [idempotence](spec-script-contract.md#idempotence), which the CLI does not compare. The order is the install order of `apply`: a component comes after the ones it requires, otherwise in the order of the file. `plan.models` has the names already resolved (`engine`, `chat_interface`).
- **Codes** (closed list, a new one is not a bump of `schema_version`): `not_json`, `wrong_type`, `unknown_key`, `unknown_type`, `unknown_component`, `unknown_option`, `secret_literal`, `secret_source`, `unsupported_schema_version`, `duplicate_component`, `several_defaults`, `unresolved_engine`, `unresolved_chat_interface`, `ambiguous_engine`, `ambiguous_chat_interface`, `missing_requirement`, `unsupported_platform`, `invalid_value` (an option outside `values`, not an integer…), `circular_requirement`. The implementation attaches a code to each message of the validation program; the human text does not change.
- `unsupported_platform` compares the `platforms` of the component with `ID` and `ID_LIKE` of `/etc/os-release`, only for `--target this`, and not in test mode (`EASY_CS_AI_ROOT`), as the scripts' own platform check. `EASY_CS_AI_HOST_IDS` (space separated) replaces the detection, for the tests.
- With `apply`, a requirement that nothing satisfies keeps its exit code 4 (see [spec: config](spec-config.md#semantics-converge)): `apply --dry-run --json` prints the same document and exits 4 when `missing_requirement` is the only kind of error, 2 otherwise. `config validate` and `generate --config` exit 2 for it.
- Not covered, as today: a `file` secret whose path is checked at run time only.

### `guide`

An agent that has nothing but the binary finds it from `easy-cs-ai --help`, whose usage starts with a line telling an AI agent to run `guide` first, and whose command list groups `guide` with `catalog`, `host` and `config` under a heading of their own for agents and programs.

Prints, as plain text, the procedure of the [next section](#procedure-for-an-agent) and the safety rules that go with it, so an agent that has nothing but the binary learns how to use it. Short (a screen or two), versioned with the CLI. It is text, not JSON: it is meant to be read by a model, and is the only reader-oriented output that has no `--json` form.

## Result of the changing commands

`install`, `uninstall`, `add`, `remove` and `apply` (not dry-run), run with `--json`, print one document **at the end, whatever the outcome**, so an agent never has to parse stderr to know what happened:

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

## Model fit for a machine that is not this one

`provisioning llmfit suggest` and `check <model>` evaluate the **local** hardware. An agent that prepares a fleet knows the specs of the target from the user, not from `host`. llmfit overrides the detected hardware with `--memory`, `--ram` and `--cpu-cores` (see [findings](../search/llmfit.md)), so the two actions gain, as options:

| Option | Meaning | Forwarded to llmfit as |
| --- | --- | --- |
| `--target-ram <GB>` | RAM of the machine to size for | `--ram` |
| `--target-vram <GB>` | GPU memory of the machine to size for | `--memory` |
| `--target-cpu-cores <n>` | CPU cores of the machine to size for | `--cpu-cores` |

With none of them, behaviour is unchanged (local hardware). They are declared in the `describe` of the llmfit script under `action_options`, keyed by action (`suggest`, `check`), and not in `options`, which are the options of `install` and of the configuration; they are therefore in `catalog` too. The options are read-only and need no engine; llmfit itself must be installed, otherwise the action exits 4 with the command that installs it (`easy-cs-ai install provisioning llmfit`), and the agent asks the user before running it (it is a change on the machine).

### Two orders, one implementation

A user either has a VM imposed (**hardware first**) or has models in mind (**models first**); an agent serves both, exactly as the interactive generator does (see [spec: VM script generator](spec-vm-generator.md#choosing-models)). Both orders are actions of the `provisioning llmfit` component, so that the generator and the agent share the code and never the logic twice:

| Order | Action | Answer |
| --- | --- | --- |
| Hardware first | `suggest` with the `--target-*` options | The models that fit, already filtered (Ollama tag, not `Too Tight`) and ranked by score, see the [script contract](spec-script-contract.md#actions) |
| Hardware first, a model named by the user | `check <model>` with the `--target-*` options | `fits` and `reason` |
| Models first | `plan <model>… [--target-cpu-cores <n>] [--chat-interface]` | The VM the models need: the model figures from llmfit, the **estimated margin** and the total, for RAM without GPU, GPU memory with a GPU, and disk, for the `best` and the `default` quantisation, plus the models llmfit could not size (`unsized`) |

`suggest` and `plan` have a **text for a person by default** (what the interactive generator shows, and what an administrator reads when running them from the command line) and the JSON documents of the [script contract](spec-script-contract.md#actions) with `--json`, which an agent always passes. The text is rendered by the action from the same document, so the two cannot differ.

The agent presents the result of `plan` as the text does: the model figure and the estimated margin side by side, never a single total that looks measured, the two quantisations, and the unsized models listed as not covered. It does not compute the margin itself. `plan` has no `--target-ram` or `--target-vram`: in this order the hardware is the answer, not the question.

The interactive generator uses the same actions to help an administrator without an agent choose models, and treats llmfit as optional: it offers to install llmfit, and falls back to typed names when llmfit is missing instead of exiting 4 (see [spec: VM script generator](spec-vm-generator.md#choosing-models)).

The configuration still does not store the target specs: the fit is checked **at run time on the target** (`add`, as before), and what the agent asks llmfit while preparing is only an early opinion. A model the agent proposed that does not fit on the target is refused at `apply` (or accepted with `force`).

## Contract addition: typed options in `describe`

`describe` options carry today a `default` that is always a string (`"11434"`, `"true"`), so a program cannot tell an integer or a boolean from a text, and validation can only say "a string, number or boolean". Each option gains, additively (no bump of `schema_version`, like `warn`):

| Field | Meaning |
| --- | --- |
| `type` | `string` (default when absent), `integer`, `boolean`, `enum` |
| `values` | The allowed values, for `enum` |
| `min`, `max` | Bounds, for `integer` |

The scripts already validate these values at run time; `type` makes it available beforehand to `catalog`, `config schema` and `config validate` (code `invalid_value`). Every shipped script gets its options typed with this change. In the configuration, a typed option accepts the JSON type that matches (`11434` or `"11434"` for an integer, `true` or `"true"` for a boolean): the CLI passes the text.

## Secrets

For the agent, and for the fleet: **a literal secret is never allowed in a configuration**. Only the three sources of [spec: config](spec-config.md#secrets) exist (`file`, `env`, `generate`); a plain value is the validation error `secret_literal`, as it is today, and this becomes the rule rather than the open question. It settles in the same way the [question of the generator](spec-vm-generator.md#open-questions), and the user-data caveat of the [contract](spec-script-contract.md#secrets): what the agent writes into a script is readable by anyone who reads the user-data.

An agent that needs a secret known in advance (rare) says so to the user and uses `env` or `file`, never a value in the file nor on a command line. Generated secrets are retrieved with the dedicated actions (`proxy nginx show-key`), which the agent does not run unless the user asks, since it prints a secret.

## Procedure for an agent

What `guide` prints, in substance:

1. **Ask before assuming.** The CLI never takes a default choice on its own, and neither does the agent: the stack (`install --defaults` included) is the user's decision, with the catalog's ranks given as a suggestion.
2. **Discover**: `catalog --json`, then `host --json` (this machine) or the specs the user gives (another machine).
3. **Choose the models, in the order that suits the user.** This step stands on its own in the guide, because an agent that has only the binary must see that there are two ways in, and ask which one applies:
   - **Hardware first**, when a VM is imposed: `provisioning llmfit suggest --json` with the `--target-*` options lists the models that fit it, and `check <model>` judges one the user names.
   - **Models first**, when the user has models in mind: `provisioning llmfit plan <model>… --json` (with `--chat-interface` when one is in the stack, `--target-cpu-cores` for the vCPU) tells what VM to ask for.

   The guide says how to read the `plan` document (`quantisations.best` and `.default`, each with `ram_no_gpu`, `gpu_memory`, `gpu_ram` and `disk`, and `model_gb`, `margin_gb`, `total_gb` in each; `unsized` for the models llmfit does not know), that the margin is an estimate to present as such, that all this is an early opinion (the fit is checked again on the target), and that llmfit must be installed, which the agent asks the user about first. See [two orders](#two-orders-one-implementation).
4. **Draft** the configuration from `config schema` and the catalog. Never write a secret as a value.
5. **Validate**: `config validate <file> --target fresh|this --json`; fix the `errors` by their `path` and `code`, and loop until `ok`.
6. **Show the user** the `plan` and **every `warning`** (open registration…), and get a yes.
7. **Produce** either the script (`generate --config <file> --package-… --output <path>`, which the user reviews and runs on the VM) or the change on this machine (`sudo easy-cs-ai apply <file> --json`, only with the user's explicit agreement, since it changes the machine).
8. **Read the result document** and `status --json`; report to the user in plain words. A failure is reported with its `message` and `failed_step`; a second `apply` resumes (see [spec: config](spec-config.md#failure-and-resume)), it is not retried blindly.
9. **Never** run `uninstall`, `remove`, `apply --prune` or `--purge` on the agent's own initiative, nor `proxy nginx show-key`, nor `exec`, which runs any command of a component's program (`ollama rm`, `docker compose down -v`) outside the state, the lock and the journal, unless the user asked for that command.

## Gaps closed

| Gap | Answer |
| --- | --- |
| The catalogue must be assembled by hand (names per type, then one `describe` each, ranks and default models unreachable) | [`catalog`](#catalog) |
| The format of the configuration exists only in the docs | [`config schema`](#config-schema) |
| Validation errors are lines on stderr, the plan is log lines, warnings only in the interactive summary | [`config validate`](#config-validate), `apply --dry-run --json` |
| Validating for a fleet (not this machine) has no command | `--target fresh`, `generate --config --dry-run --json` |
| The machine is opaque | [`host`](#host) |
| Fit of a model can only be asked for the local hardware | [`--target-*`](#model-fit-for-a-machine-that-is-not-this-one) |
| Models-first sizing, candidate ranking and the VM margin existed only in the interactive generator | [`suggest` and `plan`](#two-orders-one-implementation), shared by both |
| Option types are not declared | [typed options](#contract-addition-typed-options-in-describe) |
| Outcome of `apply` / `install` / `add` is only on stderr | [result document](#result-of-the-changing-commands) |
| Literal secrets undecided | [Secrets](#secrets) |
| The agent does not know the procedure nor the safety rules | [`guide`](#guide) |

## Definition of done

- `bats` tests in `EASY_CS_AI_ROOT` mode with fake components: `catalog` (shipped only, ranks, default model, order, `describe` verbatim, unranked, no root), `host` (fake `/proc` and `/etc/os-release`, a fact that cannot be read is `null`, no GPU), `config schema` (valid JSON Schema, options typed from `describe`, secret objects), `config validate` (every `code`, every path, several errors at once, `plan` null on error, warnings on a default value, `--target this` versus `fresh`, stdin, exit codes, no root), the result document of each changing command for success, a failing step, exit 7 and interruption, the dry-run plans.
- A schema check: a configuration accepted by `config validate` is accepted by `config schema`'s schema, and vice versa for every error code except those the schema cannot express.
- stdout hygiene: with `--json`, stdout parses as exactly one document in each of the cases above, including failures; without it, no JSON.
- `provisioning` tests: the `--target-*` options reach llmfit as `--ram`, `--memory`, `--cpu-cores`, before the subcommand; llmfit missing is exit 4 with the install hint; `suggest` (Ollama tags only, no `Too Tight`, best score first, at most `-n`, empty list on no result), `plan` (margin parts and totals for both quantisations, `--chat-interface`, `unsized`, no model is exit 2). The tests of the generator check that it prints what these actions return and computes nothing of its own.
- Every shipped `describe` validates against the typed-option rules.
- Integration test on a VM: the procedure above run end to end by a script that plays the agent (catalog, host, validate, apply with `--json`, status).
- `shellcheck` clean; the `--help` of each command and `guide` consistent with this spec.

## Open questions

- **`guide` versus a packaged skill/prompt.** The CLI is the only channel an agent without the repository has, hence `guide`; an agent platform may additionally want the same text as a skill. The text lives in one place (the CLI) either way.
- **Large catalog.** `catalog --json` embeds every `describe`; if it grows too large for a model's context, add `catalog --json <type> [<name>]` to narrow it. Not needed with four components.
- **Several instances of one component** are still not expressible (see [spec: config](spec-config.md#open-questions)), so neither by the agent.
- **Hardware detection on a GPU machine** is untested (the project has only run on CPU, see the [status](../README.md)); `host` reports what `nvidia-smi` / `lspci` give and `null` otherwise.
- **Naming of the `--target-*` options** if llmfit changes its own flags: the mapping is in one place in the llmfit script.
