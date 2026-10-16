# Spec: model fit and VM sizing

[← Back to docs](README.md)

**Status:** accepted, implemented (actions `suggest`, `check`, `plan` and `size` of `provisioning llmfit`, tested in `tests/unit/llmfit.bats`). The [declared resources](#declared-resources) and [a stack with no model](#a-stack-with-no-model) are **proposed, not implemented**: until they are, the margin below is the constants of `plan`.

## Purpose

Choosing models, and knowing what VM they need, is one **capability** of the product ([spec: capabilities](spec-capabilities.md)), implemented as actions of the `provisioning llmfit` component. It is the second step of the models part of the [journey](spec-journey.md#4-models): whoever walks it, a person answering questions or a program passing arguments, calls the same actions and gets the same answers. The text a person reads and the JSON a program reads come from the same document ([rendering](spec-rendering.md#one-document-two-renderings)).

**There is no sizing logic outside these actions.** The interactive session only asks the questions, calls the action and shows what it prints; a new rule (another margin, another filter) is a change of the llmfit script, never of the session.

It builds on the [script contract](spec-script-contract.md#type-specific-actions) and the [configuration](spec-config.md); it does not repeat them.

## Model fit for a machine that is not this one

`provisioning llmfit suggest` and `check <model>` evaluate the **local** hardware. Whoever prepares a fleet knows the specs of the target from the user, not from `host`. llmfit overrides the detected hardware with `--memory`, `--ram` and `--cpu-cores` (see [findings](../search/llmfit.md)), so the two actions gain, as options:

| Option | Meaning | Forwarded to llmfit as |
| --- | --- | --- |
| `--target-ram <GB>` | RAM of the machine to size for | `--ram` |
| `--target-vram <GB>` | GPU memory of the machine to size for | `--memory` |
| `--target-cpu-cores <n>` | CPU cores of the machine to size for | `--cpu-cores` |

With none of them, behaviour is unchanged (local hardware). They are declared in the `describe` of the llmfit script under `action_options`, keyed by action (`suggest`, `check`), and not in `options`, which are the options of `install` and of the configuration; they are therefore in `catalog` too. The options are read-only and need no engine; llmfit itself must be installed, otherwise the action exits 4 with the command that installs it (`easy-cs-ai install provisioning llmfit`). Installing it is a change on the machine, so it is the user's decision, see [llmfit is optional](#llmfit-is-optional).

### Two orders, one implementation

A user either has a VM imposed (**hardware first**) or has models in mind (**models first**); the [journey](spec-journey.md#4-models) offers both. Both orders are actions of the `provisioning llmfit` component, so that every way to walk the journey shares the code and never the logic twice:

| Order | Action | Answer |
| --- | --- | --- |
| Hardware first | `suggest` with the `--target-*` options | The models that fit, already filtered (Ollama tag, not `Too Tight`) and ranked by score, see the [script contract](spec-script-contract.md#type-specific-actions) |
| Hardware first, a model named by the user | `check <model>` with the `--target-*` options | `fits` and `reason` |
| Models first | `plan [<model>…] [--target-cpu-cores <n>] [--component <type>/<name>]…` (`--component` is proposed, see [declared resources](#declared-resources); today only `--chat-interface` exists, and it is kept afterwards as the shorthand of `--component chat-interface/librechat`) | The VM the models need: the model figures from llmfit, the **estimated margin** and the total, for RAM without GPU, GPU memory with a GPU, and disk, for the `best` and the `default` quantisation, plus the models llmfit could not size (`unsized`) |

`suggest` and `plan` have a **text for a person by default** and the JSON documents of the [script contract](spec-script-contract.md#type-specific-actions) with `--json`. The text is rendered by the action from the same document, so the two cannot differ (see [rendering](spec-rendering.md#one-document-two-renderings)).

Whoever presents the result of `plan` does so as the text does: the model figure and the estimated margin side by side, never a single total that looks measured, the two quantisations, and the unsized models listed as not covered. It does not compute the margin itself. `plan` has no `--target-ram` or `--target-vram`: in this order the hardware is the answer, not the question.

The configuration does not store the target specs: the fit is checked **at run time on the target** (`add`, as before), and what is asked of llmfit while preparing is only an early opinion. A model proposed that does not fit on the target is refused at `apply` (or accepted with `force`).

## Choosing models in a session

This is how the interactive rendering of the [models step](spec-journey.md#4-models) asks for the two orders. A program passes the same information as arguments of the actions above.

A model name is engine-specific and nothing tells the administrator whether it fits the VM. When llmfit is available (see [llmfit is optional](#llmfit-is-optional)), the step asks first **in which order to work**, because an administrator either has a VM imposed or has a model in mind:

| Choice | Meaning |
| --- | --- |
| `h` (hardware first, default) | The administrator gives the specs of the VM, the session suggests the models that fit them (below) |
| `m` (models first) | The administrator names the models, the session computes the VM they need, see [Recommended VM](#recommended-vm) |

The choice is offered again as the default when the step is redone, which is how the administrator switches order. In the `m` order no spec is asked: the cores given in an earlier pass of the `h` order, if any, are the vCPU of the recommendation. In the `h` order, the step asks for the **specs of the target VM**, each answer optional (empty means "do not size on it"):

| Question | Forwarded as |
| --- | --- |
| RAM of the VM, in GB | `--target-ram` |
| GPU memory of the VM, in GB (empty for a CPU-only VM) | `--target-vram` |
| CPU cores of the VM | `--target-cpu-cores` |

Then:

1. With at least one spec, it lists what `provisioning llmfit suggest` returns for them, numbered: the ten best by score, only the models that carry an Ollama tag (the only names an engine can pull today, so the list is offered for `ollama` only) and none that llmfit judges `Too Tight`. The selection is made by the action, not by the session. The administrator picks by number, by name, or types another name; an empty answer adds no model. With **no** spec at all, there is no list and no check, because llmfit would size for the machine running the session, not for the VM; the session says so.
2. Each model typed that is not in the list is submitted to `provisioning llmfit check <model>` with the same specs. A negative verdict, or a model llmfit does not know (it knows Hugging Face names and the Ollama tags of the models that fit), is a **warning**, repeated in the summary with llmfit's reason: the administrator knows their VM, nothing refuses a model on that opinion.
3. The specs are asked again only when the step is redone (`m` at the summary offers the previous answers as defaults; `none` clears one). An answer that is not a positive whole number is asked again.

The specs and the verdicts are **not** stored in the configuration: it stays valid for any VM and the fit is checked on the target at run time. They are an early opinion, nothing more.

## Recommended VM

In the `m` order, once the models are named (each one is sized as the step ends, with a progress line), the session tells the administrator **what to ask for when creating the VM**, from what llmfit reports for each model (`memory_required_gb`, `run_mode`, see [findings](../search/llmfit.md)). The recommendation is printed once, in the summary, next to the warnings read before the VM is created, and again whenever the summary is. It recommends characteristics, it provisions nothing and produces no VM template or image:

| Item | Derived from |
| --- | --- |
| Model memory | The largest `memory_required_gb` among the models, assuming they are not loaded at the same time. It already includes the context llmfit assumes (see [checked](#sizing-checked-with-llmfit)) |
| GPU or CPU only | **Not** derived: `run_mode` only reflects the machine llmfit was told about. Both are shown, RAM for a CPU-only VM and GPU memory for a VM with a GPU, and the administrator picks. The speed is not shown either: llmfit estimates it for the CPU of the machine running the session, not for the VM |
| Margin | **Estimated**, added on top of the model memory, see [Estimated margin](#estimated-margin) |
| Disk | The sum of the `disk_size_gb` of the models (they are all stored), plus the estimated margin of the system and components |
| vCPU | The cores given in an earlier pass of the `h` order, else `not sized by llmfit`: llmfit says nothing of them |

Each memory figure is given **twice**, for two quantisations, because the one an engine actually loads depends on the engine and on the model: the **best** one llmfit finds for a large target (usually `Q8_0`), and the **default** one of the model, which llmfit reports for a target too small for anything (`Q4_K_M` for every model checked). The session does not say which one the engine will use, it shows the two and the administrator decides: the default one is enough when the engine loads the usual 4-bit model, the best one covers an engine that loads more precise weights. The default figure comes from `llmfit info` asked for a **tiny target** (`--ram 1`): llmfit then falls back to that quantisation and its verdict is `Too Tight`, which the session ignores here. It relies on that fallback, so the tests must catch a change of behaviour of llmfit (see [Definition of done](#definition-of-done)).

The session gets the whole recommendation, margin included, from the `plan <model>…` action of the `provisioning llmfit` component (see the [script contract](spec-script-contract.md)), called with one `--component` per component of the stack (proposed, see [declared resources](#declared-resources); today a single `--chat-interface`; with several VMs, the stack of the VM it sizes: an engine VM with no chat interface gets no share for it, see [spec: two VMs](spec-two-vm.md#in-the-session)) and with the cores of the `h` order as `--target-cpu-cores`; it only prints the text it receives (the same figures are in the JSON of `--json`). `plan` is built on `size <model>`, which makes the llmfit calls below and answers one JSON document per model. A model it cannot size is `not estimated`. llmfit loads its catalogue on every call, and sizing one model took 10 to 19 seconds with the four calls in sequence (measured with llmfit 1.1.17): the action runs the four calls **together**, and the session announces each model before it sizes it (`sizing <model> with llmfit (1/3), a few seconds...`), so the wait does not look like a hang. The figures are taken so that they do not depend on the machine the session runs on: llmfit is asked for a **very large target** (`--ram`, and `--memory` for the GPU figure), so that it reports the memory of its best quantisation, and the context is the one llmfit assumes (8192 tokens, shown in the recommendation). A model name is the engine's own: a Hugging Face name (what vLLM takes) is already what `llmfit info` needs, and an Ollama tag is turned into one through the `ollama_name` field of `llmfit fit --json -n 100000`, asked for the same large target. A name that llmfit cannot resolve is `not estimated`. Nothing in the recommendation is specific to an engine: another engine only needs its own way to name a model.

### Estimated margin

llmfit's figure covers the weights and the cache of its assumed context, not what runs around the model. The `plan` action therefore **adds a margin and says so**, and the text of the action, and so the session, displays it as such: every recommendation is displayed as `<model memory> + <margin> (estimated margin)`, with the breakdown of the margin, never as a single total that looks measured. The margin is a planning estimate, not a measurement:

| Part | Estimate | Basis |
| --- | --- | --- |
| GPU memory | model memory ÷ 0.9, plus 1 GB | An engine such as vLLM uses 90 % of the GPU memory by default (0.9, 0.9 to 0.95 deemed safe) and the CUDA context, graphs and buffers come on top (about 0.8 GB measured by one source, 0.5 to 1 GB for the llama.cpp backends) |
| RAM, VM without GPU | model memory, plus 1 GB for the engine process, 1 GB for the system | Canonical gives 1 GB as the minimum of an Ubuntu 24.04 cloud image, and one measurement 0.3 GB idle |
| RAM, VM with a GPU | 2 GB for the system and the engine, nothing for the model | The weights live in GPU memory |
| Chat interface and its databases | 4 GB when a chat interface is in the stack, 0 otherwise | Set before the stack was chosen, from the figures of a **fuller** stack than the shipped one (LibreChat 1 to 2 GB, MongoDB about 1 GB, Meilisearch 0.5 to 1 GB, a RAG worker 0.5 GB: 4 to 8 GB in one estimate). The shipped stack is LibreChat, FerretDB and PostgreSQL, with no Meilisearch and no RAG ([decision](decision-librechat-install.md#2-the-stack-its-pinning-and-its-unit)), measured at idle with an empty database at about 0.55 GB (API 420 MiB, PostgreSQL 100 MiB, FerretDB 12 MiB, see [findings](../search/librechat.md)). So 4 GB is an overestimate, kept until the [declared resources](#declared-resources) replace it by 2 GB |
| Disk | 20 GB for the system and the components | Not sourced: a guess (an Ubuntu cloud image, the engine, and the images of a chat interface and its databases), the least reliable figure of the table |
| Rounding | Up to the next whole GB | |

These values come from vendor documentation for some (Ubuntu, MongoDB, Meilisearch, vLLM) and from blogs and forums for the rest (Ollama, LibreChat), none of which measures this project's stack. They are a starting point to calibrate with `docker stats` and `free` on a real VM, see [open questions](#open-questions). The margin is a constant of the `plan` action (not of the session, so that an agent gets it too), not a result of llmfit, and is the same whatever the engine. This is today's state: with the [declared resources](#declared-resources) the margin follows the components named, and only the system constants stay in `plan`.

It is shown at the end of the step and repeated in the summary, with the equivalent for a CloudStack **compute offering** (vCPU, RAM, GPU) and a disk size, so that it can be typed in as is. A model for which llmfit has no figure (see [open questions](#open-questions)) is listed as `not estimated` and the recommendation says it does not cover it: a value is never invented.

Like the verdicts, the recommendation is **not** stored in the configuration and is only an early opinion; the fit is still checked on the target.

### Declared resources

Proposed, not implemented. The table above is today's state: the engine, chat interface and disk figures are constants written in `plan`, whatever the stack is. This section moves the part that belongs to a component into the component. The **nature of the margin does not change**: it is an estimate, shown as such, never a minimum and never a measure.

**Each component declares what it adds around the models** in the `resources` of its `describe` (fields and rules in the [script contract](spec-script-contract.md#describe)): `ram_gb`, `disk_gb`, a `source` (`measured`, `vendor` or `guess`) and a `basis`, plus `per_model` and `gpu` for an engine. Adding or swapping a component is therefore a change of that component's script, never of `plan`, and the VM of a stack is the sum of what its components declare.

**`plan` takes the stack as `--component <type>/<name>` (repeatable)** and reads the `resources` of each from its `describe`, the same one `catalog` prints, by running the `describe` of the sibling script found through `EASY_CS_AI_LIB` ([script contract](spec-script-contract.md#sizing-reads-describe)); a script that is absent leaves the component undeclared. The arithmetic, the constants that remain and the rounding stay in `plan` and nowhere else.

| Part | Computed as |
| --- | --- |
| RAM, VM without GPU | model memory, plus **1 GB for the system** (constant of `plan`), plus the `ram_gb` of every component named (an engine with `per_model` once per model it holds), rounded up to the next whole GB |
| RAM, VM with a GPU | 1 GB for the system plus the same `ram_gb`, no model memory (the weights live in GPU memory), rounded up |
| GPU memory | For each engine named, `model ÷ utilization + fixed_gb` from its `gpu` declaration, the largest of them (models are not loaded at the same time, as for the RAM); rounded up. An engine with no `gpu` declaration is sized with the generic rule below and reported undeclared |
| Disk | The `disk_gb` of the models (llmfit), plus **10 GB for the system** (constant of `plan`, a guess), plus the `disk_gb` of every component named, rounded up |
| No engine named | The generic engine of today: 1 GB of RAM, `model ÷ 0.9 + 1` of GPU memory, no disk, marked undeclared. It is the case of a caller that names no component |

- **Which engine holds a model.** `plan` is called **per VM**, with the models whose [place](spec-config.md#where-a-model-goes) is that VM. A model argument may carry its engine as `<model>@<engine>` (an Ollama tag or a Hugging Face name never contains `@`), which is what `per_model` counts on and what picks the `gpu` rule of that engine. Without `@`, the model goes to the only engine named by `--component`; with several engines named, a model without `@` is a usage error (exit 2), and with no engine named it goes to the generic engine. The session and a program that follows the [journey](spec-journey.md) pass the engine of the place.
- **What does not move into a component**: the system (RAM and disk of the image, which belong to no component) and the rounding. They stay constants of `plan`, displayed as such.
- **A component without `resources` is undeclared.** It adds nothing, is listed in `undeclared` and in the text (`not covered: <names>`), and the margin is described as incomplete. It is the same rule as a model llmfit cannot size: a figure is never invented.
- **Every part carries its source.** The text shows `<n> <part> (<source>)` for each one (for example `2 chat interface (guess)`), and the JSON carries it in `components[].source`, so that the least reliable figure is the one a reader sees, not the total alone. A total is as reliable as its least reliable part, and the text says which it is.
- **`ram_no_gpu.margin_parts` keeps its keys** (`engine`, `system`, `chat_interface`, each 0 when absent) and adds one key per other type named (`proxy`, `provisioning`), keyed by type, so a caller that reads it keeps its meaning.
- **Two parts change their keys, which is a change of the document for a caller that reads them.** Today `gpu_ram.margin_parts` is `{ system_and_engine, chat_interface }` and `disk.margin_parts` is `{ system_and_components }`, one lump each. With declared resources they take the same shape as `ram_no_gpu`: `system` (1 GB of RAM, 10 GB of disk) and one key per type named, so that each part has its own source. `gpu_memory` keeps its `margin_basis`. The text of `plan` reads these keys, so it changes with them. `guide.txt` sends an agent to `plan --json`, so the guide and the tests that read these keys change in the same commit; whether to keep the old keys for one version is left open.

#### Values of the shipped components

Starting values, to calibrate (see [open questions](#open-questions)). The engine's RAM and the GPU rule reproduce today's constants. Two things move: the disk, since two parts become sourced, and the RAM of a stack with a chat interface, which falls from 4 to 2 GB because the old figure was that of a fuller stack than the shipped one (see the table above). The RAM margin of the reference stack (Ollama, LibreChat, nginx, llmfit) is therefore 4 GB instead of 6 for a VM without GPU (1 system, 1 engine, 2 chat interface), and 4 instead of 6 for the RAM of a VM with a GPU:

| Component | `ram_gb` | `disk_gb` | `source` | `basis` |
| --- | --- | --- | --- | --- |
| `engine/ollama` | 1 | 2 | `guess` | The process of the engine (today's constant); the disk is the release archive, about 1.4 GB with its GPU libraries (see [`install`](spec-script-contract.md#behaviour-of-install)), rounded up. `gpu`: `utilization` 0.9, `fixed_gb` 1, the rule of the table above |
| `chat-interface/librechat` | 2 | 6.2 | `guess` (the RAM is a guess, the disk is measured: the object takes the least reliable) | `api`, FerretDB and PostgreSQL measured at idle, empty database, about 0.55 GB (420 + 100 + 12 MiB); the RAM declared is about four times that, to cover the start of the containers, accounts and conversations, which are not measured. The images take about 6.2 GB on disk (see [LibreChat](decision-librechat-install.md#2-the-stack-its-pinning-and-its-unit)) |
| `proxy/nginx` | 0 | 0 | `guess` | Small beside the rest; to measure |
| `provisioning/llmfit` | 0 | 0 | `guess` | A binary and a catalogue, no service |

With the system's 10 GB, the disk margin of the reference stack (Ollama, LibreChat, nginx, llmfit) becomes 18.2 GB (the total is rounded up) instead of the 20 GB constant of today. This is not a better figure, it is a different split of a guess: it is the least reliable part of the table and the text says so through the source.

### A stack with no model

Proposed, not implemented. `plan` with at least one `--component` and **no model** answers for a VM that holds no model. Two cases are covered, and the answer does not depend on which one it is:

- the web VM of [spec: two VMs](spec-two-vm.md#topology), with no engine, whose chat interface comes up with an empty model list;
- a VM **with an engine and no model yet**: the administrator named none in the session, or the engine (vLLM) is installed first and receives its models later, which is a valid state ([script contract](spec-script-contract.md#engines-with-one-instance-per-model)).

The rules:

- No llmfit call is made, so llmfit does not need to be installed for it (exit 4 is only for a model to size).
- The document has `models: []`, `quantisations: null` and a `stack` entry: the RAM (1 GB of system plus the declared `ram_gb` of every component named, rounded up) and the disk (10 GB of system plus the declared `disk_gb`, rounded up), each as `margin_parts` and `total_gb` with `model_gb` 0, and `models_included: false`. An engine named counts its own `ram_gb` and `disk_gb` like any component (a `per_model` engine adds no RAM, since it holds no model; its `disk_gb` is counted).
- **The figures do not cover the models, and the text says so.** A VM with no model is not a VM that will stay without one: the administrator must plan resources **on top of** these figures for the models they will add later (their memory, their disk, and the GPU memory). The text therefore ends with a line, `models not included: add the memory, GPU memory and disk of each model you will install on this VM`, and `stack.models_included` is `false`, so that a program shows the same warning. It is the capability's, not the session's ([rule 4](spec-journey.md#rules)): the session prints it as it receives it. The line is there whatever the stack is, with or without an engine.
- **There is no GPU figure, engine or not**: the GPU rule (`model ÷ utilization + fixed_gb`) turns a model memory into a GPU memory, and with no model there is nothing to turn. The text says it when an engine is named (`GPU memory: not sized, no model`), so a VM that will get a GPU model is not read as needing none. Adding a model later is a new call.
- `vcpu` is `--target-cpu-cores` if given, else `null`, as for a stack with models.
- The text says `VM with no model: RAM <n> GB, disk <m> GB` followed by the estimated parts and their sources, the same `not covered` line for undeclared components, and the `models not included` line above.
- With no model and no component, it is a usage error (exit 2), as today. `--chat-interface` alone, being the shorthand of `--component chat-interface/librechat`, is a component: with no model it now answers with a stack instead of exit 2.
- The session calls it **whenever a VM ends with no model**, so that every such VM gets a recommendation and the warning that the models come on top: each pass of a [two-VM session](spec-two-vm.md#in-the-session) with no model, and a one-VM session that names none. For the one-VM case this adds the recommendation to the summary (see [what does not change](spec-two-vm.md#what-does-not-change)).

## llmfit is optional

llmfit has two roles around the session, and neither is mandatory.

- **On the machine running the session** (the administrator's own): it only feeds [Choosing models in a session](#choosing-models-in-a-session). It is available when `provisioning llmfit status` reports it installed and healthy, whatever the stack chosen for the VM. If it is not, and the package ships it, the step **offers to install it now** (`llmfit is not installed here: install it now, to get model suggestions and a fit check? (y/n)`, default `n`, asked once per session, not again when the step is redone) so that the session goes on with the specs and the suggestions.
  - The answer is the consent: nothing is installed without a `y`. The install is `provisioning llmfit install` run on this machine (the session's "fresh VM" planning, `EASY_CS_AI_ASSUME_EMPTY`, is lifted for it), with `sudo` when the session does not run as root. It needs root and the network (the release archive is downloaded and its checksum verified), so an administrator on a restricted network answers `n`.
  - Declined, impossible (no `sudo`) or failed (no network, checksum, exit code of the script): a message with the command to run later (`sudo easy-cs-ai install provisioning llmfit`), a warning for a failure, then the model names as free text. The session never fails because of llmfit, and a failed install leaves the session as if it had been declined.
  - A package that ships no llmfit offers nothing, and says so.

  A program that walks the journey follows the same rule without the prompt: it asks the user before running `install provisioning llmfit`, and without a yes it falls back to the model names the user gives.

  `--config` and `--config-only` with a complete file do not need it either, and are never asked.
- **On the VM** (the `provisioning llmfit` component of the stack): it checks, at run time, that each model fits. It is a component like the others of the [components step](spec-journey.md#2-components-and-dependencies): offered with its rank, and the administrator may answer `none`. The prompt says what declining costs. When the session ends with models and **no** llmfit in the stack, the session writes every model with `"force": true` (the fit check is skipped, as `add --force` does, so `apply` does not stop on the missing requirement) and the summary carries a warning: `models not checked for fit on the VM: llmfit is not part of the stack`. Declining llmfit is therefore a supported, explicit choice, never a late failure of the generated script.

The warning comes from the configuration (a model with `force` and no provisioning component), so a `--config` file gets it too. With several VMs it is judged **per slice**: a provisioning component on another VM does not count, since the fit is checked on the VM that holds the model. The `force` is added only by an interactive session, where the administrator has been told; a file is never changed. The validation also checks that a model without `force` has an llmfit to be checked by, in the same slice: otherwise `apply` would find out at the model step (exit 4, after the components are installed, see [`add`](spec-cli.md#add)). It is `missing_requirement` at the path of the model, see [what a model needs](spec-config.md#what-a-model-needs). A session never meets it, since it writes `force` when the stack has no llmfit.

## Definition of done

- `provisioning` tests: the `--target-*` options reach llmfit as `--ram`, `--memory`, `--cpu-cores`, before the subcommand; llmfit missing is exit 4 with the install hint; `suggest` (Ollama tags only, no `Too Tight`, best score first, at most `-n`, empty list on no result), `plan` (margin parts and totals for both quantisations, `--chat-interface`, `unsized`, no model and no component is exit 2). The tests of the session check that it prints what these actions return and computes nothing of its own.
- `bats` tests of the `size` action of the llmfit script with a fake llmfit binary (the four calls, an Ollama tag, an unknown model), and of the order of the models step with a fake llmfit: `h` as the default, `m` computing the recommended VM from the models (memory for the two quantisations, GPU or CPU, disk, CloudStack equivalent), the margin shown apart and labelled `estimated margin` with its breakdown, no chat interface in the stack giving no chat part, a Hugging Face name and an Ollama tag both resolved, a model without a figure listed as `not estimated`, the recommendation printed once, in the summary, and absent from the configuration, the order offered again as the default when the step is redone.
- A test of the default-quantisation fallback against the real llmfit when it is installed (skipped otherwise): `info` with `--ram 1` reports a quantisation and a memory for a few models, so that a change of behaviour of llmfit is caught at its upgrade.
- `bats` tests of the model step with a fake llmfit script: the session prints what `suggest` and `plan` return and computes nothing itself (a changed margin or filter in the fake shows up unchanged in the output).
- Tests of the [declared resources](#declared-resources), with fake components whose `describe` carries `resources` (`EASY_CS_AI_LIB` pointing at the fake tree; a named component with no script there is `undeclared`, exit 0, and a `describe` that is not valid JSON is `undeclared` with a `WARN`): the margin is the system constants plus the sum of the declarations (RAM with and without GPU, GPU memory from the `gpu` rule, disk), `per_model` counts the RAM once per model of that engine (`<model>@<engine>`, a model without `@` on one engine, exit 2 on several engines), two engines give the largest GPU figure, a component without `resources` is `undeclared` and adds nothing, `0` is declared and not undeclared, the source of each part is in the text and in `components`, no `--component` gives today's generic engine, and `--chat-interface` gives the same document as `--component chat-interface/librechat`. For the shipped components, the GPU rule and the engine's RAM are those of today, the RAM margin of the reference stack is 4 GB (2 of it for LibreChat), and a test checks that every shipped `describe` has a well-formed `resources` (numbers not negative, a known `source`, a `basis`).
- Tests of [a stack with no model](#a-stack-with-no-model): `plan --component …` with no model gives `stack`, no llmfit call (llmfit absent is not exit 4), the text line, and no model and no component is exit 2, `--chat-interface` alone gives a stack; `quantisations` is `null`; the `models not included` line is in the text and `stack.models_included` is `false`, with or without an engine; with an engine named (a plain one and a `per_model` one) the engine's `ram_gb` and `disk_gb` are counted, `per_model` adds no RAM but its `disk_gb`, there is no GPU figure and the text says `not sized, no model`; `vcpu` follows `--target-cpu-cores`. The session of one VM with no model prints that text, and a session with a model does not.

## Open questions

- **Sizing from a model**: [checked with llmfit 1.1.17](#sizing-checked-with-llmfit). What stays open is **calibrating the [estimated margin](#estimated-margin)**: measuring the real consumption of the stack (engine, chat interface, databases) on a fresh VM, with `docker stats` and `free`, and replacing the `guess` of each [declaration](#declared-resources) by a `measured`. What also stays open is that the default-quantisation figure relies on a **fallback of llmfit** (a tiny target gives the model default), not on a documented option: to watch at each llmfit upgrade, and to replace by an option if llmfit gains one. A **mixture-of-experts** model (`is_moe`) does not follow the rule below: its memory does not move with the quantisation (17.1 GB from `Q2_K` to `Q8_0` for `Qwen3-30B-A3B`), its disk size is larger than its memory, and the figure differs between a CPU and a GPU target (17.1 and 15.6 GB). For those the recommendation shows the figure as reported and flags it as less reliable.
- **How `plan` reads the declarations.** Settled: `plan` runs the `describe` of the sibling scripts, found through `EASY_CS_AI_LIB`, and a missing script makes the component undeclared (see [the script contract](spec-script-contract.md#sizing-reads-describe)). That keeps `provisioning llmfit plan` usable on its own and the layer independent of the CLI. What stays open is the cost: one `describe` per component at each call, which is small beside the llmfit calls.
- **One `source` per component.** A component whose RAM is a guess and whose disk is measured (LibreChat) is declared `guess`, so a measured figure is not shown as such. A `source` per figure would say more and cost a heavier `describe`.
- **Sizing from a configuration.** A program that has written a file with `vm` fields lists the components of each VM again to call `plan`. A `plan --config <file> --vm <name>` would read them from the file, as `config validate` does, at the price of a second way to reach the same action. Not specified until the two-VM session is implemented.
- **The preflight floors.** `install` refuses a VM below its own floors (Ollama: 6 GB on `/usr/local`, LibreChat: 12 GB free on `/var/lib/docker`), which are neither the estimate nor the minimum of a running stack. Whether they should be declared too, so that the recommendation never gives a VM that the preflight refuses, is open: the disk estimate of the reference stack (18.2 GB plus the models) is well above them, but a smaller stack is not.
- **GPU memory shared between instances.** The `gpu` rule is per model for an engine that runs one instance per model; how several instances share one GPU is already open in the [script contract](spec-script-contract.md#engines-with-one-instance-per-model) and is not settled by `per_model`, which counts RAM only.

## Sizing checked with llmfit

Measured with llmfit 1.1.17 (Linux release, in WSL), to settle the first question above:

- **The requirement depends on the machine.** llmfit reports the memory of the best quantisation that fits the machine it is told about. `Qwen/Qwen3-4B-Instruct-2507` gives 3.11 GB (`Q2_K`) at `--ram 4`, 4.84 GB (`Q6_K`) at 6, then 5.85 GB (`Q8_0`) from 8 GB up, unchanged at 16 and 64. Sizing for a large target therefore gives a stable figure.
- **The context counts.** `--max-context` 2048, 8192 (the assumed default) and 32768 give 5.0, 5.85 and 9.22 GB for the same model.
- **The memory is the weights plus a constant per model**, over six models: `memory_required_gb − disk_size_gb` is 1.5 GB for `llama3.1:8b` and `mistral:7b` at every quantisation from `Q2_K` to `Q8_0`, 1.75 for `qwen3:14b`, 3.5 for `gemma3:12b` and 1.63 for `qwen3:4b` (smaller at `Q2_K`, where llmfit also shrinks the context it assumes). The cache of the assumed context is therefore already in the figure. A mixture-of-experts model is the exception (see [open questions](#open-questions)).
- **A tiny target gives the default quantisation.** With `--ram 1`, `llmfit info` returns `Q4_K_M` for all eight models tried (`qwen3:4b`, `llama3.2:3b`, `llama3.2:1b`, `llama3.1:8b`, `mistral:7b`, `gemma3:12b`, `qwen3:14b`, `qwen3:30b-a3b`), with `Too Tight` and its memory and disk (`llama3.1:8b`: 6.16 and 4.66 GB). Adding `--memory 1` gives the same figures.
- **`run_mode` follows the machine**, not the model: the same model is `CPU` with `--ram` alone and `GPU` with `--memory`.
- **`disk_size_gb` is reported** for the chosen quantisation (4.22 GB for the `Q8_0` above).
- **Ollama tags.** `llmfit info llama3.1:8b` is `model_not_found`, but `llmfit fit --json -n 100000` on a large target lists 141 models with an `ollama_name`, among them `llama3.1:8b`, `llama3.2:3b`, `mistral:7b`, `qwen3:8b`, `gemma3:4b`, `phi4` and `qwen2.5:7b`. That field gives the exact Hugging Face name to pass to `info`.
