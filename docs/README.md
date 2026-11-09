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
- [Decision: how LibreChat is installed](decision-librechat-install.md) — Docker from its own apt repository, FerretDB + PostgreSQL stack pinned by digest, web interface served by a second nginx `server`, registration open until the first account, then closed by itself (specified, not implemented yet), models reached on the loopback
- [Spec: LibreChat options for e-mail verification and domain sign-up](spec-librechat-mail-options.md) — SMTP relay, `public-url`, `registration-domains`, the relay check and `test-mail` (proposed, not implemented)
- [Decision: VM script generator](decision-vm-generator.md) — one interactive generator for the VM script, none for layer 1; package downloaded from a pinned source, not embedded
- [Decision: explicit native tool commands](decision-explicit-native-commands.md) — `easy-cs-ai exec <type> <name> <command>` runs a component's own program; a word that is no action of the contract is an error, not a fallback
- [Decision: a `component` command](decision-component-command.md) — `easy-cs-ai component <type> <name> <action>` for the commands of a component; the types are no longer commands of the root
- [Spec: script contract](spec-script-contract.md) — actions, parameters, secrets, output, exit codes and idempotence rules shared by all install scripts
- [Spec: state format](spec-state-format.md) — layout and JSON schema of `/var/lib/easy-cs-ai/`, feeding `status` and the defaults of `add`
- [Spec: CLI](spec-cli.md) — dispatch, `status`, `install`, `uninstall`, `add` orchestration with rollback, CLI exit codes
- [Spec: configuration file and `apply`](spec-config.md) — declarative JSON deployment description, interpreted by `apply`, written by the session `config edit` and read back by `script`; the format of version 2 (a list of VMs holding their components, the models held by their engine, and a root `links` array that says which model is shown in which chat interface) is decided and not implemented; what a model needs (proxy, llmfit) is implemented
- [Spec: VM script generator](spec-vm-generator.md) — the generator as two commands: `config edit` (the interactive rendering of the journey, creates and edits the configuration) and `script` (configuration to scripts, no prompt), package source, shape of the generated VM script
- [Decision: JSON output without `--json`?](decision-json-output-rule.md) — `--json` accepted everywhere, JSON by default allowed for data-only commands (accepted)
- [Spec: the journey](spec-journey.md) — from a need to a stack, in seven steps defined once and walked either as an interactive session or with arguments and `--json`; rules that keep the two in step
- [Spec: capabilities of the CLI](spec-capabilities.md) — `catalog`, `host`, `config schema` / `validate`, result documents, typed options, secrets; one document per capability
- [Spec: renderings](spec-rendering.md) — the same document shown as text and questions for a person, as `--json` and arguments for a program; `guide`; parity checks
- [Spec: model fit and VM sizing](spec-model-fit.md) — `suggest`, `check`, `plan` of `provisioning llmfit`, the estimated margin, llmfit as an option; the resources declared by each component and the stack with no model are implemented
- [Spec: Apache CloudStack integration](spec-cloudstack.md) — a native section of the CloudStack UI, contributed upstream, to define a topology of VMs for a local AI (web VM, engine VM…), create its resources and monitor what concerns the use of the AI; a third rendering of the journey over a Rust core built for WebAssembly, no server, the tagged resources, the read-only status document of the proxy (specified, not implemented)
- [Spec: several VMs, and the editor of the configuration](spec-multi-vm.md) — the VMs of the configuration, any number of VMs with optional roles, one generated script per VM, the generator as creator and editor of the configuration (`config edit`) and, apart, `script`, the link between VMs (a model shown in the chat interface of another VM) finished by hand once the VMs are up, `add-endpoint` with an API key and a certificate; a single machine is a file of one VM (the `vm` field of version 1 and the two-VM session are implemented; the format of version 2, roles, any number of VMs and the editor are proposed)
- [Plan: implementing the configuration format version 2](plan-config-format-2.md) — the steps, their order and the state of the tests between them (proposed, to be validated)
