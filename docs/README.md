# Docs directory

[← Back to project root](../README.md)

This directory contains design decisions and write-ups about the project, complementing the raw findings gathered in [search](../search/README.md).

## Contents

- [CLI commands](cli-commands.md) — the planned `easy-cs-ai` command reference
- [Decision: scripting language](decision-scripting-language.md) — bash (+ `jq`), conventions and when to revisit
- [Decision: packaging and entry point](decision-packaging.md) — single CLI distributed as tarball, `.deb` and `.rpm`; snap dropped
- [Decision: integration order](decision-integration-order.md) — ranking of alternative components per function (inference engine, chat interface)
- [Decision: VM script generator](decision-vm-generator.md) — one interactive generator for the VM script, none for layer 1; package downloaded from a pinned source, not embedded
- [Spec: script contract](spec-script-contract.md) — actions, parameters, secrets, output, exit codes and idempotence rules shared by all install scripts
- [Spec: state format](spec-state-format.md) — layout and JSON schema of `/var/lib/easy-cs-ai/`, feeding `status` and the defaults of `add`
- [Spec: CLI](spec-cli.md) — dispatch, `status`, `install`, `uninstall`, `add` orchestration with rollback, CLI exit codes
- [Spec: configuration file and `apply`](spec-config.md) — declarative JSON deployment description, interpreted by `apply`, written by the generator (`--config-only`) and read back with `--config`
- [Spec: VM script generator](spec-vm-generator.md) — interactive session, package source, shape of the generated VM script
