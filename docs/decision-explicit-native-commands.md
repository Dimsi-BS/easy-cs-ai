# Decision: explicit native tool commands

[← Back to docs](README.md)

**Status:** accepted and implemented (see [spec: CLI](spec-cli.md#native-tool-commands))

## Context

The CLI forwarded to the component's own program (`ollama`, `nginx`, `llmfit`…) any word after `<type> <name>` that was not an action of the contract, and `--` forced it: `engine ollama ps` ran `ollama ps`.

Adding the `size` action to the llmfit component showed the cost. `size` was not in the list of actions the CLI knows, so `easy-cs-ai provisioning llmfit size <model>` went to llmfit itself, which answered `unrecognized subcommand 'size'`. The cause is general: **the actions of the contract and the commands of the tools share one namespace**, so an action added later silently takes over a command of the tool with the same name, and a typo is not reported by the CLI but by the tool, in its own words.

## Decision

- **`easy-cs-ai exec <type> <name> <command> [arguments…]` is the only way to run a component's own program.** The verb comes first, like `install` and `uninstall`: `exec engine ollama ps` runs `ollama ps`. Everything after the name is the tool's, so the global options of the CLI go before `exec`.
- **`<type> <name> <action>` is only an action of the contract**, valid if the `describe` of the component lists it. Any other word is a usage error (exit 2) that lists the actions and points to `exec`. The old form without `exec`, and `--`, are removed.
- **The CLI shows what it runs.** `--verbose` logs the resolved command (with the variables it exports) before running it, and `--dry-run` logs it as a plan and runs nothing.
- **`native.command` stays declared in `describe`.** There is no rule that the name of the component is the name of its program.

## Why

- **The collision cannot happen any more.** The two kinds of command have different syntaxes, so no action of the contract, present or future, can shadow a command of a tool.
- **Mistakes are reported by the CLI.** A mistyped action is a usage error with the list of the valid ones, not a message of the tool that the user has to recognise as coming from somewhere else.
- **The actions come from `describe`, not from a list in the CLI.** This is what the CLI already does for components (it resolves names against the scripts shipped), and it is what would have prevented the `size` problem.
- **It reads as an action.** `exec` says that the CLI runs the tool (which is what it does: it `exec`s it), where an adjective such as `native` would not.

## Consequences

- **A breaking change** for anyone who ran `easy-cs-ai engine ollama ps`. The project is a pre-release, and nothing in the tests, the scripts or the generated scripts used the implicit form: only the documentation and the unit tests of the native commands change.
- **`exec exec` for Docker Compose components**: `exec chat-interface librechat exec api npm run create-user`, where the second `exec` is Compose's own. It is unambiguous and a little ugly.
- **`exec` is outside the state, the lock and the journal**: what it changes is unknown to `status` and `apply`. It is for expert use, and the guide for AI agents lists it among the commands never run on the agent's own initiative.
- **One list remains in the CLI**, `CHANGING_ACTIONS` (which actions need root), see the [open questions](spec-cli.md#open-questions).

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| Keep the fallback, with `--` to force the tool | The collision stays and is silent. A typo reaches the tool. |
| `<type> <name> exec <command>` (verb after the name) | Contract actions and tool commands stay in the same position, and it is a third grammar next to `install engine ollama` and `engine ollama list-models`. |
| `<type> exec <name> <command>` (type first, then the verb) | Also avoids the collision, but is still a third grammar. The verb first matches `install` and `uninstall`. |
| `run` or `native` as the word | `run` repeats the `run` of `ollama` and of `docker compose`: `engine ollama run run llama3.2:3b` in the form first considered. `native` is an adjective, not an action. |
| The component name must be the name of its program, so that `exec engine ollama ps` is obviously `ollama ps` | It is false for a Docker Compose component, which has no program of its own, and for any tool whose binary differs from the component name. The command would look clear exactly where it is misleading. Showing the resolved command is the clarity that holds everywhere. |

## Open questions

- A field per action in `describe` to say which ones change the machine, to remove `CHANGING_ACTIONS`.
- **Is `exec` useful at all?** An administrator can call the installed component directly (`ollama ps`, `nginx -t`, `docker compose -f … logs -f`) without going through the CLI. What `exec` adds is only the environment the project would otherwise make the user retype (`native.env`, such as `OLLAMA_HOST`, and `{compose_file}` for Docker Compose components), the "not installed" precondition check, and the resolved command shown by `--verbose` and `--dry-run`. It adds nothing for an administrator who knows the tool, and it is an extra surface to maintain (spec, tests, the `native` block of every `describe`). To settle: keep it as a convenience, or remove it and document the direct commands instead (with the variables to export where they matter).
- No transition period is planned (the fallback is removed in the same version). If users of the pre-release need one, the fallback could warn for one version, naming `exec`.
