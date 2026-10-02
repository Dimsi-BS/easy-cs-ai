# Docs directory

[← Back to project root](../README.md)

This directory contains design decisions and write-ups about the project, complementing the raw findings gathered in [search](../search/README.md).

## Contents

- [CLI commands](cli-commands.md) — the planned `easy-cs-ai` command reference
- [Decision: scripting language](decision-scripting-language.md) — bash (+ `jq`), conventions and when to revisit
- [Decision: packaging and entry point](decision-packaging.md) — single CLI distributed as tarball, `.deb` and `.rpm`; snap dropped
- [Decision: integration order](decision-integration-order.md) — ranking of alternative components per function (inference engine, chat interface)
- [Spec: script contract](spec-script-contract.md) — actions, parameters, secrets, output, exit codes and idempotence rules shared by all install scripts
- [Spec: state format](spec-state-format.md) — layout and JSON schema of `/var/lib/easy-cs-ai/`, feeding `status` and the defaults of `add`
