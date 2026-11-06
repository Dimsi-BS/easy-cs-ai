# Spec: configuration file and `apply`

[← Back to docs](README.md)

**Status:** accepted (secrets handling still open, see [open questions](#open-questions)). **Format version 2 is decided and not implemented**: the file is a list of `vms` that hold their components (`component: <type>/<implementation>`, an optional free `name`), an `engine` component holds its `models` (each an instance of a model), a top-level `links` array says which model is shown in which chat interface (two [references](#references), **always complete**: `vm_ref`, `component_ref`, `model_ref`), there is no flat file and no top-level `models`, and `schema_version` is 2. The validation, `config schema`, `apply`, the slices and the tests still implement version 1 (the `vm` field, `links` made of pairs of VMs, the root `models` with `engine` and `chat_interface`, see `tests/unit/config_vm.bats`), and are to be rewritten. Everything below describes version 2; [What a model needs](#what-a-model-needs) is implemented as it is.

## Purpose

One declarative **configuration file** describes a deployment: which components, with which options, and which models. It has two uses, with one format:

- `easy-cs-ai apply <file>` (layer 2) interprets it and makes the machine match it;
- the [generator](spec-vm-generator.md) writes it at the end of an interactive session (`config edit`, which also opens it again to edit it), and `script <file>` reads it back to generate the scripts without prompting (regeneration, tests). The two commands share nothing but this file.

For the VM post-install layer, the generated script embeds the configuration (the [slice](#slices) of its VM) and hands it to `apply`, so the configuration travels **inside the generated script**: no external input file (see [spec: VM script generator](spec-vm-generator.md#generated-script)). The package itself is downloaded from a pinned source, not embedded, see [decision: VM script generator](decision-vm-generator.md).

`apply` builds on the [script contract](spec-script-contract.md) and the [CLI spec](spec-cli.md); it adds no capability the CLI does not have, it lets one file drive `install` and `add`.

## Format

JSON, like every other structured file of the project: `jq` is already a dependency (see [scripting language](decision-scripting-language.md)), whereas YAML would need `yq`.

The file is a **list of VMs**, each holding its components, an `engine` component holding the **models** installed on it, and a list of **links** at the end saying in which chat interface each model is shown (the inventory first, then the wiring). There is no other form: a file always has a `vms` array, even for a single machine (a stack is mostly several VMs in practice, and one form means one rule everywhere: in the session, in the editor, in the validation and in the slices). The `name` of a VM is only needed to be referenced, so it is optional when the file has **one** VM and no link, and required when it has several VMs or a link designates it ([`vms`](#vms)); the session, which does not know the number of VMs in advance, **always asks and writes it**. The file is read with `schema_version` 2.

**Names and references.** A `name` is always the free name of the object that contains it (a VM, a component, an instance of a model), chosen by the person and needed only to make **references** to it: without a reference it is optional. A reference is an object whose fields are called `<object>_ref` (`vm_ref`, `component_ref`, `model_ref`) and always hold the `name` of the object they designate (a VM, a component, an instance of a model), see [References](#references).

```json
{
  "schema_version": 2,
  "vms": [
    {
      "name": "gpu",
      "components": [
        { "component": "provisioning/llmfit" },
        { "component": "proxy/nginx", "options": { "server-name": "gpu.example.org" } },
        { "component": "engine/ollama", "name": "ollama", "default": true, "options": { "port": 11434 },
          "models": [
            { "model": "llama3.2:3b", "name": "llama3.2:3b" },
            { "model": "qwen2.5:7b", "force": true }
          ] }
      ]
    },
    {
      "name": "web",
      "components": [
        { "component": "proxy/nginx", "options": { "server-name": "ai.example.org" } },
        { "component": "chat-interface/librechat", "name": "librechat", "options": { "allow-registration": false } }
      ]
    }
  ],
  "links": [
    { "model": { "vm_ref": "gpu", "component_ref": "ollama", "model_ref": "llama3.2:3b" },
      "chat_interface": { "vm_ref": "web", "component_ref": "librechat" } }
  ]
}
```

`qwen2.5:7b` has no link: it is installed on `gpu` and used through its API.

A single machine is a file with one VM, and its links are written like any other, **complete**. The session asks, model by model, in which chat interface it is shown (see [spec: several VMs](spec-multi-vm.md#creating)), and never links the two without the person's answer; it writes the name of the VM (it asked for it) and the `name` of the engine and of the chat interface that the link designates (the implementation, written with no question):

```json
{
  "schema_version": 2,
  "vms": [ { "name": "vm-1", "components": [
    { "component": "provisioning/llmfit" }, { "component": "proxy/nginx" },
    { "component": "engine/ollama", "name": "ollama", "models": [ { "model": "llama3.2:3b", "name": "llama3.2:3b" } ] },
    { "component": "chat-interface/librechat", "name": "librechat" } ] } ],
  "links": [ { "model": { "vm_ref": "vm-1", "component_ref": "ollama", "model_ref": "llama3.2:3b" },
               "chat_interface": { "vm_ref": "vm-1", "component_ref": "librechat" } } ]
}
```

A link is the only place where the format designates one object from another, and it is **always explicit**: there is no resolution by default, whatever the number of VMs (see [References](#references)). The name of a lone VM is optional, like any name that nothing designates: a file with one VM and no name has no link (a link needs the `vm_ref` of its VM, which must then be a name).

**The format is ahead of the implementation.** It allows several engines or several chat interfaces on a VM, a free `name` for a component, several links for one model, and `options` on a model. The validation accepts, **for now**, one component per implementation on a VM (`duplicate_component`) and at most one link per model (`unsupported_count`), because the layer 1 scripts keep one state per component (see [open questions](#open-questions)); lifting those limits changes the validation, not the format. Several components of one type on a VM (an engine `engine/ollama` and an engine `engine/vllm`, once vLLM ships) is the first case to open.

### `vms`

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | with several VMs | The name of the VM: a string of lowercase letters, digits and dashes, starting with a letter (`gpu`, `web`, `vm-1`). Another type is `wrong_type`, another form `invalid_value`. Unique in the file: a second VM with the same name is `duplicate_vm`. **Optional when the file has one VM and no link** (a name is only needed to be designated: with one VM, the scripts and `--vm` have only one to choose from); a VM that a link designates must have it (`unknown_vm` otherwise), and with several VMs a VM without a name is `missing_vm_name`, at the path of that VM. The session always writes it |
| `components` | yes | The components installed on that VM, see below. At least one: a VM with none is `empty_vm` |

- The order of the VMs carries no meaning for the installation; it is the order of the summaries, of the scripts and of the next steps (the order of the file).
- A lone VM that has no name takes none: `apply` needs no `--vm`, `script` writes the file exactly at the path of `--output` (no `-<vm>` in the name, no `VM:` line in the header), and the editor asks the name of that VM when a second one is added or a link is written (it becomes required, [spec: several VMs](spec-multi-vm.md#editing)).
- Each VM is a machine of its own: what another VM holds is not on it. A requirement (`requires`) is satisfied by a component **of the same VM**.

### `components`

| Field | Required | Meaning |
| --- | --- | --- |
| `component` | yes | What the component is: `<type>/<implementation>`, the type being one of the contract types (`engine`, `chat-interface`, `proxy`, `provisioning`) and the implementation a shipped one (`<type>/<implementation>.sh`): `engine/ollama`, `proxy/nginx`. The same notation as the path of the script and as `--component` of `provisioning plan`. An unknown type is `unknown_type`, an implementation that is not shipped `unknown_component` |
| `name` | no | How the component is called **in its VM**, free, chosen by the person, and needed only to be designated by a `component_ref` of a [link](#links) (see [References](#references)). Same shape as the name of a VM. Left out: the component is **unnamed**, it has no default (the implementation is not its name) and cannot be the engine or the chat interface of a link; `plan` and `config validate` show the implementation as its label. Unique in the VM when written (`duplicate_name`). The session writes the `name` of every component a link designates, the implementation (`librechat`), with no question |
| `default` | no | Make it the default of its type, forwarded as `--default` (see [state format](spec-state-format.md#defaults)): it concerns the state of the machine only and **never decides what a reference designates**. At most one per type **on a VM** (`several_defaults`) |
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
| `model` | yes | The AI model, as the engine knows it (`llama3.2:3b`). Not a free name: it is the identity of the model. Unique in the engine (`duplicate_model`) |
| `name` | no | The free name of this instance in its engine, **needed to be the target of a link** (a [`model_ref`](#references) holds it; an instance with no `name` cannot be linked) and optional otherwise. Unique in the engine when written (`duplicate_name`). Its form is **freer than that of a VM or of a component**, since its usual value is the name of the model (`llama3.2:3b`, `qwen2.5:7b`, `library/llama3`): any non-empty string with no control character (another type is `wrong_type`, an empty or control-character one `invalid_value`). **The session fills it in by itself**, with the value of `model`, for every instance it writes and a link designates, and asks nothing: while an engine holds one instance per `model` (`duplicate_model`), the name of the model names the instance without ambiguity. It is also what will tell apart two instances of the same `model` with different `options` (vLLM) once `duplicate_model` is lifted |
| `force` | no | `true` skips the llmfit fit check, as `add --force` does |
| `options` | no | The options of this instance: those that the `describe` of the engine declares for its action `add-model`, in `action_options["add-model"]` ([script contract](spec-script-contract.md#describe)), the same form as the `options` of a component and the same checks (`type`, `values`, `required_when`, `sources`). `apply` passes each one to `add-model` as `--<name> <value>`, as it does for `install`. An option that a field of the instance already carries (`force`) is not repeated here. It is for an engine that runs **one process per model** (`per_model`, vLLM), whose instances have their own parameters; an engine that declares none (Ollama) refuses any (`unknown_option`) |

A model holds **no pointer to a chat interface**: where it is shown is written apart, in [`links`](#links). An unknown key, `chat_interfaces` included, is `unknown_key`.

**Why the model is in the engine.** An instance of a model lives where it is installed, so the engine that holds it is its container: there is no engine to resolve, nothing to point to the wrong component, the model travels with its component (and so with its VM) when a file is cut into [slices](#slices), and the file has the shape of the state of an engine, whose `models` array it mirrors ([state format](spec-state-format.md)). The same model on two engines is two instances, hence two entries, one in each engine; the same `model` twice in **one** engine is `duplicate_model`. Error paths are those of the file as written: `$.vms[i].components[j].models[k]`.

The **place** of a model is the engine component that holds it, on its VM: it decides everything that follows: the VM where the model is pulled and [sized](spec-model-fit.md#declared-resources), the engine that serves it, the proxy of its VM that fronts it, and the [next steps](spec-multi-vm.md#next-steps) that read its URL. `config validate` still exposes **a flat list** of the models in its plan, each with the `model`, and the VM and the component of its engine as resolved (see [spec: capabilities](spec-capabilities.md#config-validate)): it is an output document, not the file.

### `links`

An optional top-level array, **the wiring**, written after the inventory (the VMs, their components, their models). Each entry says that **a model is shown in a chat interface**:

```json
"links": [
  { "model": { "vm_ref": "gpu", "component_ref": "ollama", "model_ref": "llama3.2:3b" },
    "chat_interface": { "vm_ref": "web", "component_ref": "librechat" } }
]
```

| Field | Required | Meaning |
| --- | --- | --- |
| `model` | yes | A [reference](#references) to the instance of the model: `{ vm_ref, component_ref, model_ref }` (the VM, its engine, the `name` of the instance of the model), **the three fields required** |
| `chat_interface` | yes | A reference to the chat interface that shows it: `{ vm_ref, component_ref }` (the VM, its chat interface), **both fields required** |

A link is a relation between two objects that live in different places, so it is written **apart from both** and can be read from either end: the model holds no pointer to a chat interface, and a chat interface holds none to its models. A model with **no link** is installed and has none shown (an engine used through its API).

- **The same VM** (the two ends on one VM) is wired by `add` as on a single machine. **Another VM** is the link between two machines, which installs nothing and is finished by hand once the VMs are up (see [spec: several VMs](spec-multi-vm.md#next-steps)); the warnings and the next steps are computed **per link** whose two VMs differ.
- **Errors**, at the path of the link (`$.links[i]`, or the reference inside it): `missing_key` (a field of a reference that is not written: all are required), `unknown_vm` (a `vm_ref` that no VM has, a VM with no `name` included), `unresolved_engine` (the `component_ref` of a model names no engine of that VM), `unresolved_model` (the engine holds no instance whose `name` is that `model_ref`, an instance with no `name` written included), `unresolved_chat_interface` (the `component_ref` of a chat interface names none of that VM), `duplicate_link` (the same pair written twice), `unsupported_count` (a **second link of the same model**: the format allows several, the validation one for now) and `protected_engine_other_vm` (the model is in a `protected` engine and the chat interface on **another VM**: the link of two machines goes through the proxy of the engine's VM, which a `protected` engine does not have, and the contract does not yet say how such an engine publishes its URL and its key, see [spec: several VMs](spec-multi-vm.md#open-questions)).
- A link to a VM that has no proxy in front of an engine that is not `protected` is the [`missing_requirement`](#what-a-model-needs) of the model, as before.
- The resolved links go into the plan of `config validate` (`plan.links`, see [spec: capabilities](spec-capabilities.md#config-validate)).

### References

<a id="component-references"></a>A `name` designates the object that contains it; a **reference** designates an object from somewhere else. Its fields are called `<object>_ref` and **always hold the `name`** of the object they designate: a VM, a component, or an instance of a model (see [`models`](#models)). A `name` is for being designated and a `_ref` is for designating it: one vocabulary, no exception. The only references of the format are the two ends of a [link](#links), and they are **always complete**:

| Field | Required | Meaning |
| --- | --- | --- |
| `vm_ref` | yes | The `name` of the VM that holds the component. A name no VM has, or a VM that has no `name`, is `unknown_vm`, with the VM names of the file in the message |
| `component_ref` | yes | The `name` of the component on that VM (the engine in a reference to a model, the chat interface in a reference to a chat interface). A name that no component of that type has is `unresolved_engine` or `unresolved_chat_interface` (the message says so when the name exists with another type, or when the component has no `name` written) |
| `model_ref` | in a reference to a model | The `name` of the instance of the model, looked for in the `models` of that engine; none is `unresolved_model` (the message says so when an instance has that `model` but no `name`). Not in a reference to a chat interface |

A field that is not written is `missing_key`, at the path of the reference.

**A reference designates by `name` and is resolved by no rule of choice.** Nothing is deduced from the layout: not the only VM of the file, not the only engine or chat interface of a VM, not `default` (the flag belongs to the state). The configuration is **expressive and explicit**: a link says which model, on which engine, of which VM, is shown in which chat interface, of which VM, and what is added to the file later (a component, a VM, a second chat interface) **never changes what a link designates**, and cannot make it ambiguous: there is no ambiguity to detect. The cost is a few repeated names in the simple case, which the session writes and nobody has to type; the benefit is that a file is read, written by a program or an AI and validated the same way for one VM and for twenty, with no special case.

- **The principle of names** applies as it is: a `name` is free and optional, **needed only to be designated**. What a link designates must therefore have its `name` written: the VM, the engine and the chat interface and the instance of the model (its `name`, see [`models`](#models)). The session writes them (it asked the name of the VM, writes the implementation as the `name` of the engine and of the chat interface it links, with no question, and fills in the `name` of the instance with its `model`); a file written by hand or by a program writes them too, or the link is `unknown_vm`, `unresolved_engine`, `unresolved_model` or `unresolved_chat_interface`.
- The resolved references (the VM and the `name`, or the implementation as label, of each component, and the `name` of the instance) go into the plan of `config validate`, as written (see [spec: capabilities](spec-capabilities.md#config-validate)).

### Slices

The file is cut by VM, in the order of the file. A **slice** is a file of the same format with **one** VM (named when the file names it, as written), its components and so the models they hold, and the links that concern that VM, and is validated **exactly as a file of one VM**: order from `requires`, a requirement satisfied by a component of the VM only, options, secrets. Errors and warnings keep the paths of the file as written, and name the VM they are about.

- A model **travels with its engine component**, so it is in the slice of its engine's VM with nothing to resolve. A [link](#links) whose **two ends are on that same VM** is kept in the slice (the wiring of `add`, as on a single machine; the references are kept as written, complete); a link from a model of that VM to a chat interface of **another VM** is not in the slice: the other chat interface is not on this machine, and what the VM does must not depend on it. The link of two machines is finished by hand, see [spec: several VMs](spec-multi-vm.md#next-steps).
- **What a VM receives**: `script` embeds the slice in the script of its VM (see [spec: VM script generator](spec-vm-generator.md#generated-script)), and `apply` on the VM reads it, so that it knows nothing of the other VMs. Being a file of one VM, it needs no `--vm`.
- **`apply` on a file with several VMs** is refused (exit 2, listing the VM names) unless `--vm <name>` selects a slice, which is then applied as such. A file with one VM needs no `--vm`; `--vm` with an unknown name is exit 2. Pruning, `--dry-run` and the plan concern that slice only.

### Compatibility

`schema_version` is **2**. The format of version 1 (components with a flat `type` and `name`, a `vm` field, a top-level `links` made of pairs of VMs, the root `models` with the `engine` and `chat_interface` of a model) is **no longer read**: the project is in development and keeps no compatibility with it, so there is no converter. The `links` of version 2 is another array, one entry per model shown in a chat interface (see [`links`](#links)). A file with `schema_version` 1 is refused with `unsupported_schema_version` (exit 2) and a message that says the format changed and points to this section; a higher version is refused as before, never guessed. The validation stays **strict**: an unknown key is `unknown_key`. A generated script pins its package version and embeds a slice in the format of that version, so a script made for an older package keeps working with it.

### Validation

`apply` and the generator validate the file **before any side effect**, against the `describe` of the shipped scripts: unknown top-level key, unknown type, component or option, wrong value type, `schema_version` other than 2, a missing option that the component requires (`missing_option`), a secret given as a plain string, a `models` on a component that is not an engine (`models_on_non_engine`), a VM with no name in a file of several (`missing_vm_name`), a link that designates nothing or is incomplete (`missing_key`, `unknown_vm`, `unresolved_engine`, `unresolved_model`, `unresolved_chat_interface`), a link written twice (`duplicate_link`), more than one link for a model (`unsupported_count`) and a link of a `protected` engine to another VM (`protected_engine_other_vm`). Each problem is reported with its JSON path on stderr, and the exit code is 2. A higher `schema_version` is refused, never guessed. Each slice is validated as a file of one VM, and the codes of [`vms`](#vms), [`components`](#components), [`models`](#models), [`links`](#links), [References](#references) and [Slices](#slices) join the list of [spec: capabilities](spec-capabilities.md#config-validate). A model whose proxy or provisioning component is not in the file is `missing_requirement` too, see [What a model needs](#what-a-model-needs).

#### What a model needs

The validation also checks, for each model, what [`add`](spec-cli.md#add) will need to install it, so that a file that cannot finish is refused **before** anything is installed, not at the model step after the components:

| The model needs | Unless | Error when absent |
| --- | --- | --- |
| A component of type `proxy`, to expose it | The engine is **protected** (it enforces HTTPS and an API key itself, see [`protected`](spec-script-contract.md#describe)) | `missing_requirement` at the path of the model (`$.vms[i].components[j].models[k]`), naming the proxy |
| A component of type `provisioning` (llmfit, today), to check that it fits | The model has `force: true` | `missing_requirement` at the path of the model, naming the component |

- The component must be in the file (on the **VM of the engine that holds the model**: a proxy on another VM does not expose this engine) or, with `--target this`, already installed. It is the rule of a `requires`, so the code is the same and `apply` keeps its exit 4 for it.
- It is the same decision as `add` makes, read from the file and from the `describe` of the engine: the validation never runs an action. An engine whose `describe` does not say it is protected is not.
- A model with no [link](#links) is not concerned by the chat interface: only the proxy and a provisioning component are needed.
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
4. **Models**: for each, the equivalent of [`add`](spec-cli.md#add) with the engine that holds it and the chat interface of its [link](#links) in the slice (`--no-chat-interface` when the model has no link in the slice, `--force` when set), including the fit check, the wiring and its rollback.
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
- `bats` tests of the format of version 2: `wrong_type` and `invalid_value` on the name of a VM, `duplicate_vm`, `missing_vm_name` (a VM with no name among several, and accepted for a lone VM), `empty_vm`, `unknown_type` and `unknown_component` on `component`, `duplicate_name`, a component with no `name` (unnamed, no default name), `duplicate_component` (also with two different `name`s), `missing_option` for each `required_when` of the shipped components (and not raised when the condition does not hold), the same component on two VMs accepted, `several_defaults` per VM, a requirement satisfied by another VM refused, `schema_version` 1 refused with its message, and a flat file refused.
- `bats` tests of the [models](#models): a model in an engine, `models_on_non_engine` on another type, `duplicate_model` (the same `model` twice in one engine) and the same model accepted in two engines, `model` required, the `name` of an instance (any non-empty string without control characters, `wrong_type` and `invalid_value`, `duplicate_name` in one engine), an instance with no `name` accepted but not linkable (`unresolved_model`), `options` of a model refused with `unknown_option`, a `chat_interfaces` on a model refused (`unknown_key`), `wrong_type` on `models` or on a model, `force`, error paths `$.vms[i].components[j].models[k]`.
- `bats` tests of the [links](#links): a link in a file of one VM and of several VMs, each written complete; `missing_key` for each field of each reference left out (also in a file of one VM: nothing is evident), `unknown_vm` (also a VM that has no `name`), `unresolved_engine`, `unresolved_model` (a model the engine does not hold, a model of another engine), `unresolved_chat_interface` (also when the name exists with another type, and for a component that has no `name`), `duplicate_link`, `unsupported_count` on a second link of one model, `protected_engine_other_vm` (a `protected` engine, with a fake component, whose model is linked to a chat interface of another VM; accepted when it is linked to one of the same VM), a model with no link accepted, error paths `$.links[i]`.
- `bats` tests of the [references](#references): a link designates by `name` (`vm_ref`, `component_ref`, `model_ref`, with `default` ignored), and nothing is resolved by default: a component added on another VM, a second chat interface added on the VM aimed at, or a VM added, change no link (the same file, validated before and after, gives the same plan).
- `bats` tests of the [slices](#slices): each without the other VMs, models with their engine, a link whose two ends are on the VM kept (complete, as written) and a link to another VM dropped, order of the file, paths of the file as written, `apply` refused without `--vm` on several VMs, accepted without it on one, `--vm` with an unknown name, `apply --vm` applying one slice.
- `bats` tests of [what a model needs](#what-a-model-needs): a model with no proxy in the file is `missing_requirement` at its path (target `fresh`), and accepted when the proxy is installed (`--target this`); a `protected` engine needs none; no provisioning component without `force` is `missing_requirement`, and accepted with `force`; with several VMs, a proxy or a provisioning component on another VM does not count, and an engine VM with no model and no proxy is valid; the exit code of `apply` is 4 when it is the only kind of error.
- `shellcheck` clean.

## Open questions

- **Literal secrets in the file.** Answer: forbidden, see [spec: machine interface](spec-capabilities.md#secrets). The file is embedded in the generated VM script, so a literal would sit in the script and, on CloudStack, in the user-data, which is not confidential (see [contract](spec-script-contract.md#secrets)). Options: forbid literals (only `file`, `env`, `generate`), or allow them with a `WARN`. Same question as in [spec: VM script generator](spec-vm-generator.md#open-questions), to be settled together.
- **Closed: implicit references.** Settled by the rule of [References](#references): a link is always explicit, so there is nothing to resolve by default, no ambiguity and no `implicit_reference` warning. If the repetition of names in the simple case proves a burden in practice, an optional shorthand could be specified later, with its own stability rule; it is not needed now.
- **Several links per model.** The format allows a model to be shown in several chat interfaces (one entry of `links` each); the validation accepts one link per model for now (`unsupported_count`). What the next steps and the sizing do with several (one `add-endpoint` per link) is specified with [spec: several VMs](spec-multi-vm.md#open-questions) when the limit is lifted.
- **Several instances of one component on a VM** (e.g. two `engine/ollama` with different ports): the format allows them (a free `name`, [`components`](#components), designated by a `component_ref`), the validation refuses them (`duplicate_component`) because the state of layer 1 has one entry per component, one unit, one port, one Compose project. Lifting the limit is a change of layer 1 (state keyed by instance, units and volumes named by instance), then of the validation. Several components of **one type** with different implementations (`engine/ollama` and `engine/vllm`) need the same state change only for what they share, and are the first case to open.
- **Schema evolution**: how a new `schema_version` is migrated, once a second version exists.
