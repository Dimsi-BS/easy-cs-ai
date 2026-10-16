# Spec: VM script generator

[← Back to docs](README.md)

**Status:** accepted (secrets handling still open, see [open questions](#open-questions)). What concerns several VMs (one script per VM, the `VM:` header line, the next steps, the per-VM `--json` documents) is **implemented** (`vm_script/generate.sh`, `tests/unit/generate_vm.bats`), see [spec: two VMs](spec-two-vm.md); one VM behaves as described.

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

- What the generator asks, and how a question is shown, belong to the [journey](spec-journey.md) and to the [rendering](spec-rendering.md#for-a-person-the-interactive-session); this section only fixes what is specific to the generator.
- Prompts and the summary go to stderr, answers are read from stdin. The result is written to the file given by `--output <path>` (default `./easy-cs-ai-vm.sh`, or `./easy-cs-ai.json` with `--config-only`), never to stdout. For a configuration that names several VMs there is one script per VM, named from `--output` with the VM inserted before the extension (see [spec: two VMs](spec-two-vm.md#what-is-written)).
- `--help`, `--version`, `--verbose` are accepted; `--dry-run` runs the whole session and prints the result to stderr without writing it.
- The generator needs no root and changes nothing on the machine, with one exception the administrator asks for: it can install llmfit on the spot, see [llmfit is optional](spec-model-fit.md#llmfit-is-optional). It never does so unasked.

### `--config <file>`

Takes the [configuration](spec-config.md) from a file instead of a session: **no prompt at all**. There is no separate "answers" format: it is the configuration, the one `apply` reads and `--config-only` writes. The file is validated first, with the same rules and the same exit code 2 as `apply`. It must be complete: the generator never asks the missing part, it reports it. The [package source](#package-source) comes from its own options, not from the file.

- It regenerates a script without answering again, for instance to move to a newer package version (a generated script is a snapshot, see [Generated script](#generated-script)).
- It makes a generation reproducible and testable: `bats` tests generate a script from a file and check it.
- A session can be done once by hand with `--config-only`, the file reviewed or edited, then turned into a script with `--config`.
- The summary is printed on stderr and **not** asked for confirmation.
- Incompatible with `--config-only` (it would only copy the file): exit 2.
- A file that names several VMs gives one script per VM (see [spec: two VMs](spec-two-vm.md)); each script embeds the slice of its VM, validated as a one-VM file. The summary is printed per VM, and the instructions that follow are the next steps computed by the validation ([spec: two VMs](spec-two-vm.md#next-steps)), which the generator only prints; it computes nothing of them.
- `--json` (only with `--config`, a session is interactive: exit 2) prints one JSON document on stdout instead of the human output: the validation document of `config validate --target fresh` extended with a `script` entry (`scripts` and `next_steps` for several VMs), see [spec: capabilities](spec-capabilities.md#commands) and [rendering](spec-rendering.md#for-a-program---json). An invalid file prints the document with its errors, `script: null` and exits 2.

## Implementation notes

- The session offers **one component per type** (per VM when the stack is split, see [spec: two VMs](spec-two-vm.md#in-the-session)): the configuration allows several, but there is no question for a second one; edit the file written by `--config-only` for that (see [journey](spec-journey.md#2-components-and-dependencies)). At the summary, `y` confirms, `n` cancels, and `c`, `o` or `m` redo the components (with their dependencies), the options or the models (`m` is not offered in the `web` pass of two VMs, which has no models step, see [spec: two VMs](spec-two-vm.md#in-the-session)).
- The generator plans for another machine: what is installed on the machine running it is ignored (`EASY_CS_AI_ASSUME_EMPTY`), so a configuration is validated as for a fresh VM, and a requirement that the file does not satisfy is an incomplete file (exit 2).
- The validation, the ordering of components and the summary are the code of `apply` (`lib/cli-apply.sh`), so the generator and `apply` cannot disagree.
- `--dry-run` also applies to `--config-only`: the configuration goes to stderr.
- The script is written with mode `0755` (it holds no secret), and a warning is logged when it exceeds 32 KB, the default user-data limit of CloudStack.
- **The generator holds no sizing logic**: it calls the actions of `provisioning llmfit` and shows the text they print, see [spec: model fit](spec-model-fit.md). A new rule is a change of the llmfit script, not of the generator.

## What the generator knows

Everything comes from the shipped scripts, nothing is hardcoded (same principle as the CLI [dispatch](spec-cli.md#dispatch)):

| Information | Source |
| --- | --- |
| Available components per type | `<libdir>/<type>/<name>.sh` |
| Options, defaults, which ones are secret | `describe.options` |
| Platforms | `describe.platforms` |
| Requirements and the order they impose | `describe.requires` |
| Ranking of alternatives, used to pre-select | [integration order](decision-integration-order.md), as shipped in `ranks.conf` |
| Models that fit a machine of given specs, when llmfit is installed on the machine running the generator | `provisioning llmfit suggest` and `check` with the `--target-*` options, see [model fit](spec-model-fit.md#model-fit-for-a-machine-that-is-not-this-one) |
| The VM that given models need | `provisioning llmfit plan`, see [Recommended VM](spec-model-fit.md#recommended-vm) |

The generator runs from the installed package (or tarball), so it knows the scripts of that version. The script it emits pins that same version.

## Session

The generator is the **interactive rendering of the [journey](spec-journey.md)**: it walks the same steps as a program does with arguments, and produces the same configuration. This spec does not define the questions; the journey does, and [spec: rendering](spec-rendering.md#for-a-person-the-interactive-session) says how they are asked. What belongs to the generator is what it does with the answers:

| Journey step | In the session |
| --- | --- |
| [1 Discover](spec-journey.md#1-discover), [2 Components](spec-journey.md#2-components-and-dependencies), [3 Options](spec-journey.md#3-options) | Questions of `lib/questions.sh`, from what [the generator knows](#what-the-generator-knows) |
| [4 Models](spec-journey.md#4-models) | The questions of [Choosing models in a session](spec-model-fit.md#choosing-models-in-a-session), the figures from the actions of [model fit](spec-model-fit.md) |
| [5 Validate, show, confirm](spec-journey.md#5-validate-show-confirm) | The code of `apply`, then the summary: components in install order, options (secrets masked), models, platforms, the recommended VM when computed, and the warnings |
| [6 Produce](spec-journey.md#6-produce) | The [package source](#package-source), then the [script](#generated-script) |

`--config-only` stops after the confirmation and writes the configuration file. With `--config`, steps 1 to 5 are replaced by the validation of the file. Otherwise the generator goes on to the package source, then emits the script.

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
3. the **configuration** (the slice of its VM when the file names several, see [spec: two VMs](spec-two-vm.md)), embedded as a quoted heredoc (`<<'EOF'`, so nothing is expanded; the delimiter is chosen so that it does not occur in the content), written to a temporary file readable by root only;
4. `easy-cs-ai apply` on that file, which is removed afterwards.

There is no list of `install` / `add` commands to generate: the orchestration, order, wiring and rollback are the CLI's (see [apply](spec-config.md#apply)). The package version is pinned, so the configuration always meets the CLI version it was generated for.

- **Size**: the script holds the configuration and a few lines of logic, never the package. It is meant to fit in the user-data limit of the target cloud.
- `set -euo pipefail`, stops at the first failing step and returns that step's exit code (the contract codes), prints the same `[LEVEL]` logs on stderr. Re-runnable: the download is skipped when the pinned version is already installed, and `apply` converges, so running it twice is safe.
- **Header**: a comment recording the generator version, the date (ISO 8601 UTC), the package version, the components with their versions and the non-secret options, so a script found on a VM can be traced back. When the file names VMs (even one), one more line gives the VM and its rank (`VM: engine (1 of 2)`, `VM: a (1 of 1)`).
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
- `bats` tests of the models step with a fake llmfit: specs asked and forwarded as `--target-*`, suggestions picked by number and by name, a negative `check` kept as a warning in the summary, specs offered again as defaults when the step is redone, llmfit absent (the offer, declined by default and asked once, the message with the install command, free text, exit 0), accepted (installed, then the specs and the suggestions), failing to install (a warning, free text), and a package without llmfit (nothing offered).
- `bats` tests of the stack without llmfit: models written with `"force": true` and the summary warning; no models, no warning; `--config` with a model and `force` and no llmfit gets the warning, and without `force` it does not.
- Integration test: generate a script, run it on a fresh VM, `status` healthy, run it a second time, nothing changes.
- Several VMs: the tests of [spec: two VMs](spec-two-vm.md#definition-of-done).
- `shellcheck` clean on the generator; `--help` text consistent with this spec.

## Open questions

- **Secrets**: how the generated script gets its secrets (API key, admin passwords). The configuration describes a secret by its source, never by value ([Secrets](spec-config.md#secrets)); what is open is whether a literal is allowed in the file at all, and the mode of the generated file (`0600` if it ever holds one). Until decided, a secret option is asked as "generated at run time" and never written. Linked to the CloudStack user-data caveat in the [contract](spec-script-contract.md#secrets), see also [spec: config](spec-config.md#open-questions).
- **Several VMs**: one script per VM of a configuration that names its VMs (the `vm` field of [spec: config](spec-config.md#several-vms)), the question that fills it, and the instructions printed at the end, are specified in [spec: two VMs](spec-two-vm.md). The one-VM behaviour described here does not change.
- **Package hosting**: where the packages live and how the checksum is published (see [decision: VM script generator](decision-vm-generator.md#open-questions)).
- **User-data limit**: the exact limit of the target CloudStack instance, and the typical size of the generated script, to measure once the generator exists.
