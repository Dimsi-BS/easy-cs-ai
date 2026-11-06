# Spec: the journey, from a need to a running stack

[← Back to docs](README.md)

**Status:** accepted. **Proposed, not implemented**: any number of VMs with optional roles and the editor, and the [configuration format of version 2](spec-config.md#format) (a list of VMs that hold their components, models held by their engine, and a `links` array that says which model is shown in which chat interface, no root `models`), see [spec: several VMs](spec-multi-vm.md); where this spec still speaks of a split in two, it describes what is implemented today. The two ways to walk it exist (see [implementation status](#implementation-status)); the parity test is in `tests/unit/parity.bats`. The VM question and the passes per VM (steps 1, 2 and 4, and what concerns several VMs in 5 and 6) are **implemented**, see [spec: several VMs](spec-multi-vm.md). The [proposal of a proxy](#4-models) for models on an engine that is not `protected` is **implemented** in the one-VM session (`tests/unit/generate.bats`). Still proposed, and applying to one VM as well: the recommendation of a VM that ends with no model ([spec: model fit](spec-model-fit.md#a-stack-with-no-model)).

## Purpose

The product does one thing for a user: it takes them from "I want a stack of inference engine, chat interface and models" to either a **VM script** to run on a new machine or a **change applied** to this one. That path is a sequence of decisions, and it is defined **here, once**.

There are two ways to walk it, and neither is "the AI interface":

| | Interactive session | Programmatic |
| --- | --- | --- |
| Who | A person at a terminal | A program, or an AI agent working for a person |
| How | Questions and answers (`config edit`) | Arguments, a configuration file, `--json` (`catalog`, `host`, `config validate`, `script`, `apply`…) |
| Text of the instructions | The questions themselves | `easy-cs-ai guide`, which prints [`install_scripts/guide.txt`](../install_scripts/guide.txt) |
| Produces | A [configuration](spec-config.md), then the script | The same configuration, then the same script |

Both call the same [capabilities](spec-capabilities.md), validate with the same code, and end on the same artefacts. They differ only by [rendering](spec-rendering.md). There is no second product behind `--json`.

## Rules

1. **One definition.** What the journey asks, in what order, and what it must show is written in this spec, and the reader-facing text of the steps in `guide.txt`, which is the only text `guide` prints. The generator spec, the `guide` text and the session's questions are views of it.
2. **A question is a field.** Every question of the session fills one field of the configuration (or one argument), and every field the journey exposes has a question. A step with no field to carry its answer cannot exist; a new question means a new field, which then shows up in `config schema` and in `--json` without further work.
3. **The user decides.** Nothing is chosen silently: a component is in the result only if the user picked it or accepted a dependency that was proposed. Defaults and ranks are suggestions. A program acting for a person asks that person the same questions the session asks, it does not answer them.
4. **A step holds no logic.** It asks, calls a capability, and shows the document the capability returns. A filter, a margin, a validation rule or a warning is the capability's, so that improving it improves both ways at once.
5. **A missing answer is reported, never filled in.** Without a session, an incomplete configuration is an error (exit 2, with the list of what is missing), not a guess. This is the equivalent, for a program, of the session asking again.

## The steps

| # | The user decides | Capability called | Written to the configuration |
| --- | --- | --- | --- |
| 1 | Which machine the stack is for, and whether another VM follows | `catalog`, `host` | `vms[]` (the name of each VM) |
| 2 | Which component per type, and which dependencies to accept | `catalog`, `config validate` | `components[].type`, `components[].name` |
| 3 | The options of each component | `config schema` | `components[].options` |
| 4 | The order, the models, on which engine (the one that holds them) and in which chat interface they are shown | `provisioning llmfit suggest`, `check`, `plan` | `models[]` of the `engine` components, and `links[]` |
| 5 | Whether the plan and its warnings are acceptable | `config validate` | — |
| 6 | A script to run on a VM, or a change on this machine | `script`, `apply` | — |
| 7 | — (reported to the user) | the result document, `status` | — |

Steps 2 to 4 may be revisited from the summary of step 5 (`c`, `o`, `m` in the session; `m` is offered only in a pass that has an engine, see [spec: several VMs](spec-multi-vm.md#in-the-session)); the dependency check always follows the components. A configuration that exists can be walked again from its summary with the editor (`config edit <file>`, see [spec: several VMs](spec-multi-vm.md#editing)); a program edits the file and validates it again.

### 1. Discover

What can be installed, and what the target is.

- **Capability**: [`catalog`](spec-capabilities.md#catalog) (what is shipped, with ranks and default models) and [`host`](spec-capabilities.md#host) (what this machine is).
- **Session**: reads the catalog itself and shows the components shipped, with the rank 1 pre-selected. It plans for another machine by default (what is installed here is ignored, `--target fresh`). Every VM, the first included, starts with a role (optional) and a name; after each VM it asks whether to add another one, see [spec: several VMs](spec-multi-vm.md#creating); the answers are the components of each VM of the file (`vms[].components`).
- **Program**: reads `catalog --json`, and `host --json` when the stack is for this machine. For another machine it asks the user: `host` says nothing about it. It also asks the user which VMs the stack is made of, and writes `vms` with the components of each; the models then say where they go and where they are shown (step 4). A file always has a `vms` array, even for one machine; the session always asks and writes the name of each VM (the format lets a lone VM have none, see [spec: config](spec-config.md#vms)).

### 2. Components and dependencies

- **Session**: for each type, lists the components shipped, rank 1 pre-selected, and lets the user pick one, or `none`. From `requires` it proposes the missing components (a type means "any of this type") and refuses a selection that cannot be satisfied. A dependency the user refuses sends the session back to the choice.
- **Program**: writes `components` from the catalog, then runs `config validate` and shows the user what it requires; the errors `missing_requirement`, `unresolved_chat_interface`… are the dependency proposals.
- A type with no shipped component is not asked. One component per type is offered; several instances of one component are not expressible on one machine (see [spec: config](spec-config.md#open-questions)).
- **Several VMs**: when the user chose several ([step 1](#1-discover)), the session asks the components and the options once per VM, and the components go into the `components` of that VM; the models belong to the VM of their engine. Each VM may be given a **role** (`engine`, `web`, or `custom`, the default), an aid that restricts the types of the pass and is never written in the file nor required; a `custom` VM is built one component at a time ("Add a proxy? Add an engine?", each followed by its configuration), so that nothing has to be anticipated. A program writes the same `vms`. **The session does not write a VM that cannot work**: a VM ends with at least one component, and with the `engine` or `web` role the component that defines it (an engine, a chat interface) is required and `none` for it is refused with a message and asked again. A file written by hand is not concerned: the validation judges it. See [spec: several VMs](spec-multi-vm.md#roles).

### 3. Options

- **Session**: for each selected component, asks its `describe.options` in the order of the script, with the default and the description, validating before moving on. An option left at its default is not written. A secret is asked as a [source](spec-config.md#secrets). **Only the options that matter for the choices already made are asked, and the required ones are insisted on**: an option that declares `relevant_when` ([script contract](spec-script-contract.md#describe)) is skipped when the value of the option it names is not one of the listed ones (nginx's `--tls-cert` is asked with `--tls provided`, `--tls-email` and `--tls-accept-terms` with `--tls letsencrypt`, none of them with the default `self-signed`), which removes about half of the questions of a default nginx; an option that declares `required_when` and whose condition holds **cannot be left empty**: the question is asked again with the reason ("required with `tls` = `letsencrypt`") until it has a value, since the validation would refuse the file otherwise (`missing_option`). An option with no `required_when` is optional and takes its default on an empty line. A skipped option is not written, and a value already in the file for it (a file edited, written by hand) is kept untouched, as the editor keeps what it does not show. A program is not concerned: it writes the options it wants and the validation judges them.
- **Program**: drafts `options` from `config schema` and the catalog. A secret is never a value: `file`, `env` or `generate`, otherwise `secret_literal`. A secret known in advance is the user's to provide, through `env` or `file`.

### 4. Models

Asked when an engine is selected (with several VMs, in **every pass that selected an engine**: the VM is sized from its own components, and the chat interface that shows a model is chosen afterwards, once every VM exists, see [Where the models are shown](#4-models) below and [spec: several VMs](spec-multi-vm.md#in-the-session)). The user either has a VM imposed (**hardware first**) or has models in mind (**models first**). The detail, the actions and the sizing are in [spec: model fit](spec-model-fit.md):

- **Hardware first**: the specs of the VM (RAM, GPU memory, cores) give `suggest`; a model the user names goes through `check`.
- **Models first**: the names give `plan`, which says what VM to ask for, the estimated margin (the sum of what the components of the VM [declare](spec-model-fit.md#declared-resources)) shown apart from the model figure, and which models or components could not be sized. A VM that ends with no model is sized from its components alone, see [a stack with no model](spec-model-fit.md#a-stack-with-no-model).
- llmfit is optional. Without it the user gives the names, and the models are written with `force` and a warning that they are not checked for fit on the VM.
- **The proxy is not optional for a model, nor for a VM of role `engine`.** When the models of a VM are named, or when the VM has the `engine` role of a [several-VM session](spec-multi-vm.md#creating) (even with no model: the VMs that reach the engine do so through it), and its engine is not `protected` while no proxy is in that VM's components, the session proposes one before the summary, as it proposes a missing dependency at [step 2](#2-components-and-dependencies): `<model> needs a proxy to be reached from outside the VM (the engine listens on the loopback only). Add <proxy>? (y/n)`, default `y`, the proxy being the rank 1 one shipped (with no model named, the message names the engine instead of a model: `Other VMs reach <engine> through a proxy (it listens on the loopback only). Add <proxy>? (y/n)`). `y` adds it to the components of that VM and asks its options ([step 3](#3-options)); in a one-VM session or a `custom` pass `n` takes the models of that engine out of the list, with a message, and the step goes on as for a VM with no model; in a pass of role `engine`, with or without a model, `n` is not an outcome the session writes, since the linked VMs could not reach the engine: it sends the session back to the choice of the components of that pass, as a refused dependency does at [step 2](#2-components-and-dependencies). A `custom` pass has no such proposal at that point: the proxy is proposed **when the models are shown in a chat interface of another VM** (see [spec: several VMs](spec-multi-vm.md#roles)); a model needs it, and a refusal leaves the `missing_requirement` of the model, which blocks the write. A package that ships no proxy proposes nothing, and the validation says why. The question is asked again whenever the step ends with that situation, so a proxy removed by redoing the components is proposed again. A program does not get the question: it reads `missing_requirement` from `config validate` and asks the user (see [what a model needs](spec-config.md#what-a-model-needs)).
- Each model is written **in the `models` of the engine that holds it** (the engine of the pass), as one instance of a model: there is no engine to name or to resolve. Where it is shown is asked at the end, see below. The model holds no pointer to a chat interface: where it is shown is a [link](spec-config.md#links), two [references](spec-config.md#references) (`vm_ref`, `component_ref`, and `model_ref` for the model) that the session writes **complete**, whatever the number of VMs (the `name` of the VM it asked, and of the engine and of the chat interface, proposing the implementation); a program writes them complete too, since nothing is deduced, otherwise `config validate` says why (`missing_key`, `unknown_vm`, `unresolved_engine`, `unresolved_chat_interface`…).
- **Where the models are shown.** At the end of the session, **model by model** in the order of the file, the session asks in which chat interface (of which VM) the model is shown, and writes the answer as an entry of `links` (one per model shown), see [spec: config](spec-config.md#links) and [spec: several VMs](spec-multi-vm.md#creating). A chat interface of the engine's own VM is the wiring of `add`; one of another VM is the link between two machines, finished by hand. It is always asked when the configuration has a model and a chat interface, never deduced from the layout, and the file records the answer either way (a link written, or none): with **one** VM that has an engine with a model and a chat interface, it is the confirmation of the link, a yes or no with the same default (`y`). A program writes the `links` and the user decides them like any other field. The model holds no pointer to a chat interface: the link is written apart, after the inventory, and can be read from either end.
- The specs, verdicts and recommendation are **not** stored in the configuration, see [spec: model fit](spec-model-fit.md#model-fit-for-a-machine-that-is-not-this-one).

### 5. Validate, show, confirm

- **Capability**: [`config validate`](spec-capabilities.md#config-validate), the code of `apply` before any side effect. It returns every problem at once, the plan, and the warnings of the options whose effective value matches their `warn` entry. It also returns the engine of each model and the links as resolved and, for the links whose chat interface is on another VM than the model's engine, the [next steps](spec-multi-vm.md#next-steps) that the user does by hand, so both ways show them from the same document.
- **Session**: loops on invalid input, then prints the summary: components in install order, options (secrets masked), models, platforms, the recommended VM when computed, and **every warning** (an open registration, models not checked…). The user confirms (`y`), cancels (`n`) or goes back to a step. End of input cancels, with exit 0 and nothing written.
- **Program**: fixes the `errors` by their `path` and `code` until `ok`, then shows the user the `plan` and **every `warning`**, and gets a yes before going on.
- In both, the warnings are read **before** anything is created or changed.

### 6. Produce

Two outcomes, the user picks:

- **A script** for a new VM: `script <file>`, from the configuration that steps 1 to 5 produced (`config edit`, a session; or a file written by a program), with the [package source](spec-vm-generator.md#package-source). The user reviews it and runs it on the VM. The configuration is opened again with `config edit <file>`; saving it does not regenerate the scripts, `script` does. With several VMs there is one script per VM, and after them the [next steps](spec-multi-vm.md#next-steps) that the user still has to do by hand.
- **A change on this machine**: `sudo easy-cs-ai apply <file>`. It changes the machine, so a program does it only with the explicit agreement of the user.

### 7. Report

- **Capability**: the [result document](spec-capabilities.md#result-of-the-changing-commands) of the changing commands and `status`.
- **Session and program**: tell the user in plain words what happened. A failure is reported with its `message` and `failed_step`. A second `apply` resumes (see [spec: config](spec-config.md#failure-and-resume)); it is not retried blindly.

## What a program never does on its own

Taken from the same principle as rule 3, for whoever acts on a user's behalf (a person typing the command is their own authority):

- run `uninstall`, `remove`, `apply --prune` or `--purge`, unless the user asked for it;
- run `component proxy nginx show-key`, which prints a secret, or `exec`, which runs any command of a component's program outside the state, the lock and the journal (`ollama rm`, `docker compose down -v`), unless the user asked for that command;
- run `apply` on this machine, or install llmfit, without the user's agreement;
- write a secret as a value, in a file or on a command line.

## Evolving the journey

A change request falls into one of three places, and only that one needs touching:

| The change is | Where it goes | What follows without more work |
| --- | --- | --- |
| A new data, rule, check or warning | The capability ([spec: capabilities](spec-capabilities.md), [model fit](spec-model-fit.md)) | Both renderings, since both show its document |
| A new question, a new step, a new order | This spec, with the field that carries it | `config schema` and `--json` list the field. The session question and the step of `guide.txt` are written by hand |
| A presentation of an answer (wording, layout, a table) | The human rendering ([spec: rendering](spec-rendering.md)) | Nothing: the JSON is a different interface and is not touched |

A change that adds a question but no field, or a rule inside a step, breaks rules 2 and 4 and is a sign it belongs elsewhere.
### Parity

The two ways must give the same result for the same decisions. The test that guarantees it: a scenario played in the session (answers scripted on stdin) and the same decisions written as a configuration file, then `script`, must give the **same configuration**, the **same plan** (`config validate --target fresh --json`) and the **same script**. A change made on one side only fails it.

The decisions of a scenario are written **by hand**, as a program would write them from `catalog --json` and `config schema`, and not produced by the session, otherwise the test would compare the session with itself. Two things are compared as decisions rather than as bytes: an option written `9999` or `"9999"` (values are strings, numbers or booleans, see [spec: config](spec-config.md#format)), and the order of the keys of the configuration. The test also holds that what the session shows is what the plan says (components in order, models, the warnings of the options), that a session asks a question for every option of every shipped component, and that the guide names only commands and options that exist. See [`tests/unit/parity.bats`](../tests/unit/parity.bats) and [its scenarios](../tests/unit/parity/README.md).

## Implementation status

- **Session**: `vm_script/config.sh` and `vm_script/lib/questions.sh`, reached through `easy-cs-ai config edit`; the scripts of step 6 are `vm_script/script.sh`, reached through `easy-cs-ai script`.
- **Programmatic**: `install_scripts/lib/cli-ai.sh` (`catalog`, `host`, `config`, `guide`, the result documents) and `install_scripts/lib/cli-apply.sh` (the validation shared with the session).
- **Guide**: its text is the single file `install_scripts/guide.txt`, shipped in the package (next to `ranks.conf`) and printed as it is by `guide`. It is written by hand for the final reader, so a change to a step updates this spec, the session and `guide.txt` together. `tests/unit/cli_ai.bats` checks that it names the commands and the two orders of the models step, not that it follows this spec.
- **Parity test**: `tests/unit/parity.bats`, with the scenarios in `tests/unit/parity/` (a fake catalog and the shipped scripts). It does not cover an agent: it holds that the configuration the guide leads to is the one the session produces.

## Open questions

- **`guide` versus a packaged skill or prompt.** The CLI is the only channel an agent without the repository has, hence `guide`; an agent platform may also want the same text as a skill. The text lives in one place (the CLI) either way.
- **Where the specs of another machine live.** The journey asks the user for them at the models step and does not store them (see [model fit](spec-model-fit.md#two-orders-one-implementation)). If the same fleet is prepared several times, a place in the configuration may be worth it.
- **Several instances of one component** (two engines, two chat interfaces) on one machine: the format of version 2 can write them (several components of a type in a VM, a free `name`, an array of chat interfaces in a model), the validation refuses them for now and the session has no question for them ([spec: config](spec-config.md#format), [open questions](spec-config.md#open-questions)). On different VMs they are expressible today ([spec: several VMs](spec-multi-vm.md)).
