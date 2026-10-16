# Spec: the journey, from a need to a running stack

[← Back to docs](README.md)

**Status:** accepted. The two ways to walk it exist (see [implementation status](#implementation-status)); the parity test and the generation of `guide` from this spec are not done yet.

## Purpose

The product does one thing for a user: it takes them from "I want a stack of inference engine, chat interface and models" to either a **VM script** to run on a new machine or a **change applied** to this one. That path is a sequence of decisions, and it is defined **here, once**.

There are two ways to walk it, and neither is "the AI interface":

| | Interactive session | Programmatic |
| --- | --- | --- |
| Who | A person at a terminal | A program, or an AI agent working for a person |
| How | Questions and answers (`generate`) | Arguments, a configuration file, `--json` (`catalog`, `host`, `config validate`, `generate --config`, `apply`…) |
| Text of the instructions | The questions themselves | `easy-cs-ai guide` |
| Produces | A [configuration](spec-config.md), then the script | The same configuration, then the same script |

Both call the same [capabilities](spec-capabilities.md), validate with the same code, and end on the same artefacts. They differ only by [rendering](spec-rendering.md). There is no second product behind `--json`.

## Rules

1. **One definition.** What the journey asks, in what order, and what it must show is written in this spec and nowhere else. The generator spec, the `guide` text and the session's questions are views of it.
2. **A question is a field.** Every question of the session fills one field of the configuration (or one argument), and every field the journey exposes has a question. A step with no field to carry its answer cannot exist; a new question means a new field, which then shows up in `config schema` and in `--json` without further work.
3. **The user decides.** Nothing is chosen silently: a component is in the result only if the user picked it or accepted a dependency that was proposed. Defaults and ranks are suggestions. A program acting for a person asks that person the same questions the session asks, it does not answer them.
4. **A step holds no logic.** It asks, calls a capability, and shows the document the capability returns. A filter, a margin, a validation rule or a warning is the capability's, so that improving it improves both ways at once.
5. **A missing answer is reported, never filled in.** Without a session, an incomplete configuration is an error (exit 2, with the list of what is missing), not a guess. This is the equivalent, for a program, of the session asking again.

## The steps

| # | The user decides | Capability called | Written to the configuration |
| --- | --- | --- | --- |
| 1 | Which machine the stack is for | `catalog`, `host` | — |
| 2 | Which component per type, and which dependencies to accept | `catalog`, `config validate` | `components[].type`, `components[].name` |
| 3 | The options of each component | `config schema` | `components[].options` |
| 4 | The order, the models, on which engine and chat interface | `provisioning llmfit suggest`, `check`, `plan` | `models[]` |
| 5 | Whether the plan and its warnings are acceptable | `config validate` | — |
| 6 | A script to run on a VM, or a change on this machine | `generate`, `apply` | — |
| 7 | — (reported to the user) | the result document, `status` | — |

Steps 2 to 4 may be revisited from the summary of step 5 (`c`, `o`, `m` in the session); the dependency check always follows the components.

### 1. Discover

What can be installed, and what the target is.

- **Capability**: [`catalog`](spec-capabilities.md#catalog) (what is shipped, with ranks and default models) and [`host`](spec-capabilities.md#host) (what this machine is).
- **Session**: reads the catalog itself and shows the components shipped, with the rank 1 pre-selected. It plans for another machine by default (what is installed here is ignored, `--target fresh`).
- **Program**: reads `catalog --json`, and `host --json` when the stack is for this machine. For another machine it asks the user: `host` says nothing about it.

### 2. Components and dependencies

- **Session**: for each type, lists the components shipped, rank 1 pre-selected, and lets the user pick one, or `none`. From `requires` it proposes the missing components (a type means "any of this type") and refuses a selection that cannot be satisfied. A dependency the user refuses sends the session back to the choice.
- **Program**: writes `components` from the catalog, then runs `config validate` and shows the user what it requires; the errors `missing_requirement`, `unresolved_engine`… are the dependency proposals.
- A type with no shipped component is not asked. One component per type is offered; several instances of one component are not expressible (see [spec: config](spec-config.md#open-questions)).

### 3. Options

- **Session**: for each selected component, asks its `describe.options` in the order of the script, with the default and the description, validating before moving on. An option left at its default is not written. A secret is asked as a [source](spec-config.md#secrets).
- **Program**: drafts `options` from `config schema` and the catalog. A secret is never a value: `file`, `env` or `generate`, otherwise `secret_literal`. A secret known in advance is the user's to provide, through `env` or `file`.

### 4. Models

Asked when an engine is selected. The user either has a VM imposed (**hardware first**) or has models in mind (**models first**). The detail, the actions and the sizing are in [spec: model fit](spec-model-fit.md):

- **Hardware first**: the specs of the VM (RAM, GPU memory, cores) give `suggest`; a model the user names goes through `check`.
- **Models first**: the names give `plan`, which says what VM to ask for, the estimated margin shown apart from the model figure, and which models could not be sized.
- llmfit is optional. Without it the user gives the names, and the models are written with `force` and a warning that they are not checked for fit on the VM.
- The specs, verdicts and recommendation are an early opinion and are **not** stored in the configuration; the fit is checked again on the target.

### 5. Validate, show, confirm

- **Capability**: [`config validate`](spec-capabilities.md#config-validate), the code of `apply` before any side effect. It returns every problem at once, the plan, and the warnings of the options whose effective value matches their `warn` entry.
- **Session**: loops on invalid input, then prints the summary: components in install order, options (secrets masked), models, platforms, the recommended VM when computed, and **every warning** (an open registration, models not checked…). The user confirms (`y`), cancels (`n`) or goes back to a step. End of input cancels, with exit 0 and nothing written.
- **Program**: fixes the `errors` by their `path` and `code` until `ok`, then shows the user the `plan` and **every `warning`**, and gets a yes before going on.
- In both, the warnings are read **before** anything is created or changed.

### 6. Produce

Two outcomes, the user picks:

- **A script** for a new VM: `generate` (session, or `--config <file>` without one), with the [package source](spec-vm-generator.md#package-source). The user reviews it and runs it on the VM. A configuration can also be kept with `generate --config-only`.
- **A change on this machine**: `sudo easy-cs-ai apply <file>`. It changes the machine, so a program does it only with the explicit agreement of the user.

### 7. Report

- **Capability**: the [result document](spec-capabilities.md#result-of-the-changing-commands) of the changing commands and `status`.
- **Session and program**: tell the user in plain words what happened. A failure is reported with its `message` and `failed_step`. A second `apply` resumes (see [spec: config](spec-config.md#failure-and-resume)); it is not retried blindly.

## What a program never does on its own

Taken from the same principle as rule 3, for whoever acts on a user's behalf (a person typing the command is their own authority):

- run `uninstall`, `remove`, `apply --prune` or `--purge`, unless the user asked for it;
- run `proxy nginx show-key`, which prints a secret, or `exec`, which runs any command of a component's program outside the state, the lock and the journal (`ollama rm`, `docker compose down -v`), unless the user asked for that command;
- run `apply` on this machine, or install llmfit, without the user's agreement;
- write a secret as a value, in a file or on a command line.

## Evolving the journey

A change request falls into one of three places, and only that one needs touching:

| The change is | Where it goes | What follows without more work |
| --- | --- | --- |
| A new data, rule, check or warning | The capability ([spec: capabilities](spec-capabilities.md), [model fit](spec-model-fit.md)) | Both renderings, since both show its document |
| A new question, a new step, a new order | This spec, with the field that carries it | The session asks it, `config schema` lists the field, `guide` describes it |
| A presentation of an answer (wording, layout, a table) | The human rendering ([spec: rendering](spec-rendering.md)) | Nothing: the JSON is a different interface and is not touched |

A change that adds a question but no field, or a rule inside a step, breaks rules 2 and 4 and is a sign it belongs elsewhere.

### Parity

The two ways must give the same result for the same decisions. The test that guarantees it: a scenario played in the session (answers scripted on stdin) and the same decisions written as a configuration file, then `generate --config`, must give the **same configuration**, the **same plan** (`config validate --target fresh --json`) and the **same script**. A change made on one side only fails it.

## Implementation status

- **Session**: `vm_script/generate.sh` and `vm_script/lib/questions.sh`, reached through `easy-cs-ai generate`.
- **Programmatic**: `install_scripts/lib/cli-ai.sh` (`catalog`, `host`, `config`, `guide`, the result documents) and `install_scripts/lib/cli-apply.sh` (the validation shared with the session).
- **Not done**: the parity test above, and a `guide` derived from this spec; its text is written by hand in `cli-ai.sh`, and `tests/unit/cli_ai.bats` checks that it names the commands and the two orders of the models step, not that it follows this spec. Until then, a change to a step must update the session and the `guide` text together.

## Open questions

- **`guide` versus a packaged skill or prompt.** The CLI is the only channel an agent without the repository has, hence `guide`; an agent platform may also want the same text as a skill. The text lives in one place (the CLI) either way.
- **Where the specs of another machine live.** The journey asks the user for them at the models step and does not store them (see [model fit](spec-model-fit.md#two-orders-one-implementation)). If the same fleet is prepared several times, a place in the configuration may be worth it.
- **Several instances of one component** (two engines, two chat interfaces) have no question in the session and no field in the configuration.
