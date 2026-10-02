# Spec: VM script generator

[← Back to docs](README.md)

**Status:** draft (see [open questions](#open-questions))

## Purpose

The generator produces a **parameterless VM post-install script** (layer 3) with a fixed configuration, guiding an administrator through the required choices. Why it exists, and why there is none for layer 1, is in [decision: VM script generator](decision-vm-generator.md). This spec fixes how it asks, what it reads and what it emits.

It builds on the [script contract](spec-script-contract.md) (`describe`, `requires`, options), the [CLI spec](spec-cli.md) and the [configuration file](spec-config.md); it does not repeat them.

The common thread: **a session produces a configuration** (the format of [spec: config](spec-config.md)), and the generator turns it into the VM script. The same file is what `--answers-file` reads back.

## Layout

```text
vm_script/
  lib/questions.sh        question engine (prompts, validation, summary) → configuration
  generate.sh             layer 3 generator, also runs the session for `--config-only`
```

It is reached through `easy-cs-ai generate` (see [CLI](spec-cli.md#generate)), which hands over with the remaining arguments and forward streams and exit code. They are bash, like everything else (see [scripting language](decision-scripting-language.md)).

`generate --config-only` runs the session only and writes the configuration file, for an administrator who wants to keep it, review it or feed it to `apply` directly.

## Interaction

- The generator is the **only interactive program** of the project. Prompts and the summary go to stderr, answers are read from stdin. The result is written to the file given by `--output <path>` (default `./easy-cs-ai-vm.sh`, or `./easy-cs-ai.json` for `config`), never to stdout.
- Every question shows its default (the script's own default from `describe`), what it means (the `description` of `describe`) and is validated before moving on. Invalid input asks again, it never aborts the session.
- Nothing is chosen silently: a component is part of the output only if the administrator picked it, or accepted a dependency the generator proposed.
- `--help`, `--version`, `--verbose` are accepted; `--dry-run` runs the whole session and prints the result to stderr without writing it.
- The generator needs no root and changes nothing on the machine.

### `--answers-file <file>`

Replays a session **without any prompt**. The file is a [configuration](spec-config.md) and is validated first, with the same rules and the same exit code 2 as `apply`. It must be complete: the generator never asks the missing part, it reports it. The [package source](#package-source) comes from the options below, not from the file.

- It makes a generation reproducible and testable: `bats` tests generate a script from a file and check it.
- A file written by an interactive session (or by `generate --config-only`) is a valid answers file, so a session can be done once by hand, then replayed.
- With `--answers-file`, the summary is printed on stderr and **not** asked for confirmation.

## What the generator knows

Everything comes from the shipped scripts, nothing is hardcoded (same principle as the CLI [dispatch](spec-cli.md#dispatch)):

| Information | Source |
| --- | --- |
| Available components per type | `<libdir>/<type>/<name>.sh` |
| Options, defaults, which ones are secret | `describe.options` |
| Platforms | `describe.platforms` |
| Requirements and the order they impose | `describe.requires` |
| Ranking of alternatives, used to pre-select | [integration order](decision-integration-order.md) |

The generator runs from the installed package (or tarball), so it knows the scripts of that version. The script it emits pins that same version.

## Session

It produces a configuration.

1. **Components**: for each type, list the components shipped, with the rank 1 pre-selected, and let the administrator pick (one engine, one chat interface…, or none).
2. **Dependencies**: from `requires`, propose the missing components (a type means "any of this type"), and refuse a selection that cannot be satisfied. The administrator confirms or changes them; the generator never adds a component unannounced.
3. **Options**: for each selected component, ask its `describe.options`, in the order of the script. Options left at their default are not written to the configuration. Secret options are asked as a source, see [Secrets](spec-config.md#secrets).
4. **Models** (when an engine is selected): ask which models to add, and on which engine and chat interface when there is a choice. Whether a model fits the machine is checked at run time, on the target, not at generation time.
5. **Summary**: components in install order, options (secrets masked), models, target platforms. The administrator confirms, goes back to a step, or cancels.

`--config-only` stops here and writes the file. Otherwise the generator goes on to the package source, then emits the script.

### Package source

Not asked with `--config-only` (and given as options with `--answers-file`):

| Item | Meaning | Default |
| --- | --- | --- |
| `--package-url` | Where the VM downloads the package or tarball. A mirror URL for a restricted network | The GitHub Releases URL of the version below |
| `--package-version` | Version to install, **pinned** | The version of the installed CLI |
| `--package-format` | `deb`, `rpm` or `tarball` | `deb` (primary target, see [packaging](decision-packaging.md)) |
| `--package-sha256` | Checksum the script verifies | Fetched from the release by the generator, or computed from a local file |

The generator never emits a script without a checksum.

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
| 2 | Usage error: bad option, unknown component, invalid or incomplete `--answers-file` |
| 4 | Precondition not met: no component shipped, selection impossible to satisfy |
| 5 | The package checksum could not be fetched or computed |

## Definition of done

- `bats` tests feeding answers on stdin: component selection, dependency proposal, validation loop, cancel, back-navigation, `--dry-run`, the configuration written.
- `bats` tests with `--answers-file`: valid file, each validation error, incomplete file, a file written by a session replayed to the same output.
- The generated script checked with `shellcheck`; its embedded configuration extracted and compared with the input (heredoc intact, nothing expanded); run against a fake package source in `EASY_CS_AI_ROOT` mode: checksum mismatch, already-installed version, failure of `apply`; size within the limit for a typical configuration.
- Integration test: generate a script, run it on a fresh VM, `status` healthy, run it a second time, nothing changes.
- `shellcheck` clean on the generator; `--help` text consistent with this spec.

## Open questions

- **Secrets**: how the generated script gets its secrets (API key, admin passwords). The configuration describes a secret by its source, never by value ([Secrets](spec-config.md#secrets)); what is open is whether a literal is allowed in the file at all, and the mode of the generated file (`0600` if it ever holds one). Until decided, a secret option is asked as "generated at run time" and never written. Linked to the CloudStack user-data caveat in the [contract](spec-script-contract.md#secrets), see also [spec: config](spec-config.md#open-questions).
- **Package hosting**: where the packages live and how the checksum is published (see [decision: VM script generator](decision-vm-generator.md#open-questions)).
- **User-data limit**: the exact limit of the target CloudStack instance, and the typical size of the generated script, to measure once the generator exists.
