# Spec: VM script generator

[← Back to docs](README.md)

**Status:** accepted (secrets handling still open, see [open questions](#open-questions))

## Purpose

The generator produces a **parameterless VM post-install script** (layer 3) with a fixed configuration, guiding an administrator through the required choices. Why it exists, and why there is none for layer 1, is in [decision: VM script generator](decision-vm-generator.md). This spec fixes how it asks, what it reads and what it emits.

It builds on the [script contract](spec-script-contract.md) (`describe`, `requires`, options), the [CLI spec](spec-cli.md) and the [configuration file](spec-config.md); it does not repeat them.

The common thread: **a session produces a configuration** (the format of [spec: config](spec-config.md)), and the generator turns it into the VM script. The same file is what `--config <file>` reads back, to generate without a session.

## Layout

```text
vm_script/
  lib/questions.sh        question engine (prompts, validation, summary) → configuration
  generate.sh             layer 3 generator, also runs the session for `--config-only`
```

It is reached through `easy-cs-ai generate` (see [CLI](spec-cli.md#generate)), which hands over with the remaining arguments and forward streams and exit code. They are bash, like everything else (see [scripting language](decision-scripting-language.md)).

`generate --config-only` runs the session only and writes the configuration file, for an administrator who wants to keep it, review it or feed it to `apply` directly.

## Interaction

- The generator is the **only interactive program** of the project. Prompts and the summary go to stderr, answers are read from stdin. The result is written to the file given by `--output <path>` (default `./easy-cs-ai-vm.sh`, or `./easy-cs-ai.json` with `--config-only`), never to stdout.
- Every question shows its default (the script's own default from `describe`), what it means (the `description` of `describe`) and is validated before moving on. Invalid input asks again, it never aborts the session.
- Nothing is chosen silently: a component is part of the output only if the administrator picked it, or accepted a dependency the generator proposed.
- `--help`, `--version`, `--verbose` are accepted; `--dry-run` runs the whole session and prints the result to stderr without writing it.
- The generator needs no root and changes nothing on the machine. In particular it never installs llmfit: see [llmfit is optional](#llmfit-is-optional).

### `--config <file>`

Takes the [configuration](spec-config.md) from a file instead of a session: **no prompt at all**. There is no separate "answers" format: it is the configuration, the one `apply` reads and `--config-only` writes. The file is validated first, with the same rules and the same exit code 2 as `apply`. It must be complete: the generator never asks the missing part, it reports it. The [package source](#package-source) comes from its own options, not from the file.

- It regenerates a script without answering again, for instance to move to a newer package version (a generated script is a snapshot, see [Generated script](#generated-script)).
- It makes a generation reproducible and testable: `bats` tests generate a script from a file and check it.
- A session can be done once by hand with `--config-only`, the file reviewed or edited, then turned into a script with `--config`.
- The summary is printed on stderr and **not** asked for confirmation.
- Incompatible with `--config-only` (it would only copy the file): exit 2.
- `--json` (only with `--config`, a session is interactive: exit 2) prints one JSON document on stdout instead of the human output: the validation document of `config validate --target fresh` extended with a `script` entry, see [spec: machine interface](spec-ai-interface.md#commands). An invalid file prints the document with its errors, `script: null` and exits 2.

## Implementation notes

- The session picks **one component per type** (the configuration allows several, but there is no question to ask for a second one; edit the file written by `--config-only` for that). The rank 1 is offered as the default answer, `none` skips the type; a type with no shipped component is not asked.
- A dependency the administrator refuses sends the session back to the component choice. At the summary, `y` confirms, `n` cancels, and `c`, `o` or `m` redo the components (with their dependencies), the options or the models. The dependency check is not a choice of its own: it always follows the components.
- End of input on stdin cancels the session: exit 0, nothing written.
- The generator plans for another machine: what is installed on the machine running it is ignored (`EASY_CS_AI_ASSUME_EMPTY`), so a configuration is validated as for a fresh VM, and a requirement that the file does not satisfy is an incomplete file (exit 2).
- The validation, the ordering of components and the summary are the code of `apply` (`lib/cli-apply.sh`), so the generator and `apply` cannot disagree.
- `--dry-run` also applies to `--config-only`: the configuration goes to stderr.
- The script is written with mode `0755` (it holds no secret), and a warning is logged when it exceeds 32 KB, the default user-data limit of CloudStack.

## What the generator knows

Everything comes from the shipped scripts, nothing is hardcoded (same principle as the CLI [dispatch](spec-cli.md#dispatch)):

| Information | Source |
| --- | --- |
| Available components per type | `<libdir>/<type>/<name>.sh` |
| Options, defaults, which ones are secret | `describe.options` |
| Platforms | `describe.platforms` |
| Requirements and the order they impose | `describe.requires` |
| Ranking of alternatives, used to pre-select | [integration order](decision-integration-order.md), as shipped in `ranks.conf` |
| Models that fit a machine of given specs, when llmfit is installed on the machine running the generator | `provisioning llmfit recommend` and `check` with the `--target-*` options, see [model fit](spec-ai-interface.md#model-fit-for-a-machine-that-is-not-this-one) |

The generator runs from the installed package (or tarball), so it knows the scripts of that version. The script it emits pins that same version.

## Session

It produces a configuration.

1. **Components**: for each type, list the components shipped, with the rank 1 pre-selected, and let the administrator pick (one engine, one chat interface…, or none).
2. **Dependencies**: from `requires`, propose the missing components (a type means "any of this type"), and refuse a selection that cannot be satisfied. The administrator confirms or changes them; the generator never adds a component unannounced.
3. **Options**: for each selected component, ask its `describe.options`, in the order of the script. Options left at their default are not written to the configuration. Secret options are asked as a source, see [Secrets](spec-config.md#secrets).
4. **Models** (when an engine is selected): ask which models to add, and on which engine and chat interface when there is a choice. With llmfit available on the machine running the generator, the administrator chooses the **order**: the models that fit given hardware, or the hardware that suits given models, see [Choosing models](#choosing-models) and [Recommended VM](#recommended-vm); without it, the administrator types the names. The fit is still checked at run time, on the target, when the stack holds llmfit (see [llmfit is optional](#llmfit-is-optional)).
5. **Summary**: components in install order, options (secrets masked), models, target platforms, the **recommended VM** when it was computed, and the **warnings** of the options whose effective value matches their `warn` entry in `describe` (a default included), so a risk such as an open registration is read before the VM is created (see [`describe`](spec-script-contract.md#describe)). The administrator confirms, goes back to a step, or cancels.

`--config-only` stops here and writes the file. With `--config`, steps 1 to 5 are replaced by the validation of the file. Otherwise the generator goes on to the package source, then emits the script.

### Choosing models

A model name is engine-specific and nothing tells the administrator whether it fits the VM. When llmfit is available (see below), step 4 asks first **in which order to work**, because an administrator either has a VM imposed or has a model in mind:

| Choice | Meaning |
| --- | --- |
| `h` (hardware first, default) | The administrator gives the specs of the VM, the generator suggests the models that fit them (below) |
| `m` (models first) | The administrator names the models, the generator computes the VM they need, see [Recommended VM](#recommended-vm) |

The two are not exclusive: with `m`, the administrator may still enter specs, which the recommendation is then compared with. The choice is offered again as the default when the step is redone. In the `h` order, the step asks for the **specs of the target VM**, each answer optional (empty means "do not size on it"):

| Question | Forwarded as |
| --- | --- |
| RAM of the VM, in GB | `--target-ram` |
| GPU memory of the VM, in GB (empty for a CPU-only VM) | `--target-vram` |
| CPU cores of the VM | `--target-cpu-cores` |

Then:

1. With at least one spec, it lists what `provisioning llmfit recommend` suggests for them, numbered: the ten best by score, only the models that carry an Ollama tag (the only names an engine can pull today, so the list is offered for `ollama` only) and none that llmfit judges `Too Tight`. The administrator picks by number, by name, or types another name; an empty answer adds no model. With **no** spec at all, there is no list and no check, because llmfit would size for the machine running the generator, not for the VM; the session says so.
2. Each model typed that is not in the list is submitted to `provisioning llmfit check <model>` with the same specs. A negative verdict, or a model llmfit does not know (it knows Hugging Face names and the Ollama tags of the models that fit), is a **warning**, repeated in the summary with llmfit's reason: the administrator knows their VM, the generator never refuses a model on that opinion.
3. The specs are asked again only when the step is redone (`m` at the summary offers the previous answers as defaults; `none` clears one). An answer that is not a positive whole number is asked again.

The specs and the verdicts are **not** stored in the configuration: it stays valid for any VM and the fit is checked on the target at run time (see [model fit](spec-ai-interface.md#model-fit-for-a-machine-that-is-not-this-one)). They are an early opinion, nothing more.

### Recommended VM

In the `m` order, once the models are named, the generator tells the administrator **what to ask for when creating the VM**, from what llmfit reports for each model (`memory_required_gb`, `run_mode`, see [findings](../search/llmfit.md)). It recommends characteristics, it provisions nothing and produces no VM template or image:

| Item | Derived from |
| --- | --- |
| Model memory | The largest `memory_required_gb` among the models, assuming they are not loaded at the same time. It already includes the context llmfit assumes (see [checked](#sizing-checked-with-llmfit)) |
| GPU or CPU only | **Not** derived: `run_mode` only reflects the machine llmfit was told about. Both are shown, RAM for a CPU-only VM (with the estimated tokens per second, `estimated_tps`) and GPU memory for a VM with a GPU, and the administrator picks |
| Margin | **Estimated**, added on top of the model memory, see [Estimated margin](#estimated-margin) |
| Disk | The `disk_size_gb` of the models plus that of the system and components |
| vCPU | An indication only |

Each memory figure is given **twice**, for two quantisations, because the one an engine actually loads depends on the engine and on the model: the **best** one llmfit finds for a large target (usually `Q8_0`), and the **default** one of the model, which llmfit reports for a target too small for anything (`Q4_K_M` for every model checked). The generator does not say which one the engine will use, it shows the two and the administrator decides: the default one is enough when the engine loads the usual 4-bit model, the best one covers an engine that loads more precise weights. The default figure comes from `llmfit info` asked for a **tiny target** (`--ram 1`): llmfit then falls back to that quantisation and its verdict is `Too Tight`, which the generator ignores here. It relies on that fallback, so the tests must catch a change of behaviour of llmfit (see [Definition of done](#definition-of-done)).

The figures are taken so that they do not depend on the machine the generator runs on: llmfit is asked for a **very large target** (`--ram`, and `--memory` for the GPU figure), so that it reports the memory of its best quantisation, and the context is the one llmfit assumes (8192 tokens, shown in the recommendation). A model name is the engine's own: a Hugging Face name (what vLLM takes) is already what `llmfit info` needs, and an Ollama tag is turned into one through the `ollama_name` field of `llmfit fit --json -n 100000`, asked for the same large target. A name that llmfit cannot resolve is `not estimated`. Nothing in the recommendation is specific to an engine: another engine only needs its own way to name a model.

#### Estimated margin

llmfit's figure covers the weights and the cache of its assumed context, not what runs around the model. The generator therefore **adds a margin and says so**: every recommendation is displayed as `<model memory> + <margin> (estimated margin)`, with the breakdown of the margin, never as a single total that looks measured. The margin is a planning estimate, not a measurement:

| Part | Estimate | Basis |
| --- | --- | --- |
| GPU memory | model memory ÷ 0.9, plus 1 GB | An engine such as vLLM uses 90 % of the GPU memory by default (0.9, 0.9 to 0.95 deemed safe) and the CUDA context, graphs and buffers come on top (about 0.8 GB measured by one source, 0.5 to 1 GB for the llama.cpp backends) |
| RAM, VM without GPU | model memory, plus 1 GB for the engine process, 1 GB for the system | Canonical gives 1 GB as the minimum of an Ubuntu 24.04 cloud image, and one measurement 0.3 GB idle |
| RAM, VM with a GPU | 2 GB for the system and the engine, nothing for the model | The weights live in GPU memory |
| Chat interface and its databases | 4 GB when a chat interface is in the stack, 0 otherwise | LibreChat 1 to 2 GB, MongoDB about 1 GB with its cache capped, Meilisearch 0.5 to 1 GB, and about 0.5 GB per worker for the embeddings of a RAG interface: 4 to 8 GB for a full stack in one estimate |
| Rounding | Up to the next whole GB | |

These values come from vendor documentation for some (Ubuntu, MongoDB, Meilisearch, vLLM) and from blogs and forums for the rest (Ollama, LibreChat), none of which measures this project's stack. They are a starting point to calibrate with `docker stats` and `free` on a real VM, see [open questions](#open-questions). The margin is a constant of the generator, not a result of llmfit, and is the same whatever the engine.

It is shown at the end of the step and repeated in the summary, with the equivalent for a CloudStack **compute offering** (vCPU, RAM, GPU) and a disk size, so that it can be typed in as is. A model for which llmfit has no figure (see [open questions](#open-questions)) is listed as `not estimated` and the recommendation says it does not cover it: a value is never invented.

Like the verdicts, the recommendation is **not** stored in the configuration and is only an early opinion; the fit is still checked on the target.

### llmfit is optional

llmfit has two roles around the generator, and neither is mandatory.

- **On the machine running the generator** (the administrator's own): it only feeds [Choosing models](#choosing-models). It is available when `provisioning llmfit status` reports it installed and healthy, whatever the stack chosen for the VM. If it is not, the step says so once, with the command that installs it (`sudo easy-cs-ai install provisioning llmfit`), then asks for the model names as free text. It never installs it itself (it changes nothing on the machine) and never fails because of it. `--config` and `--config-only` with a complete file do not need it either.
- **On the VM** (the `provisioning llmfit` component of the stack): it checks, at run time, that each model fits. It is a component like the others in step 1: offered with its rank, and the administrator may answer `none`. The prompt says what declining costs. When the session ends with models and **no** llmfit in the stack, the generator writes every model with `"force": true` (the fit check is skipped, as `add --force` does, so `apply` does not stop on the missing requirement) and the summary carries a warning: `models not checked for fit on the VM: llmfit is not part of the stack`. Declining llmfit is therefore a supported, explicit choice, never a late failure of the generated script.

The warning comes from the configuration (a model with `force` and no provisioning component), so a `--config` file gets it too. The generator adds `force` only in the session, where the administrator has been told; a file is never changed. Note that the validation does not check, today, that a model without `force` has an llmfit to be checked by: `apply` finds out at the model step (exit 4, after the components are installed, see [`add`](spec-cli.md#add)). Making the validation report it beforehand is not part of this change.

### Package source

Not asked with `--config-only` (and given as options with `--config`):

| Item | Meaning | Default |
| --- | --- | --- |
| `--package-url` | Where the VM downloads the package or tarball. A mirror URL for a restricted network | The GitHub Releases URL of the version below |
| `--package-version` | Version to install, **pinned** | The version of the installed CLI |
| `--package-format` | `deb`, `rpm` or `tarball` | `deb` (primary target, see [packaging](decision-packaging.md)) |
| `--package-sha256` | Checksum the script verifies | Else computed from `--package-file <path>` (a local copy of the package), else read from `<package-url>.sha256` (first field of its first line), which a release publishes next to each package. Neither available: exit 5 |

The generator never emits a script without a checksum.

The default URL is `https://github.com/Dimsi-BS/easy-cs-ai/releases/download/v<version>/<file>`, with `<file>` being `easy-cs-ai_<version>_all.deb`, `easy-cs-ai-<version>-1.noarch.rpm` or `easy-cs-ai-<version>.tar.gz`. The tarball unpacks to the tree `bin/easy-cs-ai`, `lib/easy-cs-ai/…` (the layout the CLI finds relative to itself); the generated script unpacks it in `/opt/easy-cs-ai`, links `/usr/local/bin/easy-cs-ai` to it and installs `jq` when missing. When the CLI hands over to the generator it passes its own version as the default `--package-version` (a generator run on its own needs the option).

## Generated script

One file, small, self-contained apart from the package it downloads:

1. **header** (see below);
2. **download** the package from the pinned URL, verify the sha256 (mismatch → exit 5, nothing installed), install it (`apt-get install` of the local file, `dnf`, or unpack the tarball);
3. the **configuration**, embedded as a quoted heredoc (`<<'EOF'`, so nothing is expanded; the delimiter is chosen so that it does not occur in the content), written to a temporary file readable by root only;
4. `easy-cs-ai apply` on that file, which is removed afterwards.

There is no list of `install` / `add` commands to generate: the orchestration, order, wiring and rollback are the CLI's (see [apply](spec-config.md#apply)). The package version is pinned, so the configuration always meets the CLI version it was generated for.

- **Size**: the script holds the configuration and a few lines of logic, never the package. It is meant to fit in the user-data limit of the target cloud.
- `set -euo pipefail`, stops at the first failing step and returns that step's exit code (the contract codes), prints the same `[LEVEL]` logs on stderr. Re-runnable: the download is skipped when the pinned version is already installed, and `apply` converges, so running it twice is safe.
- **Header**: a comment recording the generator version, the date (ISO 8601 UTC), the package version, the components with their versions and the non-secret options, so a script found on a VM can be traced back.
- It is a **snapshot**: it pins one package version, regenerate to upgrade.

## Exit codes

The [contract codes](spec-script-contract.md#exit-codes) with the same meaning:

| Code | Meaning in the generator |
| --- | --- |
| 0 | Output written (or dry run done), or the administrator cancelled |
| 1 | Unexpected error, output file not writable |
| 2 | Usage error: bad option, unknown component, invalid or incomplete `--config` file, `--config` with `--config-only` |
| 4 | Precondition not met: no component shipped, selection impossible to satisfy |
| 5 | The package checksum could not be fetched or computed |

## Definition of done

- `bats` tests feeding answers on stdin: component selection, dependency proposal, validation loop, cancel, back-navigation, `--dry-run`, the configuration written.
- `bats` tests with `--config`: valid file, each validation error, incomplete file, a file written by `--config-only` turned into the same script as the interactive session.
- The generated script checked with `shellcheck`; its embedded configuration extracted and compared with the input (heredoc intact, nothing expanded); run against a fake package source in `EASY_CS_AI_ROOT` mode: checksum mismatch, already-installed version, failure of `apply`; size within the limit for a typical configuration.
- `bats` tests of the models step with a fake llmfit: specs asked and forwarded as `--target-*`, suggestions picked by number and by name, a negative `check` kept as a warning in the summary, specs offered again as defaults when the step is redone, llmfit absent (one message with the install command, free text, exit 0), and the generator never installing it.
- `bats` tests of the stack without llmfit: models written with `"force": true` and the summary warning; no models, no warning; `--config` with a model and `force` and no llmfit gets the warning, and without `force` it does not.
- `bats` tests of the order of the models step with a fake llmfit: `h` as the default, `m` computing the recommended VM from the models (memory for the two quantisations, GPU or CPU, disk, CloudStack equivalent), the margin shown apart and labelled `estimated margin` with its breakdown, no chat interface in the stack giving no chat part, a Hugging Face name and an Ollama tag both resolved, a model without a figure listed as `not estimated`, the recommendation repeated in the summary and absent from the configuration, the order offered again as the default when the step is redone.
- A test of the default-quantisation fallback against the real llmfit when it is installed (skipped otherwise): `info` with `--ram 1` reports a quantisation and a memory for a few models, so that a change of behaviour of llmfit is caught at its upgrade.
- Integration test: generate a script, run it on a fresh VM, `status` healthy, run it a second time, nothing changes.
- `shellcheck` clean on the generator; `--help` text consistent with this spec.

## Open questions

- **Secrets**: how the generated script gets its secrets (API key, admin passwords). The configuration describes a secret by its source, never by value ([Secrets](spec-config.md#secrets)); what is open is whether a literal is allowed in the file at all, and the mode of the generated file (`0600` if it ever holds one). Until decided, a secret option is asked as "generated at run time" and never written. Linked to the CloudStack user-data caveat in the [contract](spec-script-contract.md#secrets), see also [spec: config](spec-config.md#open-questions).
- **Package hosting**: where the packages live and how the checksum is published (see [decision: VM script generator](decision-vm-generator.md#open-questions)).
- **Sizing from a model**: [checked with llmfit 1.1.17](#sizing-checked-with-llmfit). What stays open is **calibrating the [estimated margin](#estimated-margin)**: measuring the real consumption of the stack (engine, chat interface, databases) on a fresh VM, and whether an engine should declare its own overhead in its `describe` instead of the generator's constant. What also stays open is that the default-quantisation figure relies on a **fallback of llmfit** (a tiny target gives the model default), not on a documented option: to watch at each llmfit upgrade, and to replace by an option if llmfit gains one. A **mixture-of-experts** model (`is_moe`) does not follow the rule below: its memory does not move with the quantisation (17.1 GB from `Q2_K` to `Q8_0` for `Qwen3-30B-A3B`), its disk size is larger than its memory, and the figure differs between a CPU and a GPU target (17.1 and 15.6 GB). For those the recommendation shows the figure as reported and flags it as less reliable.
- **User-data limit**: the exact limit of the target CloudStack instance, and the typical size of the generated script, to measure once the generator exists.

### Sizing checked with llmfit

Measured with llmfit 1.1.17 (Linux release, in WSL), to settle the first question above:

- **The requirement depends on the machine.** llmfit reports the memory of the best quantisation that fits the machine it is told about. `Qwen/Qwen3-4B-Instruct-2507` gives 3.11 GB (`Q2_K`) at `--ram 4`, 4.84 GB (`Q6_K`) at 6, then 5.85 GB (`Q8_0`) from 8 GB up, unchanged at 16 and 64. Sizing for a large target therefore gives a stable figure.
- **The context counts.** `--max-context` 2048, 8192 (the assumed default) and 32768 give 5.0, 5.85 and 9.22 GB for the same model.
- **The memory is the weights plus a constant per model**, over six models: `memory_required_gb − disk_size_gb` is 1.5 GB for `llama3.1:8b` and `mistral:7b` at every quantisation from `Q2_K` to `Q8_0`, 1.75 for `qwen3:14b`, 3.5 for `gemma3:12b` and 1.63 for `qwen3:4b` (smaller at `Q2_K`, where llmfit also shrinks the context it assumes). The cache of the assumed context is therefore already in the figure. A mixture-of-experts model is the exception (see [open questions](#open-questions)).
- **A tiny target gives the default quantisation.** With `--ram 1`, `llmfit info` returns `Q4_K_M` for all eight models tried (`qwen3:4b`, `llama3.2:3b`, `llama3.2:1b`, `llama3.1:8b`, `mistral:7b`, `gemma3:12b`, `qwen3:14b`, `qwen3:30b-a3b`), with `Too Tight` and its memory and disk (`llama3.1:8b`: 6.16 and 4.66 GB). Adding `--memory 1` gives the same figures.
- **`run_mode` follows the machine**, not the model: the same model is `CPU` with `--ram` alone and `GPU` with `--memory`.
- **`disk_size_gb` is reported** for the chosen quantisation (4.22 GB for the `Q8_0` above).
- **Ollama tags.** `llmfit info llama3.1:8b` is `model_not_found`, but `llmfit fit --json -n 100000` on a large target lists 141 models with an `ollama_name`, among them `llama3.1:8b`, `llama3.2:3b`, `mistral:7b`, `qwen3:8b`, `gemma3:4b`, `phi4` and `qwen2.5:7b`. That field gives the exact Hugging Face name to pass to `info`.
