# Spec: several VMs, and the editor of the configuration

[← Back to docs](README.md)

**Status:** proposed, being reworked. This spec generalizes the former "two VMs, the engine and the web interface apart" to **any number of VMs**, adds the **links** between VMs to the configuration, makes the session a **creator and editor** of the configuration, and drops the special case of two VMs (the project is in development: nothing is kept for backward compatibility with it). What was **implemented before this rework** and stays as it is: the `vm` field, the slices, the place of a model, `apply --vm`, `config validate --vm` and what a model needs (see [spec: config](spec-config.md)), the proposal of a proxy ([journey, step 4](spec-journey.md#4-models)), the pass per VM, one script per VM with the `VM:` header, the `scripts` and `next_steps` of the JSON documents, the warnings of the validation, the declared resources of [spec: model fit](spec-model-fit.md), `proxy nginx list-upstreams`, the addresses of the self-signed certificate and `certificate_names`, and `chat-interface librechat add-endpoint` with a key and a certificate. **To do**: the `links` field, the roles and the free number of VMs in the session, the editor (`--edit`), the next steps and warnings computed per link, and the rewrite of the tests and of the integration scenario that assumed two VMs.

## Purpose

Today a stack lives on **one machine** by default: the engine, the proxy and the chat interface share it, and the chat interface reaches the engine on the loopback (see [decision: LibreChat install](decision-librechat-install.md#4-reaching-the-models-from-the-container)). An administrator may want the inference engine on one VM (often the costly one, with a GPU), the web interface on another, small one, a second web interface for another team, a proxy alone, or any other split.

This spec lets one [configuration](spec-config.md) describe **any number of VMs**, lets the [generator](spec-vm-generator.md) **create and edit** it, produce **one script per VM**, and says what the administrator does once the VMs are running. It adds no deployment model: each VM is a stack like today's, and the links between them are made by hand afterwards.

Adding a VM is part of the [journey](spec-journey.md) like any other decision: a person is asked in the session whether to add another VM after each one, a program writes the VMs and their links in the configuration, and both end on the same file. **A configuration with several VMs describes machines that work together**: every VM of it is [linked](spec-config.md#links) to another, and a VM that would stand alone belongs to a configuration of its own. A configuration that exists can be **opened again** in the same session ([the editor](#editing)), to add a VM or change one.

## Principles

1. **One VM stays as it is.** The question of another VM defaults to "n", a configuration with no `vm` is read as today, and the answers that give a one-VM script today give the same script, byte for byte, **apart from the changes below**. Nothing in **this spec** changes the loopback link, the `add` orchestration, the exit codes or the JSON of the one-VM case; the JSON changes only through the last two rows, which come from the specs this one relies on. There is **no other special case**: two VMs are the case N = 2 of the rules below, with no answer, name, text or link of their own. What a one-VM user sees change is this inventory, the only one of this spec (see also [what does not change](#what-does-not-change)):

   | Change | Comes from | Effect on one VM |
   | --- | --- | --- |
   | The question of another VM | this spec, see [creating](#creating) | A file of scripted answers needs one more line at the end of the session (an empty one takes the default `n`) |
   | The proposal of a proxy | the journey ([step 4](spec-journey.md#4-models)) | Only in a session that names a model on an engine that is not `protected` with no proxy on its VM (an engine alone, for instance): one more line at that place (an empty one takes its default `y`), and the script gains the proxy when it is accepted |
   | The sizing text, and a recommendation with no model | [spec: model fit](spec-model-fit.md#declared-resources) | The text of the recommended VM in the summary changes (the figures are those of the [shipped components](spec-model-fit.md#values-of-the-shipped-components)), and a session that names no model gets a recommendation, with the warning that the models come on top when the stack has an engine ([a stack with no model](spec-model-fit.md#a-stack-with-no-model)). The script and the configuration are not concerned |
   | The refusal of a model that cannot finish | [spec: config](spec-config.md#what-a-model-needs) | A file whose model needs a proxy or a provisioning component it does not give is refused by `config validate` and `generate --config` (exit 2), where `apply` kept exit 4 at the model step (it still does); what a session does is in the [same section](spec-config.md#what-a-model-needs) |
   | The `models_not_checked` warning | [spec: model fit](spec-model-fit.md#llmfit-is-optional) | Built by the validation instead of the session's summary: a file with a model written with `force` and no provisioning component gains a `warnings` entry (with its `code`) in `config validate --json` and `generate --json`. The text of the warning and the summary of a session do not change |
2. **One configuration, two optional fields.** A component may name its VM (`components[].vm`, see [spec: config](spec-config.md#several-vms)), and so may a model, which gives it a [place](spec-config.md#where-a-model-goes) with its engine. A top-level `links` array says which VM [reaches](spec-config.md#links) the engine of which other VM. The generator cuts the file into one **slice** per VM; each script embeds only its slice, with no `vm` and no `links`. A VM, and `apply` running on it, never see that another VM exists. `schema_version` stays 1.
3. **The link is finished by the administrator, once the VMs are up.** The address of an engine VM and its API key do not exist when the scripts are generated, so nothing about them goes into a script. The configuration says **who reaches whom** (`links`); the generator tells the administrator what is left to do (see [Next steps](#next-steps)).
4. **No secret travels through a generated script.** The API key is generated on the engine VM, as today (see [Secrets](spec-script-contract.md#secrets)), and read from there on demand with `component proxy nginx show-key`.
5. **Roles help, they never bind.** The session offers [roles](#roles) as shortcuts, and works as well with none. A role is never written in the file and never a rule of the format.

## Roles

A **role** is an aid of the session: it restricts the types a pass asks and proposes what usually goes with them. A person never has to know in advance what a VM will hold: the `custom` role builds it one component at a time. It is **never stored** in the file (like the target specs of the models step, an early opinion), **never required**, and the VM of a file is judged by what it holds, not by a role.

| Role | Types the pass asks | What it adds |
| --- | --- | --- |
| `engine` | `provisioning`, `proxy`, `engine` | The pass must select an engine, and the proxy is proposed even with no model (the VMs that reach the engine do so through it) |
| `web` | `proxy`, `chat-interface` | The pass must select a chat interface |
| `custom` (default) | Every type, **one at a time**: for each, `Add a <type> on <vm>? (y/n) [n]`, and on `y` the choice of the component (rank 1 preselected) and its options, before the next type | Nothing is imposed except that the VM ends with a component (otherwise the walk starts again with a message). The [dependencies](spec-journey.md#2-components-and-dependencies) and the [proxy proposal](spec-journey.md#4-models) are made as in a one-VM session |

- What `engine` and `web` typically hold: `llmfit`, `nginx`, `ollama` (or `vllm`) and the models on an engine VM; `nginx`, `librechat` on a web VM, which comes up with **no model**, its selector empty until the link is made. This is a convention of the session, **not a rule of the format**: any component may be given any VM, and the validation checks each slice as it checks a one-VM file. The rules that are about the links are in [Validation](#validation).
- **Every VM has a name**, asked when the VM is added (default: its role, made unique by a number: `engine`, `web`, `web-2`, `vm-3` for `custom`); names have the shape of [spec: config](spec-config.md#several-vms). The first VM of a session is built as a `custom` one, before the session knows that there will be others, and is named only when another VM is added (default `vm-1`): the roles are offered for the VMs that follow, and in the [editor](#editing). A VM holds at least one component: with `engine` or `web` the component that defines the role is required and `none` for it is refused and asked again ([journey, step 2](spec-journey.md#2-components-and-dependencies)); with `custom` nothing is required except that the VM ends with a component. So a `custom` VM may hold an engine and a chat interface (a stack like a one-VM one, which may also be the `vm` of a link), a second engine, or anything a file written by hand allows, as long as it ends [linked](spec-config.md#links).
- Because `custom` imposes no proxy, the session proposes it **when the links are made**: an engine VM that a link targets, whose engine is not `protected`, with no proxy, gets `Other VMs reach <engine> on <vm> through a proxy (it listens on the loopback only). Add <proxy>? (y/n)`, default `y`, and `y` adds it and asks its options. A refusal is allowed, and the [`engine_unreachable`](#validation) error then blocks the write until the person adds the proxy (`e <vm>`), unlinks the VM (`l`) or removes it.
- The engine stays on its loopback and the proxy exposes it, as `add` already does for any engine that is not `protected` (none of the shipped ones is). The proxy is therefore **required** on an engine VM as soon as it holds a model, see [what a model needs](spec-config.md#what-a-model-needs). Nothing new on the engine side: its slice is the configuration an administrator who wants an API-only VM writes today. A model is not linked to a chat interface of another VM by `chat_interface`, see [spec: config](spec-config.md#several-vms): that is the job of a [link](spec-config.md#links).
- LibreChat `requires` nginx (for its web site), not an engine, so a slice with a chat interface and no engine validates and installs on its own.
- Several VMs may carry an nginx, each with its own options (server name, certificate strategy, ports): that is why the file may hold an entry per component **and per VM**.
- There is no limit to the number of VMs, in the session, the format or the generator.

## Validation

The validation of [spec: config](spec-config.md#validation) applies, with the file cut into slices; its errors for `vm` and for [`links`](spec-config.md#links) (among them `unlinked_vm`: in a file that names several VMs, each VM is in a link) are listed there. This spec adds one **error** and one **warning**, shown by `config validate`, by the summary of the session, and by `generate --config`; the warning does not change the exit code. A **link** is an entry of `links`; a **steps link** is a link whose engine VM has a proxy, an engine that is not `protected` and at least one model (the [next steps](#next-steps) are given for these):

| Code | Kind | When | Message (in substance) |
| --- | --- | --- | --- |
| `engine_unreachable` | **error** (exit 2) | An engine that is not `protected` is on a VM with no proxy, **holds no model in the file**, and that VM is the `engine_vm` of a link | The engine listens on the loopback of its VM and nothing exposes it: the chat interface of the linked VM cannot reach it. Add a proxy to that VM, or remove the link |
| `engine_address_unknown` | warning | The VM is the `engine_vm` of a steps link, the `server-name` option of its proxy is **not written in the file**, and its effective `tls` is `self-signed` (the default; `letsencrypt` already needs an explicit `server-name`, and a `provided` certificate is the customer's) | The address of the engine VM is not known yet: its proxy will take the host name of the machine as its server name, and a self-signed certificate will also cover the addresses the machine has when it is installed. The linked VM must reach the engine VM by one of those names or addresses. If none does, re-run `install proxy nginx` on the engine VM with the options it was installed with and `--server-name <name or address>` (an option left out returns to its default), before linking the models |

The warning exists because the address of a VM is usually not known when its script is generated (it is given by the cloud when the VM is created), so the session cannot ask for it and must not leave the administrator to find the problem at step 4. It states the situation and what covers it ([the certificate](#the-certificate-of-the-engine-vm)) **before** anything is created, and the fix (the re-run) is also in the [next steps](#next-steps). A `server-name` written in the file, a name or an address, removes the warning, and so does a `tls` that is not `self-signed`. It never comes with `engine_unreachable` (that one needs no model, this one needs a model and a proxy).

An engine that is not `protected`, **holds a model** and has no proxy on its VM is the **error** `missing_requirement` ([what a model needs](spec-config.md#what-a-model-needs)), linked or not; `engine_unreachable` is what remains for a **linked** engine VM that holds no model yet. It never comes with `missing_requirement` for the same engine. An engine VM that **no link targets** and holds no model needs no proxy and is valid (its models, and its proxy, may come later). The two are errors only where a link needs the engine: a linked engine VM that cannot be reached is a configuration that cannot work.

The error has the shape of the other errors and the warning that of the other warnings of [spec: capabilities](spec-capabilities.md#config-validate), each with a `code` and the `vm` it is about. Both are computed on the whole file, so a validation of one slice (`--vm`) gives neither. A VM that no link reaches gets neither (and is the error `unlinked_vm` if it is in no link at all).

**Where the session shows it.** The warning is about the link between VMs, so it can only be computed once the VMs and the links exist: a pass cannot give it. The **summary of the whole configuration** ([creating](#creating), [editing](#editing)) lists the errors and warnings that **need several VMs to be computed** (today `engine_unreachable` and `engine_address_unknown`, both about an engine VM), each naming its `vm`. Every other warning (the `warn` of an option, `models_not_checked`) is judged inside one VM and shown **once**, in the summary of the pass of that VM, and not repeated in the summary of the whole configuration. A session avoids `engine_unreachable` by proposing the proxy (the `engine` role in its pass, any VM when the links are made, see [roles](#roles)); only a person who refuses it sees the error, and the summary says the fix. `engine_address_unknown` can come from any session, since the address does not exist yet: it is not blocking and its text says the fix.

## In the session

The session is the [journey](spec-journey.md) walked once per VM. It writes one configuration, whose components carry their `vm` and which carries the `links`. It **creates** a configuration, or **edits** one that exists.

### Creating

The session starts with the **first VM** exactly as a one-VM session does: no question about a number of VMs, the steps 2 to 5 over every type, the same summary. The question of another VM comes after it.

- After the confirmation (`y`) of the summary of a VM, the session asks, when the package ships at least one engine and one chat interface (otherwise it is not asked):

  ```text
  Add another VM? (y/n) [n]
  ```

  Answered `n` (the default) with one VM, the session ends as before: no `vm`, no `links`, the same script. The effect on the scripted answers of the tests and of the [parity scenarios](../tests/unit/parity/README.md) is in [principle 1](#principles).
- Answered `y`, the VM just built is **named** (default `vm-1`) and gets its `vm`, then the session builds the next one: its [role](#roles) (`engine`, `web` or `custom`, default `custom`), its **name**, and a pass, which is the session as it is today restricted to the types of the role. Every component written gets the `vm` of its pass, and so does every model, with the `engine` it was asked for ([where a model goes](spec-config.md#where-a-model-goes)). Each pass ends on its own [summary](spec-journey.md#5-validate-show-confirm) (components in install order, options, models, platforms, warnings, and the recommended VM of the pass when it is computed), with the same confirm / redo (`c`, `o`, `m`) / cancel, and then the question of another VM again, so a stack of any size is built one VM at a time. Cancelling at any point cancels everything: nothing is written, exit 0.
- **The models step belongs to every pass that selected an engine**, with the same two orders and the same sizing; `m` is offered only in such a pass. The [proposal of a proxy](spec-journey.md#4-models) is made in every pass of role `engine` (with or without a model) and, for the other roles, only when it names a model on an engine that is not `protected` with no proxy on its VM. A refusal in a pass of role `engine` goes back to the components of that pass.
- The recommended VM of each pass comes from `provisioning llmfit plan`, called with the components **of that VM** (`--component` for each), so an engine VM carries no share for an interface that is not on it. A pass with models, named in the `m` order ([choosing models](spec-model-fit.md#choosing-models-in-a-session); in the `h` order the VM is imposed and there is no recommendation for models), adds them, each as `<model>@<engine>` with the engine of its [place](spec-config.md#where-a-model-goes), and a pass that ends with no model is sized as [a stack with no model](spec-model-fit.md#a-stack-with-no-model) (the cores of the `h` order belong to the VM they were given for, see [choosing models](spec-model-fit.md#choosing-models-in-a-session)). How `plan` counts the models of an engine VM is in [models loaded together](spec-model-fit.md#models-loaded-together).
- **When the answer to "another VM" is `n` and there are several VMs**, the session asks the **links**. For every VM with a chat interface that has at least one other VM with an engine:

  ```text
  Which VMs hold the engines whose models <web_vm> lists? (names separated by spaces, none) [<default>]
  ```

  The default is the other VMs that have an engine, or `none` when `<web_vm>` has an engine of its own. An answer naming a VM with no engine, or `<web_vm>` itself, is refused and asked again. The question is always asked: nothing is linked silently ([rule 3 of the journey](spec-journey.md#rules)), and one Enter takes the usual answer. The links go to the `links` array.
- The session then shows the **summary of the whole configuration**, the one of the [editor](#editing): VMs, components, models, links and **every warning**, with the editor's commands. A VM that is in no link makes the [`unlinked_vm`](spec-config.md#links) error, shown there, and nothing is written while it stands: the person links it (`l`), edits it (`e`) or removes it (`r`). `y` writes the configuration (and the scripts, as `generate` does); cancel and the end of input write nothing, exit 0.
- The [package source](spec-vm-generator.md#package-source) is asked once and is the same for every script.

### Editing

```text
generate --edit <file> [--output <path>] [package options]
```

Opens an existing configuration in the same session. **Saving the configuration regenerates its scripts**: the configuration and the scripts of its VMs are written together, so that the scripts on disk never describe another configuration than the file next to them. `--edit` excludes `--config-only` and `--config` (exit 2): a configuration saved with no scripts would leave the old ones stale. The file is written back to itself; `--output` names the scripts, as for any generation (see [what is written](#what-is-written)).

- **Loading.** The file is read and validated like `config validate --target fresh`. A file that is not JSON, or cannot be read, and a missing file are exit 2 (a creation is `generate` with no `--edit`). A file with validation errors **opens anyway** (fixing it is what the editor is for): the errors are shown in the summary, numbered, each with its path, its code and the command that fixes it, and **nothing is written while one remains**.
- **The summary of the whole configuration** is the first screen: VMs in order, with their components, options (secrets masked), models, links, platforms, and **every warning**. Its prompt:

  ```text
  a add a VM   e <vm> edit   m <vm> models   l links   n <vm> rename   r <vm> remove   f fix   y write   q quit
  ```

- `a` adds a VM: its role (optional, `custom` by default) and its name, then its pass, then its links. `e <vm>` redoes the pass of an existing VM **from its current content** (components preselected, options and models offered as defaults, as the specs of the models step are offered again when it is redone); it never imposes a role, the VM is edited as `custom`. `m <vm>` redoes its models only. `l` redoes the links (each chat-interface VM, as above, with the current ones as defaults). `n <vm>` renames a VM in its components, its models and its links. `r <vm>` removes a VM with its components, its models and the links that name it, after telling what goes; the last VM cannot be removed.
- **Fixing errors.** The editor is where errors are corrected, whatever their origin (a file written by hand, a program, a change just made in the editor). `f` walks the errors one at a time and **re-asks the question of the field at the path of the error** ([rule 2 of the journey](spec-journey.md#rules): every field has a question): an option outside its values asks that option again with its default, a `missing_requirement` proposes the component that is missing (`Add <proxy>? (y/n)`, then its options), a model that resolves to no engine asks its place again, a link to an unknown VM asks the links again. The cases with no question to re-ask are proposed as a choice: `unlinked_vm` and `engine_unreachable` offer to link the VM (`l`), to add the proxy (`e <vm>`) or to remove the VM (`r`) or the link; an entry the CLI does not know (`unknown_key`, `unknown_component`, `unknown_option`) offers to remove it. Each fix is validated at once and the list is shown again, so a person goes from the first error to `ok` without writing any JSON. A change that creates an error does the same: **removing a VM** lists the VMs left in no link and offers to link, edit or remove each of them, and the same for a rename, a removal of a component or of a model.
- **A one-VM file** (no `vm`) is opened as one VM with no name, which `a` handles: the session asks the name of the existing machine (default `vm-1`, as in [creating](#creating)) and writes the `vm` on all its components and models, since `vm` is all or none ([spec: config](spec-config.md#several-vms)). **Removing down to one VM** asks whether to keep the `vm` fields (one name) or to drop them together with the links (a one-VM file); default: drop.
- **The editor never drops what it does not show.** The session offers one component per type per VM; entries it does not present (a second engine on a VM, an option it has no question for, a model of another place) are kept as they are, and so is a `default` it does not touch.
- **Writing.** `y` validates again, asks the [package source](spec-vm-generator.md#package-source) (given as options, it is not asked), then generates the scripts of every VM of the file exactly as `generate --config <file>` would, and writes **everything or nothing**: the configuration (a temporary file in the same directory, then rename, the mode kept) and all the scripts; if one cannot be written, none is kept and the file is unchanged. The next steps are printed as after any generation. With `--dry-run` every result goes to stderr and nothing is written. `q`, cancel or the end of input leave the file and the scripts untouched, exit 0.
- **Stale scripts.** Removing or renaming a VM leaves, next to the new scripts, the script it had under its old name. The editor never deletes a file: after writing, it lists the files of the pattern of the scripts (`<output>-*.<extension>`) that no VM of the file produces any more, so that the person removes them.
- **A new package version.** Regenerating pins the version of the CLI that runs the editor (the default `--package-version`), like any generation: a script is a snapshot, and editing a configuration upgrades the scripts with it. The summary says which version they will pin.
- The editor changes nothing on the machine and needs no root, like the rest of the generator.

### What is written

| Mode | One VM | Several VMs |
| --- | --- | --- |
| Script | `./easy-cs-ai-vm.sh` | `./easy-cs-ai-vm-<name>.sh`, one per VM |
| `--config-only` | `./easy-cs-ai.json` | `./easy-cs-ai.json`, **one file**, with the `vm` fields and `links` |
| `--edit <file>` | the file, **and** `./easy-cs-ai-vm.sh` | the file, **and** one script per VM, written together |

- With `--output <path>`, the VM name is inserted before the extension of each script: `--output vm.sh` gives `vm-engine.sh` and `vm-web.sh`. With `--config-only`, `--output` names the one file; with `--edit`, it names the scripts and the file is the one edited.
- The scripts are written together: if one cannot be written, none is kept.
- `--dry-run` runs the whole session and prints every result to stderr.
- The header of each script gains one line, `VM: <name> (<rank> of <N>)`, so that a script found on a VM says which side of a set it is. A file with no `vm` gives no such line (for a file that names one VM only, see [spec: config](spec-config.md#several-vms)).
- The size warning (32 KB) applies to each script.

## For a program

The same file, written in one go: a program (or an agent working for a person) writes the configuration with the `vm` of each component and the `links`, validates it with `config validate <file> --target fresh` (which cuts it into slices and checks each; the default target `this` is one machine and needs `--vm`, see [spec: capabilities](spec-capabilities.md#config-validate)), then runs `generate --config <file>`, which gives the same scripts the session does. A program that **edits** a file edits the JSON and validates it again: the [editor](#editing) is its rendering for a person. There is no other path and no other flag: the answers to the VM question and to the links question **are** the `vm` fields and `links`, so that [rule 2 of the journey](spec-journey.md#rules) holds without exception, and `config schema` lists the fields. The role is an early opinion and has no field.

The documents of `generate --config --json` and `config validate --json` for several VMs (`scripts`, `plan.links`, `next_steps`, the warnings, what a validation of one slice gives) are defined in [spec: capabilities](spec-capabilities.md#commands) and [`config validate`](spec-capabilities.md#config-validate); the content of `next_steps` is [below](#next-steps).

The journey text of [`guide.txt`](../install_scripts/guide.txt) tells an agent to ask the user which VMs the stack is made of (each linked to another), to give the `vm` fields and the `links`, and to edit a file by validating it again; a test checks that it names the same commands as the next steps.

## Next steps

When the file has **at least one link**, the validation computes the list of what remains for the administrator (see [Where they are computed](#where-they-are-computed)). After the scripts are written, the generator prints it on stderr (not asked to confirm), and with `--json` it is the array `next_steps`. One rule for every number of VMs and of links, with no text of its own for two VMs:

- **Step 1** is always there: "Run each script as root on its VM, the engine VMs first." when there is at least one steps link (the order only matters for the links described below), else "Run each script as root on its VM." A file with no link gives step 1 alone, in its second wording.
- For each **engine VM** that is the `engine_vm` of at least one steps link (in the order of the file): **step 2**, read the API key, the URL of each model and the names and addresses its certificate covers; and **step 3**, let the linked VMs reach it on the HTTPS port of its proxy (443 unless you set `--port`): firewall, security group.
- For each **steps link**: **step 4**, link each model of the engine VM from the VM that holds the chat interface, with `add-endpoint`.
- A link that is not a steps link (no proxy on its engine VM, a `protected` engine, no model: `protected` engines enforce HTTPS and their key themselves and `add` does not put them behind the proxy, so `list-upstreams` would be empty; see the [open questions](#open-questions)) gives no step: the warnings say what to fix, and the models that come later are linked by hand with the `add-endpoint` of the contract.

For a person the text is the following, here for a link `web → engine` ([who writes which lines](#rules-for-the-text)):

```text
2 scripts written, one per VM:
  ./easy-cs-ai-vm-engine.sh   VM engine  (<the components of that VM>)
  ./easy-cs-ai-vm-web.sh   VM web  (<the components of that VM>)

What is left to do once the VMs are up:
  1. Run each script as root on its VM, the engine VMs first.
  2. On the engine VM engine, read the API key, the URL of each model and the
     names and addresses its certificate covers:
       sudo easy-cs-ai component proxy nginx show-key
       easy-cs-ai component proxy nginx list-upstreams
       easy-cs-ai component proxy nginx status          (certificate_names)
  3. Let the VM web reach the VM engine on the HTTPS port of its proxy
     (443 unless you set --port): firewall, security group.
  4. On the VM web, link each model of the VM engine:
       sudo easy-cs-ai component chat-interface librechat add-endpoint <engine>-<model> <url> \
         --model <model> --api-key-file <file>
     <url> is the one read in step 2, <file> holds the key (mode 0600, or - for
     stdin), and the endpoint name is suggested unique on the VM (a chat
     interface may link several engine VMs).
     With the default self-signed certificate, copy the certificate of the
     engine VM (/etc/easy-cs-ai/nginx/server.crt) to the VM web and add
     --ca-file <file>. The host in <url> must be one the certificate covers
     (certificate_names, step 2): the server name printed by list-upstreams,
     or, when no server name was given, an address of the engine VM, which
     you put in place of the host. If the VM web can reach neither, or the
     address changed since the proxy was installed, re-run on the engine VM
       sudo easy-cs-ai install proxy nginx <the options it was installed with> \
         --server-name <name or address>
     (an option left out returns to its default) which renews a self-signed
     certificate (copy it again), then read step 2 again.
Until step 4 is done, the model list of the chat interface stays empty.
```

With several links the steps are numbered in order, and there is one step 2 and one step 3 per engine VM and one step 4 per link, each naming its VMs. With a single step (no steps link), the person's text is the title and `  1. Run each script as root on its VM.`, with no closing line, and `next_steps` is `[ "Run each script as root on its VM." ]`.

Rules for the text:

- **Fixed text, filled with what the configuration says.** The component names, the VM names and the models are those of the file (one `add-endpoint` line per model, with its `--model`). The address, the port, the URL and the files stay placeholders: they do not exist yet.
- **The text is the validation's, the commands are the contract's.** It never invents an action or an option: a bats test checks that every action and option named in the text is in the `describe` of the script it names (`actions` of nginx, `action_options` of the LibreChat script, see [Contract additions](#contract-additions)). The list is given only by a package whose scripts have them, so the CLI never gives a command that fails.
- <a id="rules-for-the-text"></a>**Who writes which lines.** The heading (`<N> scripts written…` and the file of each VM) is the **generator's own**: it names the files it wrote, which the validation cannot know (`--output` changes them, and `config validate` writes nothing), and it is never part of `next_steps`. The steps are the validation's and what `next_steps` holds, **one string per step** (a step with commands is one multi-line string, with no numbering in it and no file name of a script: step 1 says "each script", not its path). The title `What is left to do once the VMs are up:`, the numbering and the closing line (when there are several steps) are added by the rendering of the validation, which `generate` and `config validate` share, from the same array: what a person reads and the strings of `next_steps` are the same text in the same order.
- With `--config-only`, no script is produced: the generator prints one line naming the file written instead of the list. `--json` needs `--config`, which excludes `--config-only`, so this line is never in a `next_steps`.
- With one VM, or a file that names one VM only ([spec: config](spec-config.md#several-vms)), nothing is printed: for no `vm` the output is today's.

### Where they are computed

The list is computed by the validation of [spec: capabilities](spec-capabilities.md#config-validate), in the same place as the warnings, from the file (its `links` included) and the `describe` of the shipped scripts: nothing of the machine, and no script written. The condition, the text and the models filled in are a rule of the capability, not of the generator ([rule 4](spec-journey.md#rules)), so improving them improves both ways at once: `generate` computes nothing of the list, it prints its own heading, then the list after writing the scripts, and puts it in its `--json`; `config validate --json` returns it too, so a program can show it before generating. `guide.txt` carries the procedure for a reader that is a model. It is written by hand, not generated, and a test keeps it in step with the list (see [Definition of done](#definition-of-done)).

## Contract additions

Two actions change, and a detail of `install` and `status` of the nginx proxy is added (see [The certificate of the engine VM](#the-certificate-of-the-engine-vm)). The existing calls behave exactly as today.

### `proxy nginx list-upstreams`

```text
component proxy nginx list-upstreams
```

Prints the models the proxy fronts, each with the URL an external client uses, as a JSON array on stdout:

```json
[ { "name": "ollama-llama3.2-3b", "url": "https://llm.example.org/ollama-llama3.2-3b/v1" } ]
```

- The `url` is what `add-upstream` printed: the OpenAI base URL built from the server name and the port of the install (no port when it is 443). The state keeps the internal URL of the engine, which no other machine can use, so this action is how the administrator gets the URL to give to `add-endpoint`.
- Read-only: no root, no lock, not journaled, like `list-models`. `[]` when the proxy fronts nothing, exit 4 when it is not installed. It reads the state, so it answers whether the proxy is healthy or not.
- It never prints the API key: `show-key` stays the only action that prints a secret.
- It is an action of the type `proxy` ([contract](spec-script-contract.md#type-specific-actions)), declared in the `actions` of the `describe`, so another proxy component offers it too.

### `chat-interface librechat add-endpoint`

Calls without the new options behave exactly as today: `apiKey: "unused"`, the system trust store.

```text
component chat-interface librechat add-endpoint <name> <url> [--model <model>] [--api-key-file <path|->] [--ca-file <path>]
```

| Option | Meaning |
| --- | --- |
| `--api-key-file <path>` | The API key the endpoint expects. A file of mode `0600` or stricter, or `-` for stdin, never on the command line (see [Secrets](spec-script-contract.md#secrets)). Without it, the placeholder key of the local link |
| `--ca-file <path>` | PEM certificate (or CA) the endpoint is verified against, for an engine VM whose proxy uses a self-signed or private-CA certificate. Without it, the system trust store. Verification is never turned off |

- **The key is stored as a secret**: in a file of mode `0600` owned by root under `/etc/easy-cs-ai/secrets/`, referenced by the api container through its environment file, and **never written in `librechat.yaml`**, in the state, in the logs or in `--dry-run`. The path goes in the state `secrets`, the value nowhere. It is **kept by `uninstall` and removed only with `--purge`**, like the other secrets of LibreChat ([script contract](spec-script-contract.md#uninstall)); `remove-endpoint` removes it at once.
- **The certificate is public**: copied to `/etc/easy-cs-ai/librechat/`, mounted read-only in the api container and trusted there. The endpoints share one bundle, rebuilt from the certificates of all of them, since the container takes one file. The certificates and the bundle are recorded in the state `files` when they are written, so `uninstall` always removes them (and the `librechat/` directory with them when it is empty).
- The two options, and the existing `--model`, are declared under `action_options` of `add-endpoint` in `describe` (they are not options of the configuration), so a program can discover them. The [next steps](#next-steps) name `--model`, and the test that checks their commands against the `describe` needs it declared.
- Like today, the action recreates only the `api` container, and only when the rendered files changed. It is idempotent: the same arguments change nothing, a new key or certificate replaces the old one. `remove-endpoint` removes the entry, its key file and its share of the bundle.
- A remote endpoint is recorded in the state `endpoints` like a local one (`name`, `url`, `model`), with the key file in `secrets`.
- `easy-cs-ai add` never passes these options: it links models of an engine of the same machine. The remote link is made by hand, with the component action.
- **Checked on 2026-10-16** (LibreChat 0.8.7, the image pinned by digest): the key of a custom endpoint may be an environment variable reference in `librechat.yaml` (`apiKey: '${NAME}'`, which the LibreChat documentation recommends over a literal), and `NODE_EXTRA_CA_CERTS` is honoured by the Node of the image (v24.16.0): against a self-signed HTTPS server, `fetch`, the `axios` and the `openai` package of the image fail with `DEPTH_ZERO_SELF_SIGNED_CERT` without the variable and succeed with it, the `Authorization` header carrying the key. What is **not** covered is the whole path through LibreChat itself (the `api` container reading the key from its environment file and the bundle mounted read-only): the integration test on two VMs is where it is confirmed. If it fails there, the mechanism changes, not the options above.

### The certificate of the engine VM

Implemented. The address of the engine VM is usually not known when its script is generated, and a self-signed certificate is checked against the host of the URL the linked VM uses ([decision: certificates](decision-nginx-certificates.md#self-signed)). Two additions to `proxy nginx`, neither changing a call that gives a `--server-name`:

- **`install` with `--tls self-signed` and no `--server-name`** adds to the names the certificate covers the **addresses the machine has when the certificate is made**: every address of global scope (not loopback, not link-local), read from the system. The certificate then covers the host name (the default server name), `localhost`, `127.0.0.1` and those addresses, so the administrator can use the name or an address he reads on the VM, without knowing it beforehand. With an explicit `--server-name`, the certificate is what it is today (that name, `localhost`, `127.0.0.1`). `EASY_CS_AI_NGINX_ADDRESSES` (space separated) replaces the detection, for the tests, as `EASY_CS_AI_HOST_IDS` does for the platform.
- **A re-run does not remake the certificate for a new address.** The rule stays the one of the script today, "regenerated only when the certificate no longer covers the server name": a certificate that already covers it is kept, whether the name is the one of the first install or another one it already covers, since the linked VM holds a copy of it and a new one would break the link. An address that changes after the install (DHCP) is not covered: the fix is the re-run with `--server-name` **and the options the proxy was installed with**, since `install` takes an option left out from its default and not from the state (the [contract](spec-script-contract.md#parameters) precedence), which is the last lines of step 4 of the [next steps](#next-steps).
- **`status` of nginx gains `certificate_names`**: the array of the DNS names and addresses of the certificate nginx serves, read from the certificate itself (probed, not copied from the state), `[]` when it cannot be read. It is optional, additive and not a bump of `schema_version`; the other fields of `status` are unchanged. It is what step 2 reads, so the administrator knows which host the linked VM may use.
- `provided` and `letsencrypt` certificates are the customer's or Let's Encrypt's: `install` adds nothing to them, and `certificate_names` shows what they cover. Let's Encrypt needs an explicit `--server-name` already.

## What does not change

- The generated script, the configuration the session writes and the JSON of `generate` and `config validate` of a one-VM stack, byte for byte for the same decisions that give a stack able to finish, apart from the [inventory of principle 1](#principles), which lists the only changes of the one-VM case.
- `apply` on a file with no `vm` and `config validate` on a file that can finish, the configuration format of the one-VM case, `schema_version`, the exit codes of every command (apart from the refusal in that inventory).
- The loopback link and `network_mode: host` of the one-VM stack, and the `add` / `remove` orchestration, which stay the rule when engine and chat interface share a machine.
- Every other script of layer 1, and the slice a VM receives (a plain one-VM file).

## Implementation notes

- `install_scripts/lib/cli-apply.sh`: the `vm` field (shape, all-or-none, uniqueness per VM), the slices, `--vm`; **`links`** (shape, the five errors, never copied into a slice); the validation stays one `jq` program, run per slice, with the paths of the file as written.
- `vm_script/lib/questions.sh`: the question of another VM after each pass, the roles and names, the pass per VM (selection, options and models state per pass; a pass restricts the types it asks, starts from an empty selection or, when editing, from the VM's content), the links question, and the editor loop (summary, `a e m l n r`), which the creation session enters once the last VM is built.
- `vm_script/generate.sh`: `--edit` (not with `--config-only` nor `--config`), one script per slice, the VM in the names and the header, the all-or-nothing write of the scripts **and** of the edited file (atomic), the list of the stale scripts, and the printing of the next steps, which it receives from the validation. The script template is unchanged: one slice, the same template.
- `install_scripts/lib/cli-ai.sh`: `config schema`, `config validate` and `generate --json` for the `vm` field, `links` and the documents above (`plan.links`), and the computation of the next steps and of the warnings per link (the condition, the text, the models filled in).
- `install_scripts/proxy/nginx.sh`: the `list-upstreams` action (JSON on stdout, read-only, listed in `actions` of `describe`), built on the `public_url` the script already has.
- `install_scripts/chat-interface/librechat.sh` and `templates/librechat/`: the two options, the key and certificate files, the compose change for the bundle.
- `install_scripts/guide.txt`: the VMs, the `vm` fields and `links`, the editing of a file, the next steps, and the sizing of each VM (`plan` with `--component` for the components of the VM and `<model>@<engine>` for its models, and the answer for a VM with no model), which the guide names today only as `--chat-interface`. It does not name the keys of `margin_parts`, which [change](spec-model-fit.md#declared-resources) without touching it.
- `install_scripts/provisioning/llmfit.sh`, and the `describe` of the shipped scripts: the sizing is specified in [spec: model fit](spec-model-fit.md#declared-resources) and stays in `plan`, the session holding no figure of its own ([rule 4](spec-journey.md#rules)). It is a prerequisite of the recommendation of a pass, not of the generation of the scripts; a package without `provisioning/llmfit` prints no recommendation ([a stack with no model](spec-model-fit.md#a-stack-with-no-model)).

## Definition of done

- `bats` tests of the configuration: see [spec: config](spec-config.md#definition-of-done) (the `vm` field, `links`, their errors, the slices, `apply --vm`).
- `bats` tests of the session from scratch, answers on stdin (the answers files of the two-VM tests, of the [parity scenarios](../tests/unit/parity/README.md) and of `two-vm.sh` are rewritten for the new questions and for `links`; the one-VM answers gain the line of the question of another VM only, see [principle 1](#principles)): the default answers give the same one-VM script as before (compared with a script generated by the previous behaviour, with its answers plus the empty line of the question); the question absent when no engine or no chat interface is shipped; `y` names the first VM and builds a second one, asking its role and its name, and again after each pass, for any number of VMs; the three roles (`engine` and `web` impose their component and refuse `none`; `custom` walks the types one at a time with `Add a <type>? (y/n)` and then the component and its options, imposes none, and starts the walk again for a VM with no component); models in every pass that has an engine, each with its `vm` and `engine`; the links question, its default, and the refusal of a VM with no engine or of the VM itself; the proposal of a proxy, with its options, for a linked engine VM with none (accepted, and refused, which leaves `engine_unreachable` blocking the write); the summary of the whole configuration with its warnings, and `unlinked_vm` blocking the write until the VM is linked, edited or removed; one script per VM and one configuration with the `vm` fields and `links`; cancel after any pass writes nothing; `m` offered in a pass that has an engine only; `--dry-run` writes nothing; `--output` and `--config-only` names; one script unwritable keeps none; the header line `VM: <name> (<rank> of <N>)`; the errors and warnings of the summary: `engine_unreachable` blocking the write, for a file given with `--config` (exit 2) and for a session where the proxy was refused, in the summary of the whole configuration, with no other warning of an earlier VM repeated there (a `models_not_checked` of an engine VM shows once, in its pass); an engine VM with a model and no proxy refused with `missing_requirement` before any script is written (and the warning not given for it).
- `bats` tests of the editor: opening a valid file; opening a file with errors (shown, not writable); a one-VM file gaining a VM (the `vm` is written everywhere), a VM removed with its models and its links, removal down to one VM (drop or keep), renaming (components, models and links follow), `e` keeps what the session does not show, `m` and `l` redo what they name, `f` fixes each kind of error of a file written by hand (an option out of its values, `missing_requirement`, `unlinked_vm`, `engine_unreachable`, a link to an unknown VM, an unknown key) and ends on `ok`, the removal of a VM offers to fix the VMs it leaves unlinked, `--edit` with `--config-only` or with `--config` is exit 2, a missing file and a file that is not JSON are exit 2, saving writes the file **and** regenerates the scripts of every VM (the same bytes as `generate --config` on the saved file), one script unwritable keeps nothing and leaves the file unchanged, the scripts of a removed or renamed VM are listed as stale and not deleted, the package source asked once (or given), `--output` names the scripts, `--dry-run` writes nothing, and cancel, `q` and end of input leave the file and the scripts byte for byte.
- `bats` tests of the recommended VM of each pass, with a fake llmfit and fake components that declare `resources` (see [spec: model fit](spec-model-fit.md#definition-of-done)): a pass with an engine calls `plan` with its models (as `<model>@<engine>`) and its own components and no share for a chat interface that is not on it; a pass with no engine calls it with its components and no model, and prints the stack with no model, without the `models not included` line, while a VM with an engine and no model has it; the session computes no figure.
- `bats` tests of `generate --config` on a file with `vm`: the scripts, each embedding its slice without `vm` and without `links` (extracted and compared), `--json` with `scripts` and `next_steps`, and the same files for the same decisions as the session.
- Tests of the next steps: computed by the validation from the file and the shipped `describe`s, with no script name in them (the same list whatever `--output` is), the heading of the scripts written being the generator's and not in `next_steps`; only with at least one link; one steps link; two links to one engine VM (steps 2 and 3 once, step 4 twice); two engine VMs for one chat interface (steps 2 and 3 twice, step 4 twice); a chat-interface VM with an engine of its own; step 1 alone (in its wording without "the engine VMs first") when a condition of a steps link is broken, one test per condition: no model on the engine VM (with a proxy: no warning, since the VM can finish and its models come later; without a proxy the file is refused with `engine_unreachable`, so there are no steps at all), a `protected` engine (with or without a proxy, no warning either way); a file with no link; a validation of one slice alone with neither `next_steps` nor `engine_unreachable`; the models of the file filled in; one string per step, with no numbering, title or closing line in a string; the text of a person numbers the strings, with the title before and the closing line after only when there are several; step 4 names the re-run of `install proxy nginx` with the options the proxy was installed with and `--server-name`; the same lines in the text of `generate`, in `generate --json` and in `config validate --json`; only options present in the `describe` of the LibreChat script; and `guide.txt` names the same commands, and the `--component` / `<model>@<engine>` form of `plan`.
- A file that names one VM only (`vm` on every component, one name) behaves as [spec: config](spec-config.md#several-vms) says, one test per effect listed there, and the same file without the `vm` fields gives today's script.
- Parity: a scripted several-VM session, a scripted edit of a file, and the equivalent hand-written file give the same configuration, the same plan (`config validate --target fresh --json`) and the same scripts ([parity test](spec-journey.md#parity)).
- `bats` tests of the proxy proposal ([journey, step 4](spec-journey.md#4-models)): proposed when a model is named on an engine that is not `protected` with no proxy on its VM, in a one-VM session too (an engine alone with a model, whose answers file gains that line; for a package that ships no proxy the validation error shows at the summary instead), and, in a pass of role `engine`, **with no model named**, with the message naming the engine; `y` adds nginx to that VM and asks its options; `n` removes the models of that engine in a one-VM session or a `custom` pass, and in a pass of role `engine`, with a model or not, goes back to the components of that pass; asked again after a redo of the components; not proposed for a `protected` engine, when no proxy is shipped, or in a one-VM session with no model.
- Tests of `engine_address_unknown`, one case per condition of its [row](#validation): given when they all hold (`tls` written or by default); not given with a `server-name` written (a name, or an address), with `tls` `provided` or `letsencrypt`, for an engine VM with no model (that is `engine_unreachable`'s case, never both), for a `protected` engine, for an engine VM that no link reaches, or by a validation of one slice; shown once, in the summary of the last pass; the same warning, with its `vm`, in `config validate --json` and in `generate --config`; no change of exit code.
- `bats` tests of the certificate of the engine VM, in `EASY_CS_AI_ROOT` mode with `EASY_CS_AI_NGINX_ADDRESSES`: no `--server-name` and `--tls self-signed` gives a certificate that covers the host name, `localhost`, `127.0.0.1` and the addresses; an explicit `--server-name` gives the certificate of today (no address added); a re-run with a new address keeps the certificate, a re-run with another name makes a new one; `provided` is untouched; `status` has `certificate_names` read from the served certificate (and `[]` when it cannot be read), with no other field changed. The step 2 and 4 text names only actions and options that are in the `describe` of nginx (`status`, `install`, `--server-name`).
- `bats` tests of `list-upstreams` in `EASY_CS_AI_ROOT` mode: the public URL of each upstream (port 443 and another port, with the server name), `[]` when there is none, exit 4 when the proxy is not installed, no root needed, nothing journaled, the API key never printed, and the action listed in `actions` of `describe`.
- `bats` tests of `add-endpoint` in `EASY_CS_AI_ROOT` mode: without the new options the rendered files are identical to today's; with `--api-key-file` (file, stdin, too-open file refused with exit 2, never in `librechat.yaml`, state, logs or `--dry-run`); with `--ca-file` (copied, bundle rebuilt, an invalid PEM refused); idempotence; `remove-endpoint` removes the key and the certificate; `uninstall` of LibreChat with such an endpoint removes the certificate and the bundle and keeps the key file, and `uninstall --purge` removes the key too.
- Integration test on several VMs (`tests/integration/two-vm.sh` becomes `multi-vm.sh`, see [its README](../tests/integration/README.md)): an engine VM and two web VMs, all scripts run, the links made as in the next steps, a message answered through the api container of each web VM, the scripts run a second time change nothing. The single-VM test stays as it is; two VMs are the case of one web VM, not a test of their own.
- `shellcheck` clean; `--help` of the generator and `guide` consistent with this spec.

## Open questions

- **Sizing of a VM.** Settled by [declared resources](spec-model-fit.md#declared-resources) and [a stack with no model](spec-model-fit.md#a-stack-with-no-model). What stays open is the quality of the figures, which is the calibration of the [estimated margin](spec-model-fit.md#open-questions), not something specific to this spec. The editor re-sizes a VM by listing its components again for `plan`; `plan --config <file> --vm <name>` would read them from the file and becomes worth having.
- **A command to finish the link.** `add-endpoint` by hand is the smallest thing. A higher-level command that reads the key and the certificate from the engine VM would be easier to use, and needs access from one VM to the other that the project does not assume.
- **The models listed by the endpoint.** With `--model`, LibreChat shows that model only (`fetch: false`). Without, it fetches the list of the engine, through the key and the TLS, which adds a network dependency at start. To settle with the first real test.
- **Which models a link covers.** A link covers all the models of its engine VM. A `models` list on the link would let a chat interface show only some; one field more, not needed to start.
- **A declared VM.** A VM exists only by its components, so a VM with none vanishes from the file. A top-level `vms` array (name, a note, later a size or an address) would let the editor keep an empty VM, but it is a second source of truth for the names; not specified.
- **Errors with no fix in the editor.** An error that the editor cannot turn into a question or a choice (a file whose structure is not an object, for instance) is exit 2 at loading, with the message of the validation: the editor opens only what it can show.
- **The name of the entry.** The editor is `generate --edit <file>`, which keeps the generator the only interactive program of the project. The name is not settled: a `config edit` command would read better but breaks "the CLI never prompts, except `generate`"; the behaviour (saving regenerates the scripts) does not depend on it.
- **Showing what an edit changes.** The editor shows the whole summary, not a difference with the file read. A `config diff` capability would serve the editor and a program alike.
- **The address of the engine VM and its certificate.** Settled by the [`engine_address_unknown` warning](#validation), the [addresses added to the self-signed certificate](#the-certificate-of-the-engine-vm) and the last lines of step 4. What stays open: an address that changes after the install is not covered (the re-run with `--server-name` and the same options is the answer, a certificate that follows the address would break the copy the linked VM holds), and a name that no DNS gives to the engine VM, for which the administrator must give an address.
- **Structured next steps.** `next_steps` is an array of strings, one per step, enough for an agent that reads them and for the text. If a program has to act on a step (find the `add-endpoint` command of a model), the entries would become objects (`id`, `vm`, `text`); documents of one VM are not concerned.
- **A `protected` engine on its own VM.** No shipped engine is `protected`, so the next steps give step 1 only for one, whether its VM has a proxy or not. Linking a chat interface to such an engine would need its URL and its key, which the [contract](spec-script-contract.md#describe) does not say how a `protected` engine publishes (a proxy action does not apply, since `add` does not front it). To specify with the first `protected` engine.
- **A link in the other direction**, or between VMs that no chat interface is on (an engine VM that pushes its models somewhere). Not specified: a link is a chat-interface VM reaching an engine VM.
- **The next steps in the header** of each script, so that a script found on a VM says what is left to do. Only the VM line is in this version.
