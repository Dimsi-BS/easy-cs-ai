# Spec: configuration file and `apply`

[← Back to docs](README.md)

**Status:** accepted (secrets handling still open, see [open questions](#open-questions)). **Format version 2 is decided and not implemented**: the file is a list of `vms` that hold their components (`component: <type>/<implementation>`, a free `name`), an `engine` component holds its `models` (each an instance of a model, with the chat interfaces that show it as component references), there is no flat file, no top-level `models` and no top-level `links`, and `schema_version` is 2. The validation, `config schema`, `apply`, the slices and the tests still implement version 1 (the `vm` field, `links`, the root `models` with `engine` and `chat_interface`, see `tests/unit/config_vm.bats`), and are to be rewritten. Everything below describes version 2; [What a model needs](#what-a-model-needs) is implemented as it is.

## Purpose

One declarative **configuration file** describes a deployment: which components, with which options, and which models. It has two uses, with one format:

- `easy-cs-ai apply <file>` (layer 2) interprets it and makes the machine match it;
- the [generator](spec-vm-generator.md) writes it at the end of an interactive session (`config edit`, which also opens it again to edit it), and `script <file>` reads it back to generate the scripts without prompting (regeneration, tests). The two commands share nothing but this file.

For the VM post-install layer, the generated script embeds the configuration (the [slice](#slices) of its VM) and hands it to `apply`, so the configuration travels **inside the generated script**: no external input file (see [spec: VM script generator](spec-vm-generator.md#generated-script)). The package itself is downloaded from a pinned source, not embedded, see [decision: VM script generator](decision-vm-generator.md).

`apply` builds on the [script contract](spec-script-contract.md) and the [CLI spec](spec-cli.md); it adds no capability the CLI does not have, it lets one file drive `install` and `add`.

## Format

JSON, like every other structured file of the project: `jq` is already a dependency (see [scripting language](decision-scripting-language.md)), whereas YAML would need `yq`.

The file is a **list of VMs**, each holding its components, and an `engine` component holds the **models** installed on it, each saying in which chat interface it is shown. There is no other form: a file always names its VMs, even for a single machine (a stack is mostly several VMs in practice, and one form means one rule everywhere: in the session, in the editor, in the validation and in the slices). The file is read with `schema_version` 2.

```json
{
  "schema_version": 2,
  "vms": [
    {
      "name": "gpu",
      "components": [
        { "component": "provisioning/llmfit" },
        { "component": "proxy/nginx", "options": { "server-name": "gpu.example.org" } },
        { "component": "engine/ollama", "default": true, "options": { "port": 11434 },
          "models": [
            { "name": "llama3.2:3b", "chat_interfaces": [ { "vm": "web" } ] },
            { "name": "qwen2.5:7b", "force": true }
          ] }
      ]
    },
    {
      "name": "web",
      "components": [
        { "component": "proxy/nginx", "options": { "server-name": "ai.example.org" } },
        { "component": "chat-interface/librechat", "options": { "allow-registration": false } }
      ]
    }
  ]
}
```

A single machine is a file with one VM; its models name that VM in `chat_interfaces` when they are shown in a chat interface of the same VM. The file says it **explicitly**: the session asks, model by model, in which chat interface it is shown (see [spec: several VMs](spec-multi-vm.md#creating)), and never links the two without the person's answer:

```json
{
  "schema_version": 2,
  "vms": [ { "name": "vm-1", "components": [
    { "component": "provisioning/llmfit" }, { "component": "proxy/nginx" },
    { "component": "engine/ollama",
      "models": [ { "name": "llama3.2:3b", "chat_interfaces": [ { "vm": "vm-1" } ] } ] },
    { "component": "chat-interface/librechat" } ] } ]
}
```

**The format is ahead of the implementation.** It allows several engines or several chat interfaces on a VM, a free `name` for a component, several references in `chat_interfaces`, and `options` on a model. The validation accepts, **for now**, one component per implementation on a VM (`duplicate_component`) and at most one reference in `chat_interfaces` (`unsupported_count`), because the layer 1 scripts keep one state per component (see [open questions](#open-questions)); lifting those limits changes the validation, not the format. Several components of one type on a VM (an engine `engine/ollama` and an engine `engine/vllm`, once vLLM ships) is the first case to open.

### `vms`

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | The name of the VM: a string of lowercase letters, digits and dashes, starting with a letter (`gpu`, `web`, `vm-1`). Another type is `wrong_type`, another form `invalid_value`. Unique in the file: a second VM with the same name is `duplicate_vm` |
| `components` | yes | The components installed on that VM, see below. At least one: a VM with none is `empty_vm` |

- The order of the VMs carries no meaning for the installation; it is the order of the summaries, of the scripts and of the next steps (the order of the file).
- Each VM is a machine of its own: what another VM holds is not on it. A requirement (`requires`) is satisfied by a component **of the same VM**.

### `components`

| Field | Required | Meaning |
| --- | --- | --- |
| `component` | yes | What the component is: `<type>/<implementation>`, the type being one of the contract types (`engine`, `chat-interface`, `proxy`, `provisioning`) and the implementation a shipped one (`<type>/<implementation>.sh`): `engine/ollama`, `proxy/nginx`. The same notation as the path of the script and as `--component` of `provisioning plan`. An unknown type is `unknown_type`, an implementation that is not shipped `unknown_component` |
| `name` | no | How the component is called **in its VM**, free, chosen by the person: what a reference to the component designates (the `chat_interfaces` of a model). Same shape as the name of a VM. Default: the implementation (`ollama` for `engine/ollama`). Unique in the VM (`duplicate_name`) |
| `default` | no | Make it the default of its type, forwarded as `--default` (see [state format](spec-state-format.md#defaults)). At most one per type **on a VM** (`several_defaults`) |
| `options` | no | Options of the script, keyed by option name **without** `--` (the `describe.options[].name`). Values are strings, numbers or booleans |
| `models` | no | **Engines only**: the models installed on this engine, see [`models`](#models). On a component that is not of type `engine`: `models_on_non_engine` |

- An option left out takes the script's built-in default, as on the command line, **unless the component declares it required**: an option whose `required_when` ([script contract](spec-script-contract.md#describe)) holds for the other options of the entry (nginx's `tls-cert` with `tls: provided`, `tls-accept-terms` and `server-name` with `tls: letsencrypt`) and that is left out is the error `missing_option`, at the path of the entry's `options`, naming the option and the condition. An option with no `required_when` is optional. An option whose `relevant_when` does not hold is **not an error** when written (the validation accepts it, as the scripts do), it is only not asked by the session.
- `config schema` lists the values of `component` from the shipped scripts, so that a program validates the notation without parsing it.
- **One component per implementation on a VM, for now**: the same `component` twice on one VM is `duplicate_component`, whatever their `name`s (the state of layer 1 has one entry per component, see [open questions](#open-questions)). `proxy/nginx` is listed once **on each VM** that has a proxy, with its own options (server name, certificate).
- Order in the file carries no meaning: the install order comes from `requires`.

### Secrets

An option flagged `secret` in `describe` is never given as a plain string. It is an object naming its source, the same channels as the [contract](spec-script-contract.md#secrets):

| Form | Source |
| --- | --- |
| `{ "file": "/path" }` | `--<name>-file`, the file must be mode `0600` or stricter |
| `{ "env": "NAME" }` | The environment variable of the process running `apply` |
| `{ "generate": true }` | Generated by the script (the contract default when the option is absent) |

Whether a literal secret may appear in the file is an [open question](#open-questions).

### `models`

A model is described **in the engine component that installs it**: `models` is an optional array of the entry of a component of type `engine`, and there is no `models` at the root of the file. Each entry is **one instance of a model** on that engine:

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Model name, as the engine knows it. Unique in the engine (`duplicate_model`) |
| `chat_interfaces` | no | The chat interface(s) that show the model: an array of [component references](#component-references) (several chat interfaces may show one instance of a model). Absent or empty: the model has none (an engine used through its API). **At most one** for now (`unsupported_count` otherwise) |
| `force` | no | `true` skips the llmfit fit check, as `add --force` does |
| `options` | no | **Reserved.** The options of this instance, validated against what the `describe` of the engine would declare for a model (a future `model_options` key, see the [script contract](spec-script-contract.md#describe), not defined yet). While no engine declares any, every `options` of a model is refused (`unknown_option`). It is for an engine that runs **one process per model** (`per_model`, vLLM), whose instances have their own parameters |

**Why the model is in the engine.** An instance of a model lives where it is installed, so the engine that holds it is its container: there is no engine to resolve, nothing to point to the wrong component, the model travels with its component (and so with its VM) when a file is cut into [slices](#slices), and the file has the shape of the state of an engine, whose `models` array it mirrors ([state format](spec-state-format.md)). The same model on two engines is two instances, hence two entries, one in each engine; the same name twice in **one** engine is `duplicate_model`.

**The model carries the link**: its `chat_interfaces` says where it is shown. A chat interface of the engine's own VM is wired by `add` as on a single machine; a chat interface of **another VM** is the link between two machines, which installs nothing and is finished by hand once the VMs are up (see [spec: several VMs](spec-multi-vm.md#next-steps)). Error paths are those of the file as written: `$.vms[i].components[j].models[k]`.

The **place** of a model is the engine component that holds it, on its VM: it decides everything that follows: the VM where the model is pulled and [sized](spec-model-fit.md#declared-resources), the engine that serves it, the proxy of its VM that fronts it, and the [next steps](spec-multi-vm.md#next-steps) that read its URL. `config validate` still exposes **a flat list** of the models in its plan, each with the VM and the `name` of its engine as resolved and its resolved chat interfaces (see [spec: capabilities](spec-capabilities.md#config-validate)): it is an output document, not the file.

#### Component references

Each element of the `chat_interfaces` of a model designates a component of type `chat-interface` of a VM:

| Field | Required | Meaning |
| --- | --- | --- |
| `vm` | yes | The VM that holds the component. A name no VM has is `unknown_vm`, with the VM names of the file in the message |
| `name` | no | The `name` of the component on that VM |

It resolves as follows:

| `name` | Component |
| --- | --- |
| given | The chat interface of that name on that VM. None: `unresolved_chat_interface` (the message says so when the name exists with another type) |
| absent | The only chat interface on the VM, else the one with `default: true` on that VM, else `ambiguous_chat_interface` (the message lists the names). None on the VM: `unresolved_chat_interface` |

- The `vm` is always written, so that a reference never depends on what the other VMs hold; `name` is left out when the VM has one chat interface (the session and a program that follow the [journey](spec-journey.md#4-models) write it only when it is needed).
- The resolved references (the VM and the `name` of each component) go into the plan of `config validate` (see [spec: capabilities](spec-capabilities.md#config-validate)).

### Slices

The file is cut by VM, in the order of the file. A **slice** is a file of the same format with **one** VM, its components and so the models they hold, and is validated **exactly as a file of one VM**: order from `requires`, a requirement satisfied by a component of the VM only, options, secrets. Errors and warnings keep the paths of the file as written, and name the VM they are about.

- A model **travels with its engine component**, so it is in the slice of its engine's VM with nothing to resolve; its `chat_interfaces` keeps the reference when the chat interface is on **that same VM** (the wiring of `add`, as on a single machine) and is emptied otherwise: a chat interface of another VM is not on this machine, and what the VM does must not depend on it.
- **What a VM receives**: `script` embeds the slice in the script of its VM (see [spec: VM script generator](spec-vm-generator.md#generated-script)), and `apply` on the VM reads it, so that it knows nothing of the other VMs. Being a file of one VM, it needs no `--vm`.
- **`apply` on a file with several VMs** is refused (exit 2, listing the VM names) unless `--vm <name>` selects a slice, which is then applied as such. A file with one VM needs no `--vm`; `--vm` with an unknown name is exit 2. Pruning, `--dry-run` and the plan concern that slice only.

### Compatibility

`schema_version` is **2**. The format of version 1 (components with a flat `type` and `name`, a `vm` field, a top-level `links`, the root `models` with the `engine` and `chat_interface` of a model) is **no longer read**: the project is in development and keeps no compatibility with it, so there is no converter. A file with `schema_version` 1 is refused with `unsupported_schema_version` (exit 2) and a message that says the format changed and points to this section; a higher version is refused as before, never guessed. The validation stays **strict**: an unknown key is `unknown_key`. A generated script pins its package version and embeds a slice in the format of that version, so a script made for an older package keeps working with it.

### Validation

`apply` and the generator validate the file **before any side effect**, against the `describe` of the shipped scripts: unknown top-level key, unknown type, component or option, wrong value type, `schema_version` other than 2, a missing option that the component requires (`missing_option`), a secret given as a plain string, an unresolvable chat interface of a model, a `models` on a component that is not an engine (`models_on_non_engine`). Each problem is reported with its JSON path on stderr, and the exit code is 2. A higher `schema_version` is refused, never guessed. each slice is validated as a file of one VM, and the codes of [`vms`](#vms), [`components`](#components), [`models`](#models), [Component references](#component-references) and [Slices](#slices) join the list of [spec: capabilities](spec-capabilities.md#config-validate). A model whose proxy or provisioning component is not in the file is `missing_requirement` too, see [What a model needs](#what-a-model-needs).

#### What a model needs

The validation also checks, for each model, what [`add`](spec-cli.md#add) will need to install it, so that a file that cannot finish is refused **before** anything is installed, not at the model step after the components:

| The model needs | Unless | Error when absent |
| --- | --- | --- |
| A component of type `proxy`, to expose it | The engine is **protected** (it enforces HTTPS and an API key itself, see [`protected`](spec-script-contract.md#describe)) | `missing_requirement` at the path of the model (`$.vms[i].components[j].models[k]`), naming the proxy |
| A component of type `provisioning` (llmfit, today), to check that it fits | The model has `force: true` | `missing_requirement` at the path of the model, naming the component |

- The component must be in the file (on the **VM of the engine that holds the model**: a proxy on another VM does not expose this engine) or, with `--target this`, already installed. It is the rule of a `requires`, so the code is the same and `apply` keeps its exit 4 for it.
- It is the same decision as `add` makes, read from the file and from the `describe` of the engine: the validation never runs an action. An engine whose `describe` does not say it is protected is not.
- A model with no chat interface is not concerned by the chat interface: only the proxy and a provisioning component are needed.
- A VM with an engine and **no model** needs no proxy to validate (the engine may receive its models later): the proxy is required by a model, never by an engine alone.
- **The session does not write the proxy error**: when models are named without a proxy on their VM it proposes one, and a refusal takes the models out in a one-VM session, or sends the pass of an `engine` role VM back to its components ([journey, step 4](spec-journey.md#4-models)). The error is for a file written by hand or by a program, and for a session whose package ships no proxy to propose, where the summary shows it.

## `apply`

```text
easy-cs-ai apply <file|-> [--vm <name>] [--prune] [--dry-run]
```

`--vm <name>` selects one VM of a file that has several, see [Slices](#slices); with one VM it is not needed. `-` reads the configuration from stdin. Requires root (exit 4), except with `--dry-run`. The CLI never prompts, as for the other commands.

### Semantics: converge

`apply` makes the machine **reach** what the file says, and is safe to run again. Like `install --defaults`, it converges.

- **Nothing is added that the file does not name.** There is no `--defaults` here: the file is the explicit choice. A component required by another (`requires`) that is neither listed nor already installed is an error (exit 4, naming the command that would fix it), as for `install` without `--defaults`. See [Dependencies](spec-cli.md#dependencies).
- **Nothing is removed by default.** A component or a model present on the machine but absent from the file is left alone. `--prune` is the explicit opt-in (see below).
- A listed component already installed with the same options is a no-op, and with different options it is reconfigured: this is the script's own [idempotence](spec-script-contract.md#idempotence), the CLI does not compare anything itself.

### Steps

1. **Read and validate** (no side effect). With several VMs, the file is cut into its [slices](#slices) first and only the one selected by `--vm` goes on; a file with one VM is its own slice. `--dry-run` prints the plan after this step and exits 0.
2. **Order** the components from `requires` (from `describe`, not hardcoded), the same computation as the default stack of [`install`](spec-cli.md#install).
3. **Components**: for each, in that order, the CLI runs the equivalent of `install <type> <name>` with the options of the entry (and `--default` when set). Secrets are passed through their channel, never on the command line.
4. **Models**: for each, the equivalent of [`add`](spec-cli.md#add) with the engine and the chat interface of the slice (`--no-chat-interface` when `chat_interfaces` is empty, `--force` when set), including the fit check, the wiring and its rollback.
5. **Prune** (only with `--prune`): after everything else succeeded, in reverse order, `remove` for each installed model absent from the file (of the engines listed), then `uninstall` for each component absent from the file, without `--purge`.

### Failure and resume

- The run stops at the first failing step and returns its exit code, naming the step (`[ERROR] apply: install engine ollama failed (exit 5: …)`).
- **No global rollback.** Installed components are kept: they are what the file asked for, and a second `apply` resumes with what is left. A failing `add` is rolled back as specified for `add` (and exits 7 if that rollback is incomplete).
- `--prune` runs last, so a failed run never removes anything.
- Interruption (SIGINT, SIGTERM) behaves as for `add`: the running script finishes its own cleanup, then the command ends with 130 / 143.

### Journal

`apply` writes `apply start components=<n> models=<n> prune=<bool>` (plus `vm=<name>` with `--vm`) and `apply end exit=… duration=…` through `log_event`, around the lines of each step (see [Action journal](spec-script-contract.md#action-journal)). The file's content is not logged, only counts.

## Relation to the other commands

| Need | Command |
| --- | --- |
| One component, by hand | `install <type> <name>` |
| The rank 1 stack | `install --defaults` |
| One model on the current setup | `add <model>` |
| A described deployment, reproducible | `apply <file>` |

`apply` is the form used by the generated VM script. `install --defaults` stays for the quick, undescribed case.

## Implementation notes

- Validation is one `jq` program run over the file and the `describe` of every listed component, so the whole list of problems comes out at once, each with its JSON path. Not covered yet: a `file` secret whose path is checked at run time only (by the script, mode `0600` or stricter).
- Options reach a script as `--<name> <value>` (booleans and numbers as their text); a secret `{ "file": … }` as `--<name>-file <path>`; a secret `{ "env": "VAR" }` through the script's own `EASY_CS_AI_<COMPONENT>_<OPTION>` variable, set from `VAR` (exit 2 when `VAR` is not set), so it never appears on a command line; `{ "generate": true }` passes nothing.
- A requirement that is neither installed nor listed is checked before the first install, so nothing is installed by a run that cannot finish.
- `--prune` removes the models of the engines listed in the file that the file does not name, then every installed component the file does not list, in `uninstall --all` order.

## Definition of done

- `bats` tests in `EASY_CS_AI_ROOT` mode with fake components: each validation error with its JSON path, order from `requires`, missing requirement, re-run is a no-op, changed options reconfigure, defaults, a model in its engine, `force`, stdin input, `--dry-run`, failure at each step and resume, `--prune` (and its absence), the secret forms.
- Integration test on a fresh VM: `apply` of a configuration, `status` healthy, second `apply` changes nothing, `apply --prune` with a reduced file.
- `bats` tests of the format of version 2: `wrong_type` and `invalid_value` on the name of a VM, `duplicate_vm`, `empty_vm`, `unknown_type` and `unknown_component` on `component`, the default `name` and `duplicate_name`, `duplicate_component` (also with two different `name`s), `missing_option` for each `required_when` of the shipped components (and not raised when the condition does not hold), the same component on two VMs accepted, `several_defaults` per VM, a requirement satisfied by another VM refused, `schema_version` 1 refused with its message, and a flat file refused.
- `bats` tests of the [models](#models): a model in an engine, `models_on_non_engine` on another type, `duplicate_model` (the same name twice in one engine) and the same model accepted in two engines, `options` of a model refused with `unknown_option`, `wrong_type` on `models` or on a model, `force`, error paths `$.vms[i].components[j].models[k]`.
- `bats` tests of the [component references](#component-references): `vm` given with and without `name`, a reference by the only chat interface, by the `default`, `ambiguous_chat_interface`, `unresolved_chat_interface` (also when the name exists with another type), `unknown_vm`, `unsupported_count` on `chat_interfaces` with two references, an empty or absent `chat_interfaces`.
- `bats` tests of the [slices](#slices): each without the other VMs, models with their engine, a chat interface of the same VM kept and one of another VM emptied, order of the file, paths of the file as written, `apply` refused without `--vm` on several VMs, accepted without it on one, `--vm` with an unknown name, `apply --vm` applying one slice.
- `bats` tests of [what a model needs](#what-a-model-needs): a model with no proxy in the file is `missing_requirement` at its path (target `fresh`), and accepted when the proxy is installed (`--target this`); a `protected` engine needs none; no provisioning component without `force` is `missing_requirement`, and accepted with `force`; with several VMs, a proxy or a provisioning component on another VM does not count, and an engine VM with no model and no proxy is valid; the exit code of `apply` is 4 when it is the only kind of error.
- `shellcheck` clean.

## Open questions

- **Literal secrets in the file.** Answer: forbidden, see [spec: machine interface](spec-capabilities.md#secrets). The file is embedded in the generated VM script, so a literal would sit in the script and, on CloudStack, in the user-data, which is not confidential (see [contract](spec-script-contract.md#secrets)). Options: forbid literals (only `file`, `env`, `generate`), or allow them with a `WARN`. Same question as in [spec: VM script generator](spec-vm-generator.md#open-questions), to be settled together.
- **Several instances of one component on a VM** (e.g. two `engine/ollama` with different ports): the format allows them (a free `name`, [`components`](#components)), the validation refuses them (`duplicate_component`) because the state of layer 1 has one entry per component, one unit, one port, one Compose project. Lifting the limit is a change of layer 1 (state keyed by instance, units and volumes named by instance), then of the validation. Several components of **one type** with different implementations (`engine/ollama` and `engine/vllm`) need the same state change only for what they share, and are the first case to open.
- **Schema evolution**: how a new `schema_version` is migrated, once a second version exists.
