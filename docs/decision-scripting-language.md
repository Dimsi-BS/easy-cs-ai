# Decision: scripting language

[← Back to docs](README.md)

**Status:** accepted

## Context

The project provisions AI components (inference engines, reverse proxy, chat interface) on Linux servers and VMs, through install scripts, a CLI and generators. The VMs are sized as tightly as possible to save money, so the tooling must stay light and must not require a heavy runtime. Ubuntu/Debian is the primary target, but wider Linux support is desirable.

## Decision

- **Bash** for the install scripts, the CLI dispatcher, the generators and the VM post-install scripts.
- **`jq`** for JSON (e.g. the output of `llmfit`), and **`yq`** only if a structured YAML file must be edited in place.
- No "full" programming language for now.

Conventions:

- Bash ≥ 4, `set -euo pipefail`, shared helpers in a common library sourced by the scripts.
- Idempotent scripts: running one twice must not break an existing install.
- `shellcheck` in CI, `bats-core` for unit tests, integration tests in fresh containers or VMs (see [tests](../tests/README.md)).
- No secret (API key…) passed as a command-line argument; restrictive file permissions on generated configuration.
- Prefer generating whole files from templates (`envsubst`) or drop-in files (`conf.d/*.conf`, systemd drop-ins) over editing existing files in place. This avoids most of the need for `yq`.
- Local state in plain files under `/var/lib/easy-cs-ai/`, readable with `source` or `jq`.

Runtime prerequisites: `bash`, `curl`, `jq` (and `yq` if needed), installed by the bootstrap step when missing.

## Why

- Bash is present on virtually every Linux distribution, including minimal VM and cloud-init images, and adds nothing to the VM footprint.
- The work is mostly calling `apt`, `curl`, `systemctl` and writing configuration files, which is the natural territory of the shell.
- `status`, `install` and `add` (see [CLI commands](cli-commands.md)) boil down to reading state files, calling `llmfit`/the engine/`systemctl`, and generating configuration. None of that requires a richer language.
- Python was considered for the richer commands: it is installed by default on Ubuntu/Debian but not on minimal images, and its version varies widely across distributions. Its footprint (tens of MB) is small compared to the inference engines, so resources are not the blocker; simply, bash is enough.

## Consequences

- Quoting, silent errors and idempotence are the main risks; `shellcheck`, `bats` and the conventions above address them.
- The CLI is a dispatcher with sub-commands (see [packaging](decision-packaging.md)), so a sub-command can be rewritten in another language later without changing the interface.

## Revisit when

- a script exceeds roughly 300 lines of logic;
- we need concurrency, non-trivial retries or structured API calls;
- quoting/error-handling bugs keep recurring despite `shellcheck`.

The preferred escape hatch is then **Go** (single static binary, no runtime on the VM), rather than Python, so that the VM does not need an extra interpreter.

## Alternatives considered

| Option | Why not (for now) |
| --- | --- |
| Python (stdlib only) | Not guaranteed on minimal images, version varies; not needed yet |
| Go / Rust | Extra build chain; worthwhile only if bash stops being enough |
| Ansible | Requires Python and a controller; too heavy for tightly-sized VMs |
