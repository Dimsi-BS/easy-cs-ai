# Spec: CLI

[← Back to docs](README.md)

**Status:** accepted. What concerns a configuration that names several VMs (`apply --vm`, one script per VM from `generate`) is **proposed, not implemented**, see [spec: two VMs](spec-two-vm.md); a file with no `vm` behaves as described.

## Purpose

The `easy-cs-ai` CLI is the layer 2 entry point. It is a thin `git`-style dispatcher over the layer 1 scripts (see [packaging](decision-packaging.md)), plus the commands that do their own work (`status`, `install`, `uninstall`, `add`, `remove`, `apply`), which combine several scripts. This spec fixes how a command line is resolved, what each command does step by step, how failures are reported and what is undone on error.

It builds on the [script contract](spec-script-contract.md) (actions, `describe`, exit codes) and the [state format](spec-state-format.md); it does not repeat them. [CLI commands](cli-commands.md) stays the short overview.

Out of scope: the interface of the generator behind `generate`, see [spec: VM script generator](spec-vm-generator.md).

## Installed layout

```text
/usr/bin/easy-cs-ai                     the dispatcher
/usr/lib/easy-cs-ai/
  lib/common.sh
  engine/ollama.sh  proxy/nginx.sh  …   the layer 1 tree, as in the contract
  templates/
```

- The dispatcher sets `EASY_CS_AI_LIB` to `/usr/lib/easy-cs-ai/lib` and runs the scripts from there. It sources `lib/common.sh` itself for `log_*`, `die`, the lock helpers (`with_state_lock`, `with_component_lock`) and the state helpers.
- The tarball has the same tree under any directory; the dispatcher finds it through `EASY_CS_AI_HOME` when set, else `../lib/easy-cs-ai` relative to itself, else `../../install_scripts` (the source tree: the dispatcher is `package/bin/easy-cs-ai`), else `/usr/lib/easy-cs-ai`.
- `EASY_CS_AI_ROOT`, `EASY_CS_AI_STATE_DIR` and `EASY_CS_AI_CONFIG_DIR` are honoured and passed through, so the CLI is testable with `bats` like the scripts.

## Command line

```text
easy-cs-ai [global options] <command> [arguments…]
```

| Command | Effect |
| --- | --- |
| `status` | List installed components with their live status |
| `install <type> <name> [options…]` | Install a component |
| `install [<type>] --defaults` | Install the default choices (a whole stack, or the default component of a type) |
| `uninstall <type> <name> [options…]` | Uninstall a component |
| `uninstall --all` or `uninstall <type> --all` | Uninstall everything that is installed (of a type, or all), without naming components |
| `add <model> [--engine <name>] [--chat-interface <name>]` | Add a model to an engine and wire it |
| `remove <model> [--engine <name>]` | Unwire a model and remove it from its engine |
| `remove --all [--engine <name>]` | Remove every model (of one engine, or of all) |
| `apply <file\|-> [--vm <name>] [--prune]` | Make the machine match a configuration file (`--vm` selects one VM of a file that names several, proposed) |
| `generate [--config-only] [parameters…]` | Produce the parameterless VM post-install script (one per VM when the configuration names several), or only its configuration file |
| `catalog`, `host`, `config schema`, `config validate`, `guide` | Read-only discovery and validation for a person as well as for a program or an AI agent, see [spec: capabilities](spec-capabilities.md) |
| `exec <type> <name> <command> [arguments…]` | Run the component's own program (`ollama`, `nginx`…) as it is, see [Native tool commands](#native-tool-commands) |
| `<type> <name> <action> [arguments…]` | Component command: an action of the contract, forwarded to the script |

- `<type>` is one of `engine`, `chat-interface`, `proxy`, `provisioning` (the contract types). `install` accepts all four, since `proxy` and `provisioning` are required by other commands (see [Dependencies](#dependencies)).
- **Global options**, accepted before the command: `--help`, `--version`, `--verbose`, `--dry-run`, `--json`. After the command, `status`, `add`, `remove`, `apply`, `config`, `catalog`, `host` and `guide` accept the last three too; for `install` and `uninstall`, `--json` is the CLI's and `--dry-run` goes to the components, which print their own plan; after a component command or `generate` they are forwarded as they are, since the scripts and the generator accept the same ones; after `exec` they belong to the tool, so they go **before** `exec`.
- **General commands and component commands are kept apart.** A component is always addressed by its type followed by its name (`engine ollama`), never by its name alone. The first word of the command line is therefore either a general command (`status`, `install`, `uninstall`, `exec`, `add`, `remove`, `apply`, `generate`, `catalog`, `host`, `config`, `guide`, `help`, `version`) or a component type (`engine`, `chat-interface`, `proxy`, `provisioning`): these two sets are the reserved words, so a component name can never clash with a general command.
- Like the scripts, the CLI **never prompts**. Unknown commands, unknown types, unknown component names and missing arguments are usage errors (exit 2) with a message listing the valid values.

### Dispatch

The CLI resolves names against the scripts actually shipped (`<libdir>/<type>/<name>.sh`), never against a hardcoded list, so a new component needs no CLI change.

| Command line | Resolved to |
| --- | --- |
| `install engine ollama --port 11435` | `engine/ollama.sh install --port 11435` |
| `uninstall engine ollama --purge` | `engine/ollama.sh uninstall --purge` |
| `engine ollama list-models` | `engine/ollama.sh list-models` |
| `proxy nginx show-key` | `proxy/nginx.sh show-key` |
| `provisioning llmfit size llama3.2:3b` | `provisioning/llmfit.sh size llama3.2:3b` (a contract action, not llmfit's own command line) |
| `engine` | lists the engines shipped and, for each, whether it is installed (no script call except `describe`) |

- `install` and `uninstall` add the CLI-level steps described below (dependencies, `--default`); everything else after the component name is forwarded untouched. The script is the judge of its own options (unknown option → exit 2 from the script).
- A component command forwards stdout, stderr and exit code as they are. Type-specific actions that change the component's own models or endpoints (`engine ollama add-model`, `chat-interface librechat add-endpoint`) are available this way for expert use, but do **not** do the wiring that `add` does.
- `easy-cs-ai <type> <name> --help` shows the script's help, generated from its `describe`.
- `<type> <name> <action>` is valid only if the action is listed in `actions` of the component's `describe` (see the [contract](spec-script-contract.md#describe)), or is an option such as `--help`. The CLI keeps no list of actions of its own for this, so an action added to a script needs no CLI change, like a new component. Any other word is a usage error (exit 2) that lists the actions of the component and points to `exec`: it is never taken for a command of the component's program, see [Native tool commands](#native-tool-commands).

### Native tool commands

**Principle: what a tool already does is executed by the tool, never reimplemented.** The CLI and the scripts only add what the project's conventions require around the call (root check, lock, state, journal, JSON on stdout, exit codes). Why the program is reached through an explicit command and not by any word that is no action: [decision](decision-explicit-native-commands.md).

- `exec <type> <name> <command> [arguments…]` runs **as is by the component's own program**, declared in `describe` as `native.command` (`ollama`, `nginx`, `llmfit`…), with the command and the arguments as the tool receives them:

  | Command line | Executed |
  | --- | --- |
  | `exec engine ollama run llama3.2:3b` | `ollama run llama3.2:3b` |
  | `exec engine ollama ps` | `ollama ps` |
  | `exec proxy nginx -t` | `nginx -t` |
  | `exec provisioning llmfit system` | `llmfit system` |

  Arguments, streams, TTY and exit code are the tool's own (it is `exec`'d, nothing is parsed or filtered). The CLI does not check root here: the tool decides. Everything after `<name>` belongs to the tool, so the global options of the CLI go **before** the command (`easy-cs-ai --dry-run exec engine ollama ps`).
- **Explicit, never guessed.** The verb comes first, as for `install` and `uninstall`, and `<type> <name> <action>` is only ever an action of the contract. A word that is not one is a usage error that points to `exec`, it no longer falls through to the tool. Otherwise a contract action added later would silently take over the same name of the tool, and a typo would reach the tool instead of being reported. The old forms `<type> <name> <tool command>` and `<type> <name> -- <tool command>` are gone, `--` included: it was the explicit form of this.
- **What runs is shown, not implied.** The name of a component is not always the name of its program (a Docker Compose component has none of its own), so the CLI states the resolved command, on stderr, never on stdout, which belongs to the tool: `--verbose` logs `exec: OLLAMA_HOST=127.0.0.1:11434 ollama ps` before running it, and `--dry-run` logs `plan: exec OLLAMA_HOST=127.0.0.1:11434 ollama ps`, with the variables it would export, and runs nothing, as the plans of `install` and `uninstall` do.
- The CLI only prepares the environment so that the tool talks to the instance the project installed: it exports the variables listed in `describe.native.env` (e.g. `OLLAMA_HOST`), built from the `params` recorded in the state. The component must therefore be installed (exit 4 otherwise).
- Components without a program of their own (Docker Compose-based chat interfaces) declare `native.command` as `docker compose -f <compose_file>` (from the state `service`), so `exec chat-interface librechat logs -f` is `docker compose -f … logs -f`, and `exec chat-interface librechat exec api npm run create-user` runs Compose's own `exec`. A component with nothing to run natively leaves `native` out, and `exec` on it is a usage error.
- **Refusals.** Exit 2 (usage): no command, no component name, an unknown type or component, a component that declares no `native`, and `--json` before `exec` (the output is the tool's, it is not turned into JSON). Exit 4 (precondition): the component is not installed, or its program is not found on the machine (checked before running, instead of the shell's 127). Otherwise the exit code is the tool's own.
- The type-specific actions of the contract are themselves **thin wrappers** over native commands (`list-models` reads the engine's API, as `ollama list` is a table, `remove-model` runs `ollama rm`, `provisioning suggest` runs `llmfit recommend --json`). They exist only to add the convention-mandated parts: JSON on stdout, state update, journal, a size-aware wait. See the [contract](spec-script-contract.md#wrapping-native-tools).

### Privileges

`install`, `uninstall`, `add`, `remove`, `apply` (except with `--dry-run`) and the changing component actions require root. The CLI checks it first and fails with exit 4 and a message suggesting `sudo`; it never re-executes itself through `sudo`. `status`, `--help`, `describe` and the read-only actions run unprivileged (the state is world-readable, see [state format](spec-state-format.md#layout)).

`exec` is not checked for root: the tool decides. It is also outside the state, the lock and the journal: a model pulled or removed with `exec engine ollama pull` / `rm` is unknown to `status` and `apply`, as with the expert actions of [Dispatch](#dispatch) that do not do the wiring of `add`. It is for expert use, and an agent never runs it on its own initiative (see [spec: machine interface](spec-journey.md#what-a-program-never-does-on-its-own)).

## Implementation status

Implemented: dispatch, `status`, `install` (dependencies, `--defaults`, default stack), `uninstall` (single, `--all`, wiring clean-up), component commands. `exec` is implemented, and the actions are checked against the `describe` of the component (the CLI keeps no list of them; only `CHANGING_ACTIONS`, for root, remains). `add` and `remove` are implemented (in `lib/cli-models.sh`) and tested with fake components; they cannot succeed on a real machine before the proxy, llmfit and a chat interface exist (a missing one is the documented exit 4). The signal handling (SIGINT/SIGTERM, rollback, 130/143) is written but not covered by tests yet. `apply` is implemented (in `lib/cli-apply.sh`, see [spec: config](spec-config.md)) and tested with fake components. `generate` hands over to `vm_script/generate.sh` (`$HOME_DIR/vm_script`, else `../vm_script`), exporting `EASY_CS_AI_HOME` and `EASY_CS_AI_CLI_VERSION`, and forwarding `--dry-run` and `--verbose`.

## `status`

Reads every `components/*.json`, then calls `<script> status` for each (live probe, in order, each limited to 15 s: a timeout is reported as not healthy). Output as in [state format](spec-state-format.md#what-status-combines):

```text
COMPONENT     TYPE            VERSION   DEFAULT  RUNNING  HEALTHY  MODELS
ollama        engine          0.5.7     yes      yes      yes      llama3.2:3b
```

- `--json` prints one array of objects instead: `name`, `type`, `version`, `default`, `models` (an array of names) from the state, and `running`, `healthy` from the script's `status` JSON. Sorted by type, then name. Other fields are not repeated: the state files are readable by anyone.
- A component whose state file cannot be read (unknown higher `schema_version`, invalid JSON) is shown with `VERSION` and flags as `?`, and an `ERROR` line on stderr names the file. It is never hidden.
- A pending manifest without state (failed install) is not listed as a component: one `WARN` line on stderr names it and the `uninstall` command that cleans it. It does not change the exit code.
- Nothing installed prints the header and a hint (`easy-cs-ai install engine ollama`) on stderr.
- **Exit code**: 0 when every component is healthy (or nothing is installed), 6 when at least one is installed but not healthy, 1 when a state file is unreadable.

## `install`

```text
easy-cs-ai install <type> <name> [--defaults] [--default] [script options…]
easy-cs-ai install <type> --defaults
easy-cs-ai install --defaults
```

**The CLI never picks a component on its own.** Every choice it would otherwise guess (which component, which dependency) is made only when `--defaults` is given. `--defaults` is a CLI option, not forwarded to the scripts; it is about *which components* are installed, whereas the options of a given component fall back on the script's own built-in defaults as usual. Not to be confused with `--default`, which makes a component the default of its type (see [Defaults](spec-state-format.md#defaults)) and is forwarded to the script.

| Command line | Effect |
| --- | --- |
| `install engine ollama` | Installs Ollama; a missing requirement fails (see [Dependencies](#dependencies)) |
| `install engine ollama --defaults` | Same, and installs the missing requirements with their defaults |
| `install engine --defaults` | Installs the rank 1 engine (see [integration order](decision-integration-order.md)) |
| `install --defaults` | Installs the **default stack**: the rank 1 component of every type that is not installed yet |
| `install engine` or `install` | Usage error (exit 2) suggesting the `--defaults` form |

Steps for one component:

1. Check root and resolve the script (usage error otherwise).
2. [Resolve dependencies](#dependencies).
3. Run `<script> install` with the remaining options, stdout and stderr passed through.
4. If `--default` was given, the script itself sets the flag; it is forwarded as a script option, so a generated standalone script behaves the same.

The exit code is the script's, except when a dependency failed (that step's code, with a message naming it).

**Default stack** (`install --defaults`): for each type (`provisioning`, `proxy`, `engine`, `chat-interface`), if no component of the type is installed, install the rank 1 one, in an order that satisfies `requires` (computed from `describe`, not hardcoded). Types already installed are left alone, so the command converges and is safe to re-run. It follows the integration order, so a change of rank 1 changes the stack without touching the CLI: the order is the file `ranks.conf` shipped next to the scripts (`<type> <name>` lines, rank 1 first within each type), not code. A type whose rank 1 has no install script yet (or that has no rank) is skipped with a `WARN`, so the command works while the catalogue is being built; naming the type explicitly (`install <type> --defaults`) fails instead. This is the one-line form for the VM post-install layer.

### Default model

An engine with no model leaves the first contact with the product empty (and the model selector of the chat interface too). `install --defaults` (the whole stack, or `install engine --defaults`) therefore adds the **default model** of each engine **it installed**, after every component of the run, so that the chat interface is there to be linked.

- **Where**: `default-models.conf`, shipped next to `ranks.conf` (`<engine> <model>` per line, the model in the engine's own naming). It is data, not code, so changing a default needs no CLI change. An engine with no line gets no model (an `INFO`).
- **Fixed, not chosen from the machine**: the default is a small model that fits any VM (`llama3.2:3b` for Ollama). Choosing from `provisioning suggest` would make two VMs of the same fleet differ and the result unpredictable for the VM post-install layer; the fit check of `add` still protects a machine too small even for it.
- **How**: the [`add`](#add) orchestration with `--engine <engine> --defaults` (fit check, wiring, rollback as usual).
- **Failure**: a model that does not fit or cannot be downloaded is a `WARN` naming the `add` command to run; the install still succeeds (exit 0), since the stack is sound and only the model is missing.
- **Only for what the run installed**: an engine already installed is left alone, as for every component, so a model removed with `remove` is not brought back by a re-run, and the command still converges. `--dry-run` announces the model without adding it.
- **Cost**: the download and disk size of the model are added to a default install (about 2 GB for `llama3.2:3b`).
- **Refreshing**: model names age (renamed tags, better small models). The file carries a `Last reviewed` date and is reviewed by hand, together with the [integration order](decision-integration-order.md#decision) and the pinned versions of the scripts. A tag that has disappeared shows as the `WARN` above on a default install, not as a failure. No automatic update: a default must be a reviewed, reproducible choice. The [integration test](../tests/integration/README.md) covers it (step 8).

### Dependencies

The scripts only *check* `requires`, they never install another component (see the contract). Resolving is the CLI's job:

- Requirements are read from `<script> describe` (`requires`, a list of component **names or types**).
- A missing requirement **fails with exit 4** and a message giving the exact command to run (`nginx is required by librechat: easy-cs-ai install proxy nginx`).
- With `--defaults`, a missing requirement is installed first with its default options, announced on stderr (`[INFO] installing nginx (required by librechat)`). If the requirement is a type, the rank 1 component of that type is chosen.
- `--dry-run` prints the whole chain and installs nothing.

## `uninstall`

```text
easy-cs-ai uninstall <type> <name> [--purge] [--force]
easy-cs-ai uninstall <type> --all [--purge] [--force]
easy-cs-ai uninstall --all [--purge] [--force]
```

`--all` designates **everything that is installed**, so that a test environment is wiped with one command and no component is named. It has nothing to do with `--defaults` (which is only about installing default choices): it removes whatever is there, including a component that is not rank 1 (e.g. vLLM).

| Command line | Effect |
| --- | --- |
| `uninstall engine ollama` | Uninstalls Ollama, or cleans the leftovers of a failed install (exit 4 if there is neither a state nor a pending manifest, as in the contract) |
| `uninstall engine --all` | Uninstalls every installed engine; none installed → nothing to do, exit 0 |
| `uninstall --all` | Uninstalls **every installed component**, of every type |
| `uninstall engine` or `uninstall` | Usage error (exit 2) suggesting the `--all` form |

- The components are the `components/*.json` of the state, plus the `pending/*.json` manifests of failed installs (see [pending manifest](spec-state-format.md#pending-manifest)), cleaned last since nothing can depend on them. Anything running on the machine but absent from the state is not touched (the state only covers what the tool installed).
- The order puts dependents before what they need (from the `requires` in the state files), so no `--force` is required. Among components with no relation between them, the **reverse of the install order** applies: chat interface, engine, proxy, provisioning. The engine therefore goes before the proxy, and its models are unwired while the proxy and the chat interface can still be reached (see the clean-up below).
- The run stops at the first failure and returns its exit code; running it again resumes with what is left. `--purge` and `--force` apply to every component of the run; without `--purge`, data (models, databases) is kept, as for a single `uninstall`.
- `--dry-run` prints the list of components that would be removed, in order.
- Because this is destructive, `--all` is refused on a command line that names a component: `uninstall engine ollama --all` is a usage error (exit 2). `--defaults` is not accepted by `uninstall` at all (usage error).

For one component, the CLI checks root, then runs `<script> uninstall` with the options. Refusal when another component `requires` this one (exit 4) is the script's; the CLI adds the list of those components to the message by scanning `requires` in the state files. The CLI does **not** cascade: dependents are never removed implicitly.

After the script succeeds, the CLI cleans the wiring left in other components:

- engine removed: nothing else to do for the models it served beyond the next point;
- for each model of the removed engine recorded with `exposed_via` / `linked_to`, run `proxy remove-upstream` and `chat-interface remove-endpoint` (best effort: a failure is a `WARN` and does not change the exit code, since the engine is already gone);
- proxy or chat interface removed: clear the matching `exposed_via` / `linked_to` entries in the engine models.

Defaults are handled by the script (promotion or none, see state format).

## `add`

```text
easy-cs-ai add <model> [--engine <name>] [--chat-interface <name>] [--no-chat-interface] [--defaults] [--force] [--dry-run]
```

`add` is an orchestration of component actions. Every change goes through a script action, so scripts stay the only writers of their own state (one exception, step 5).

### Resolution (no side effect)

1. **Engine**: `--engine`, else the component of type `engine` with `"default": true`. No engine installed → exit 4 (`install an engine first`); several and no default → exit 4 listing the candidates; an unknown name → exit 4.
2. **Chat interface**: `--chat-interface`, else the default one. If none is installed and the option was not given, this step is skipped with an `INFO` (an engine alone, reached by API, is a valid setup); `--no-chat-interface` skips it explicitly. A named but missing chat interface → exit 4.
3. **Needs a proxy?** Read the engine's `endpoint.protected`. If `false` the model must be wrapped by the proxy.
4. **Missing components**: the step 1 and 3 components (llmfit, the proxy) that are not installed make the command fail with exit 4 and the command to run, unless `--defaults` is given, in which case they are installed with their defaults (see [Dependencies](#dependencies)). Nothing is installed implicitly.
5. Print the plan (`--dry-run` stops here, exit 0).

### Steps

| # | Step | Action | Skipped when |
| --- | --- | --- | --- |
| 1 | Check the model fits | `provisioning check <model>` | `--force` |
| 2 | Add to the engine | `engine add-model <model>` | model already in the engine |
| 3 | Expose through the proxy | `proxy add-upstream <upstream> <url>` | engine is `protected`, or already exposed |
| 4 | Link to the chat interface | `chat-interface add-endpoint <name> <url> --model <model>` | no chat interface, or already linked |
| 5 | Record the wiring | update `models[].exposed_via` / `linked_to` in the engine state | nothing changed in 3 and 4 |

- **Step 1**: a negative verdict stops the command with exit 4 and the reason from llmfit; `--force` bypasses the check, with a `WARN`. With `--force`, llmfit is not needed at all, so it is not counted among the missing components. The check is also skipped when the model is already in the engine.
- **Step 3**: on a resume where the model is already exposed, the step is skipped, so a rollback never removes an upstream that existed (step 4 no longer needs the URL it prints). An engine that records no `endpoint` (one instance per model) is treated as not `protected`, so its models go through the proxy. `<upstream>` is `<engine>-<model slug>` (lowercase, characters outside `[a-z0-9.-]` replaced by `-`), so models of two engines never collide. `<url>` is the model's internal URL: the engine `endpoint.url`, or, for an engine with one instance per model, `http://127.0.0.1:<port>` from the model's entry.
- **Step 4**: `<name>` is the same slug, `--model <model>` is the model being added, and `<url>` is the **internal** OpenAI base URL of the engine, whether or not the model went through the proxy: the engine `endpoint.openai_base_url`, or, for an engine with one instance per model, `http://127.0.0.1:<port>/v1` from the model's entry. The chat interface runs on the same machine, so the link needs neither HTTPS nor an API key; the proxy is for clients outside the machine (see [decision: LibreChat install](decision-librechat-install.md#4-reaching-the-models-from-the-container)). Steps 3 and 4 are independent.
- **Step 5** is the one place where the CLI writes a component's state: `exposed_via` and `linked_to` describe a relation between components, which no single script knows. It uses the `lib/common.sh` state helpers (lock, atomic write, `jq empty`), following the [writing rules](spec-state-format.md#writing-rules), and preserves unknown fields.
- The CLI holds **no lock** across the steps: each script takes its own component lock for its action, and the state helpers take the state lock for the write only (see [Locking](spec-script-contract.md#locking)). A step that finds its component busy fails with exit 4 and triggers the rollback as any failure. Two concurrent `add` of different models are fine; two of the same model converge thanks to the idempotence of the steps.

### Idempotence and resume

`add` is re-runnable. Each step first checks the engine state (model present, `exposed_via`, `linked_to`) and does only what is missing. A `add` that failed at step 4 is completed by running it again; one that is complete exits 0 with `already added`.

### Rollback

On a failure at step *N*, the steps **done by this run** are undone in reverse order:

| Failed step | Undone, in this order |
| --- | --- |
| 5 | `chat-interface remove-endpoint`, `proxy remove-upstream`, `engine remove-model` |
| 4 | `proxy remove-upstream`, `engine remove-model` |
| 3 | `engine remove-model` |
| 2 | nothing (the script cleans after itself, see the contract) |
| 1 | nothing |

- What existed before the run is never undone (a model that was already in the engine stays, so a failed re-run cannot damage a working setup).
- Components installed through `--defaults` (llmfit, nginx) are **kept**: they are shared, harmless, and a retry reuses them.
- The failure is reported with the failing step's exit code. If the rollback itself fails, the leftovers are listed on stderr (`[ERROR] could not undo: proxy upstream ollama-llama3.2-3b`) and the exit code is **7**.
- Step 2 of a large model can be interrupted (Ctrl-C, SIGTERM): the CLI traps the signal, lets the running script finish its own cleanup, then rolls back as for a failure (exit 130 / 143, standard shell convention).

### Journal

`add` and `remove` write `<command> start model=… engine=… chat_interface=…` and `<command> end exit=… duration=…` through `log_event`, around the lines of each script (see [Action journal](spec-script-contract.md#action-journal)).

## `remove`

```text
easy-cs-ai remove <model> [--engine <name>] [--dry-run]
easy-cs-ai remove --all [--engine <name>] [--dry-run]
```

The reverse of `add`: it unwires the model, then deletes it from its engine. Mostly meant to repeat install tests quickly, without reinstalling the engine.

`remove --all` removes **every model** of the engine given by `--engine`, or of every engine when the option is absent, so a test environment goes back to "components installed, no model" in one command. It runs the steps below for each model in turn (engines in state order, models in `models` order). It is refused when a model name is also given (usage error, exit 2), and `--defaults` is not accepted. It stops at the first failing model and returns its exit code; running it again resumes with the models left. Nothing to remove → exit 0.

### Resolution (no side effect)

1. Check root.
2. **Engine** (single model): `--engine`, else the engine whose state lists `<model>` in `models`. Not found anywhere → exit 4 (`model not found`, listing the known models). Held by several engines → exit 4 listing them, to be disambiguated with `--engine`. The default engine is **not** used: a model is searched where it is.
3. Print the plan (`--dry-run` stops here, exit 0).

### Steps

Reverse order of `add`, so that nothing ever points to a model that no longer exists:

| # | Step | Action | Skipped when |
| --- | --- | --- | --- |
| 1 | Unlink from each chat interface in `linked_to` | `chat-interface remove-endpoint <name>` | `linked_to` is empty |
| 2 | Remove from the proxy | `proxy remove-upstream <upstream>` | `exposed_via` is `null` |
| 3 | Remove from the engine | `engine remove-model <model>` | — |

- After steps 1 and 2 the CLI clears the matching `linked_to` / `exposed_via` in the engine state (same state helpers as `add` step 5), so a failure further on leaves a state that matches reality. Step 3 removes the whole `models` entry.
- A component named in `linked_to` / `exposed_via` that is no longer installed is skipped with a `WARN` (nothing to unwire).
- Data: the model files are deleted by the engine's own command (`ollama rm`). The proxy, the chat interface and the components installed with `--defaults` are never touched.

### Failure and resume

There is **no rollback**: undoing a removal would mean pulling the model again, which is long and may not be possible offline. The command stops at the first failing step and returns its exit code. Because the order unwires first, the model is then at worst *still present but no longer reachable*, a consistent state. Running `remove` again resumes: each step does only what is left, and the last one exits 0 once the model is gone (a model absent everywhere is then the exit 4 of the resolution, as for any unknown model).

## Exit codes

The CLI uses the **script contract codes** with the same meaning, and passes the script's code through when it runs one script; for composite commands it is the code of the failing step.

| Code | Meaning in the CLI |
| --- | --- |
| 0 | Success, including "nothing to do" |
| 1 | Unexpected error, unreadable state |
| 2 | Usage error: unknown command, type or component, missing argument, bad option |
| 3 | Unsupported platform |
| 4 | Precondition not met: not root, nothing to act on (no engine, model does not fit, unknown default), component required by another, a component to `exec` that is not installed or whose program is not found |
| 5 | Network or download failure |
| 6 | Verification failed, or `status` found an unhealthy component |
| 7 | **CLI only**: the command failed and its rollback is incomplete, see stderr for what is left |
| 130, 143 | Interrupted by SIGINT / SIGTERM |

- The CLI adds a human message to each code (first line on stderr, `[ERROR] <what failed> (exit <code>: <meaning>)`) and ends with a hint when there is one. The scripts' own log lines are not filtered.
- Code 7 is reserved by this spec; the contract says "anything else is reserved", so no script may use it.

## Output

- **stderr**: logs, same `[LEVEL] message` format as the scripts, whose stderr is passed through. `--verbose` is forwarded.
- **Colors**: the logs (`ERROR` whole line red, `WARN` whole line yellow, `DEBUG` whole line dim, `INFO` only its green tag, so that routine output stays readable) and the `status` table (bold header, `yes`/`no` of `RUNNING` and `HEALTHY` green/red) are colored, and only when the stream is a terminal. `NO_COLOR` or `TERM=dumb` turns them off; `EASY_CS_AI_COLOR=always|never` overrides the detection. Output that is piped, captured or `--json` is never colored.
- **stdout**: only machine-readable output (`status --json`, forwarded script JSON), except the `status` table, which is the result of the command. With `--json`, tables and plans are replaced by JSON.
- Secrets are never printed, as for the scripts (`proxy nginx show-key` is the explicit exception, forwarded).

## `apply`

```text
easy-cs-ai apply <file|-> [--vm <name>] [--prune] [--dry-run]
```

`--vm <name>` applies one VM of a file that describes several (it is refused without it, see [spec: config](spec-config.md#several-vms)); a file for one machine does not use it. Reads a [configuration file](spec-config.md) and runs the equivalent of `install` for each listed component (in `requires` order), then `add` for each listed model, with the same rollback as `add`. It converges, installs nothing the file does not name, and removes nothing unless `--prune` is given. Exit codes are those of the steps it runs, see [spec: config](spec-config.md#apply) for the semantics, failure and resume.

## `generate`

`generate [--config-only] [parameters…]` hands over to the generator with the remaining arguments, forwarding its streams and exit code. The options and the questions come from `describe`; the rest is in [spec: VM script generator](spec-vm-generator.md). The generator is interactive unless given `--config <file>`, the one exception to the rule that the CLI never prompts: `generate` hands over to it without adding any prompt of its own. The generator produces the layer 3 scripts only (one per VM when the configuration names several, see [spec: two VMs](spec-two-vm.md)): there is none for layer 1, the CLI chains components with `apply`.

## Contract additions

This spec relies on four points that are specified in the [script contract](spec-script-contract.md): `provisioning check <model>` and the `url` printed by `proxy add-upstream` / `chat-interface add-endpoint` (see [Type-specific actions](spec-script-contract.md#type-specific-actions)), `requires` naming a type and the `native` object of `describe` (see [`describe`](spec-script-contract.md#describe)), and `--default` as an option of `install` (see [Parameters](spec-script-contract.md#parameters)).

## Definition of done

- Every command and every row of the dispatch and exit-code tables covered by `bats` tests in `EASY_CS_AI_ROOT` mode, using fake component scripts (success, each exit code, slow, interrupted).
- `add` tested for each rollback row with a fake failing step, and for resume; `remove` tested for each failing step and resume.
- `install` tested with and without `--defaults` (missing requirement, type only, default stack, re-run).
- `uninstall --all` and `remove --all` tested for order (dependents first), resume, a type-scoped run (`uninstall <type> --all`), nothing to remove, leftovers of a failed install (pending manifest only), and the usage errors (`--all` with a name, `--defaults` on `uninstall` or `remove`).
- `exec` tested with fake components: the command and its arguments reach the program untouched (options such as `-t` included), the environment of `native.env`, `--verbose` and `--dry-run` showing the resolved command (and `--dry-run` running nothing), each refusal (no command, no component name, no `native`, not installed, program not found, `--json`), and the old forms (`<type> <name> <tool command>` and `--`) refused with a message that points to `exec`. An action added to the `describe` of a fake script is accepted with no change of the CLI, and one that is not listed is refused with the list of the actions.
- `apply`: see the definition of done of [spec: config](spec-config.md#definition-of-done).
- `shellcheck` clean; `--help` text consistent with this spec.
- Integration test on a fresh VM: `install engine ollama`, `add llama3.2:3b`, `status` healthy, `uninstall`. Round trip for repeated tests: `install --defaults`, `add`, `remove --all`, `uninstall --all`, then the system is back as found (except shared packages).

## Open questions

- Whether `status` should probe in parallel once the number of components grows (sequential and bounded by 15 s per component today).
- Shell completion (bash/zsh) built from `describe`: wanted, not specified.
- Which actions change the machine, and so need root: still a list in the CLI (`CHANGING_ACTIONS`), whereas the actions themselves now come from `describe`. A field per action in `describe` would remove the last list.
