# Decision: VM script generator

[← Back to docs](README.md)

**Status:** accepted (secrets handling still open, see [open questions](#open-questions))

## Context

Each layer 1 install script does one thing: install and configure one component (Ollama, nginx, LibreChat…), see the [script contract](spec-script-contract.md). A real deployment chains several of them, each with its own parameters, and the same deployment is often replayed on many VMs.

Two questions were asked: is a generator worth having, since one command can already do each step, and at which layer.

## Decision

- **One interactive generator, for layer 3**: `generate` produces a small parameterless VM post-install script (one per VM when the configuration names several VMs, see [spec: two VMs](spec-two-vm.md)). It downloads the package/CLI from a pinned source, embeds a configuration and runs `easy-cs-ai apply` on it.
- **`generate --config-only`** runs the same session and writes only the configuration file ([spec: config](spec-config.md)). That file is also what `generate --config <file>` takes in place of the session, which makes a generation reproducible and testable without prompts.
- **No generator for layer 1.** It was planned for the case where layer 2 turned out too hard to build. With `apply`, the CLI chains the components, orders them from `requires` and fixes their parameters from the configuration, so a layer 1 generated script would only duplicate it. Layer 1 scripts stay usable on their own, with their own options.
- **The package is downloaded, not embedded.** The script carries the URL, the version and the sha256 of the package, and verifies it before installing. The source is configurable, so a restricted network points at an internal mirror.

The behaviour is specified in [spec: VM script generator](spec-vm-generator.md).

## Why

- **A generated script is a chain, not a single command.** The components are separate scripts. A deployment such as Ollama, then the reverse proxy with HTTPS and API key, then LibreChat, is several steps with their own parameters.
- **The output is a ready-to-replay artefact.** Parameters are fixed in the embedded configuration, so the script can be handed as-is to cloud-init, user-data or a VM template and run on N machines.
- **The choices depend on each other.** The engine decides what the chat interface must point to, HTTPS requires a domain and an API key, and the hardware (GPU or not) restricts the engine. A guided flow prevents invalid combinations and forgotten steps, which a command line cannot do.
- **The cost is low.** Scripts already expose their options through `describe`, so the generator adds no per-component knowledge.
- **Embedding the package does not fit the target.** VM scripts are mostly passed as user-data, which is size-limited (to be checked on the CloudStack instance: the default is, to our knowledge, 32 KB, `vm.userdata.max.length`; other clouds are in the same range). An archive of the CLI, the scripts and the templates, in base64, would likely exceed it, whereas a configuration is small.
- **Downloading is not weaker once pinned.** The sha256 in the script gives the same integrity as embedding. The mirror covers restricted networks without growing the script.

## Consequences

- The generator is the **only interactive part** of the project. The scripts and the CLI keep their rule of never prompting, which is what makes the generated script usable unattended.
- The generator never hardcodes a component or an option: it reads the shipped scripts and their `describe`. A new component needs no generator change.
- A generated script is a snapshot: it pins a package version and embeds a configuration, regenerate it to upgrade.
- The VM needs network access to the package source at run time. Where the package is hosted is open (see below).
- The layer 1 scripts no longer have to be inlinable by a generator, which relaxes the [script contract](spec-script-contract.md#layout): they must work standalone, and only need `lib/common.sh`.
- A fully offline script (package embedded) is not planned. It would be added if a real need appears, for example a script copied by hand to an isolated machine.

## Alternatives considered

| Option | Why not |
| --- | --- |
| No generator, document the command sequence | Every administrator rewrites the chain by hand and the invalid combinations are found at install time |
| A generator for layer 1 scripts | Duplicates what `apply` does, and constrains the scripts to be inlinable |
| Embed the whole package in the generated script | Too large for user-data, only useful for isolated machines |
| Non-interactive generator only | Hides the choices the administrator has to make, the interactive guidance is the point |

## Open questions

- **Secrets in a generated script** (API key, admin passwords): the configuration describes a secret by its source (file, environment variable, generated at run time), never by value. Whether a literal in the file is allowed at all is not decided, see [spec: config](spec-config.md#open-questions) and [spec: VM script generator](spec-vm-generator.md#open-questions). This ties in with the [secrets rules](spec-script-contract.md#secrets) of the contract and the CloudStack user-data caveat noted there.
- **Where the packages are hosted**: GitHub Releases at first, an `apt`/`dnf` repository later (see [packaging](decision-packaging.md#consequences)). The generated script depends on it, and a mirror URL must stay possible.
