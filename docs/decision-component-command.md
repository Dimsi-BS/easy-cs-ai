# Decision: a `component` command for the commands of a component

[← Back to docs](README.md)

**Status:** accepted and implemented (see [spec: CLI](spec-cli.md#command-line))

## Context

The component types (`engine`, `chat-interface`, `proxy`, `provisioning`) were commands of the root: `easy-cs-ai engine ollama list-models`, `easy-cs-ai proxy nginx show-key`. The first word of the command line was either a general command (`status`, `install`…) or a type, and these two sets were the reserved words.

That makes the root depend on the catalogue. A new type (a vector database, monitoring…) takes a new word of the root, and a new general command (`model`, `logs`…) can clash with a type. The help mixed the two as well: `provisioning llmfit suggest|plan` sat next to `catalog` and `host`, which are the commands for an AI agent.

## Decision

- **The commands of a component go through `component`**: `easy-cs-ai component <type> <name> <action> […]`. `component <type>` lists the components of a type and `component` alone lists every type, with whether each component is installed.
- **The root holds only general commands**, so it is the only reserved set. A type is a value of a command (`install engine ollama`, `exec engine ollama ps`, `component engine ollama list-models`), never a command.
- **`install`, `uninstall` and `exec` keep their form.** They are verbs that come first and take a component after them; `component` is the noun for the actions of the contract.
- **The old form is removed**, with no alias. A type as the first word is an unknown command (exit 2) whose hint points to `component`.

## Why

- **A new type or component takes no word of the root**, and a new command cannot be shadowed by one. The CLI already resolves types and names against the scripts shipped, so only the dispatcher, the help and the documentation change.
- **The root says what the CLI does**: general commands and discovery. The component commands are one entry of the help, not four.
- **No alias**, because an alias would keep the types as reserved words, which is what this removes.

## Consequences

- **A breaking change** for the commands of components (`proxy nginx show-key` becomes `component proxy nginx show-key`). The project is a pre-release; the unit and integration tests, `guide.txt`, the README and the documentation that give the old form change with the code.
- **A longer command** for the ones typed often (`component proxy nginx show-key`). The root verbs people use every day (`status`, `install`, `add`) are not affected.
- **Two grammars remain side by side**: `install engine ollama` and `component engine ollama list-models`. The first word is always a verb or the noun `component`, and the type is always the second.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| Keep the types at the root | The root keeps depending on the catalogue, and a command can clash with a type. |
| Keep the types at the root as aliases of `component` | The types stay reserved words, so nothing is gained. |
| `component` only as an optional prefix | Two ways to write the same command, and the types stay reserved. |
| One command per type with the same grammar (`engine ollama …`) under `install` and `exec` too | The three verbs would still not form one rule, and `exec` and `install` would change for nothing. |
