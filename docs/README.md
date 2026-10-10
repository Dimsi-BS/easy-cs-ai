# Docs directory

[← Back to project root](../README.md)

This directory contains design decisions and write-ups about the project, complementing the raw findings gathered in [search](../search/README.md).

## Contents

- [CLI commands](cli-commands.md) — the planned `easy-cs-ai` command reference
- [Decision: scripting language](decision-scripting-language.md) — bash (+ `jq`), conventions and when to revisit
- [Decision: packaging and entry point](decision-packaging.md) — single CLI distributed as tarball, `.deb` and `.rpm`; snap dropped
- [Decision: integration order](decision-integration-order.md) — ranking of alternative components per function (inference engine, chat interface)
- [Decision: TLS certificates of the reverse proxy](decision-nginx-certificates.md) — self-signed by default, certificate provided by the customer, or Let's Encrypt
- [Decision: how vLLM is installed](decision-vllm-install.md) — Python venv by default, Docker reserved (proposed)
- [Decision: how LibreChat is installed](decision-librechat-install.md) — Docker from its own apt repository, FerretDB + PostgreSQL stack pinned by digest, web interface served by a second nginx `server`, registration open by default with a warning, models reached on the loopback
- [Decision: VM script generator](decision-vm-generator.md) — one interactive generator for the VM script, none for layer 1; package downloaded from a pinned source, not embedded
- [Decision: explicit native tool commands](decision-explicit-native-commands.md) — `easy-cs-ai exec <type> <name> <command>` runs a component's own program; a word that is no action of the contract is an error, not a fallback
- [Spec: script contract](spec-script-contract.md) — actions, parameters, secrets, output, exit codes and idempotence rules shared by all install scripts
- [Spec: state format](spec-state-format.md) — layout and JSON schema of `/var/lib/easy-cs-ai/`, feeding `status` and the defaults of `add`
- [Spec: CLI](spec-cli.md) — dispatch, `status`, `install`, `uninstall`, `add` orchestration with rollback, CLI exit codes
- [Spec: configuration file and `apply`](spec-config.md) — declarative JSON deployment description, interpreted by `apply`, written by the generator (`--config-only`) and read back with `--config`
- [Spec: VM script generator](spec-vm-generator.md) — interactive session, package source, shape of the generated VM script
- [Spec: machine interface of the CLI](spec-ai-interface.md) — `--json` for programs and AI agents: `catalog`, `host`, `config schema` / `validate`, result documents, typed options, procedure for an agent (proposed)
