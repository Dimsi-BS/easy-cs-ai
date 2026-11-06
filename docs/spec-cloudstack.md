# Spec: Apache CloudStack integration, a page for a local AI topology

[← Back to docs](README.md)

**Status:** proposed, specification only. Nothing of this is written: no page, no service, no change to the scripts. **Decision:** the page is a **native section of the CloudStack UI, contributed to `apache/cloudstack`**, not a plugin loaded in an iframe (that would need a web server of its own to host the page, see [search/cloudstack](../search/cloudstack/ui-extension.md)); see [contributing to CloudStack](#contributing-to-cloudstack). **Decision 2:** there is **no server of the project**: the core of the logic is written once, in **Rust**, and compiled both for Linux (the CLI) and to **WebAssembly** (the page); the only thing stored server-side is the **group of VMs and its configuration, in CloudStack itself** (see [the core](#the-core-webassembly) and [where a topology lives](#where-a-topology-lives)). What this needs and does not settle is listed in [open questions](#open-questions); the options that were weighed are in [search/cloudstack: architecture](../search/cloudstack/architecture.md). It builds on specs that are themselves partly proposed (the [`links` and the editor of several VMs](spec-multi-vm.md)); what it needs from them is listed in [what it relies on](#what-it-relies-on). Every statement about Apache CloudStack itself (its API, its UI plugin mechanism, its limits) comes from memory of the documentation and **is to be verified** against the version targeted, see [to verify](#to-verify-on-cloudstack).

## Purpose

An administrator of an Apache CloudStack cloud wants a **local AI** (an inference engine, a chat interface, a reverse proxy, models) running on VMs of that cloud, with no tool to learn beyond the CloudStack UI. This spec adds **one page to the CloudStack UI** (a native section of that UI, contributed upstream) that does, from inside CloudStack, what the project does from a terminal:

1. **Define** a topology of VMs (for instance a `web` VM and an `engine` VM) and what each one holds: the [configuration](spec-config.md), with its [`vm` fields and `links`](spec-multi-vm.md).
2. **Create** the CloudStack resources that topology needs (VMs, disk, network rules, key pair…), each VM provisioned at first boot by the [post-install script](spec-vm-generator.md) the generator produces for it.
3. **Monitor**, specifically, what concerns the use of a local AI: are the engine and the chat interface up, which models are served, are they being used, is the VM big enough for them. The VMs and their disks are of course also listed in the usual pages of CloudStack: the page does not replace them, it adds the view that only this project can give.

The page is **a third rendering of the [journey](spec-journey.md)**, after the interactive session and the `--json` arguments (see [spec: renderings](spec-rendering.md)): it asks the same questions, runs the same core (compiled to WebAssembly instead of for Linux), shows the same documents, and ends on the same configuration and the same scripts. It owns no rule.

> **A page decides how something is shown or asked, never what is true.** The components, options, dependencies, sizing, warnings, next steps and scripts are the capabilities' ([rule 4 of the journey](spec-journey.md#rules)). The page only adds what CloudStack alone knows: which resources exist and what they cost.

## Principles

1. **Same features as the project, one logic.** Choosing components and options, dependencies, models checked and sized with llmfit, VMs and links, validation, warnings, the generated scripts and the next steps all come from **one core**, written once and compiled for the CLI and for the page, see [the core](#the-core-webassembly). The page never recomputes a figure, a margin, a warning or a script, and holds no copy of a rule. A change of a rule is a change of the core, and improves the terminal and the page at once.
2. **No component of the project to install or host.** Everything the page needs runs in the browser or is CloudStack's own. What a cloud operator does to offer the page is to run a CloudStack version that has it.
3. **One file describes the topology.** What the page edits and saves is the configuration of [spec: config](spec-config.md), the same file `script` and `apply` read. A topology made in the page can be downloaded and run from a terminal, and a file written elsewhere can be loaded in the page ([parity](#definition-of-done)).
4. **The user decides, CloudStack is the authority on resources.** Nothing is created, resized or deleted without the person having seen the list and confirmed ([rule 3 of the journey](spec-journey.md#rules)). What exists in CloudStack is read from CloudStack, never from a copy of the page.
5. **Only what it created, and it marks it.** Every resource the page creates carries [tags](#tags); it lists, changes and deletes **only** tagged resources of the topology. A VM, a network or a volume that the user made by hand is never touched, even if it looks related.
6. **No secret in what the page stores or sends.** The user-data of a VM is stored in the CloudStack database and readable from the VM, so no secret goes there ([contract](spec-script-contract.md#secrets)): the keys are generated on the VMs and stay there. The one secret the page handles is the [monitoring key](#reading-the-vms), which reads status only and gives no access to the models.
7. **Nothing the CloudStack permissions do not allow.** The page acts with the session of the user, through the API layer the UI already uses for every other page: a user who cannot deploy a VM cannot do it here. It adds no privilege and no authentication of its own towards CloudStack.
8. **Written the way CloudStack's UI is written.** The section follows the conventions of `ui/` of `apache/cloudstack` (its structure, components, translations, tests, licence), because it is meant to be merged there and kept by that community: nothing in it is specific to this repository except the capabilities it calls.

## What it relies on

| Needs | From | State |
| --- | --- | --- |
| Several VMs in one file, `links`, roles, one script per VM, next steps | [spec: several VMs](spec-multi-vm.md) | `vm` and scripts implemented, `links`, the editor and any number of VMs proposed |
| Sizing of each VM: vCPU, RAM, GPU, disk, "equivalent of a CloudStack compute offering" | [spec: model fit](spec-model-fit.md) (`plan`) | implemented |
| User-data size (32 KB, the default `vm.userdata.max.length`) | [spec: VM generator](spec-vm-generator.md) | the generator already warns |
| Capabilities as `--json` documents | [spec: capabilities](spec-capabilities.md) | implemented in bash and `jq`; **to be moved into the Rust core** ([the core](#the-core-webassembly)) |
| A core written in Rust, as a library that does no input or output, built for Linux and for WebAssembly | New | **proposed here**; reopens [decision: scripting language](decision-scripting-language.md#revisit-when) for that part only |
| `llmfit` usable as a library compiled to WebAssembly | [findings](../search/llmfit.md) | **not checked**; the sizing depends on it |
| Status of the components | [`status`](spec-cli.md#status), `component … status` | implemented |
| Reading the use of the models, from outside the VM | [the status document](#the-status-document) | **new, proposed here** |

## Architecture

```mermaid
graph LR
    User["Administrator\n(browser)"] --> Page["Section of the CloudStack UI\n(topology, create, monitor)"]
    Page --- Core["Core of the project\n(Rust compiled to WebAssembly,\nruns in the page)"]
    Page -->|"CloudStack API\n(session of the UI)"| CS["Apache CloudStack\nmanagement server"]
    CS --- Store["Group of VMs and its configuration\n(stored in CloudStack)"]
    CS --> VM1["VM engine\nproxy + engine"]
    CS --> VM2["VM web\nproxy + chat interface"]
    Page -.->|"HTTPS, status document"| VM1
    Page -.-> VM2
```

Four pieces, each with one job, and **none of them is a server of the project**:

| Piece | Job | Does not |
| --- | --- | --- |
| **The page** (a section of the CloudStack UI) | The screens: edit, confirm, create, watch. Calls CloudStack for resources and the core for everything about the AI, reads the status of the VMs | Hold any rule of the project |
| **The core** (WebAssembly, in the page) | Every capability that is a computation: catalog, schema, validation, sizing, script generation, next steps | Do input or output: no network, no file, no clock |
| **CloudStack** (its API) | Own the resources: offerings, templates, networks, VMs, volumes, tags, metrics, jobs, and the **group of VMs with its configuration** | Know anything about models |
| **The VMs** | Run the stack, and publish their own read-only [status](#the-status-document) | Reach CloudStack |

### The page

A **section of the CloudStack UI**, with its own entry in the navigation next to the compute pages, written in the UI's own framework and built with it, reached by the users whose CloudStack role allows it. It is not a plugin and not an iframe: it uses the session, the API calls, the components, the notifications and the translations of the UI, and looks like its other pages. It lives in `apache/cloudstack` (see [contributing](#contributing-to-cloudstack)), not in this repository. Its three screens are the [topology](#screen-1-topology), the [creation](#screen-2-creation) and the [monitoring](#screen-3-monitoring). The page has a list of the topologies of the account first (their [groups of VMs](#where-a-topology-lives)), with *new topology*, *import a file* and, for each one, *open*, *download the file*, *destroy*.

### The core (WebAssembly)

The capabilities of the CLI are what the page needs, and they are **computations on documents**: a catalog of what can be installed, a configuration, and the result. Written as **pure functions**, `(inputs) → document`, they run the same in the browser and on a machine:

| Capability | Inputs | Document | Described in |
| --- | --- | --- | --- |
| catalog, schema | The snapshot of the `describe` of the shipped scripts | The catalog and the schema | [spec: capabilities](spec-capabilities.md#catalog) |
| validate | The snapshot, the configuration | `plan`, `warnings`, `errors`, `next_steps` | [spec: capabilities](spec-capabilities.md#config-validate) |
| plan, suggest, check | The snapshot, the models and components, the specs of the VM | The sizing, with its estimated margin | [spec: model fit](spec-model-fit.md#declared-resources) |
| script | The snapshot, the configuration, the package source and the random values given | One script per VM and the next steps | [spec: VM generator](spec-vm-generator.md) |

- **The core does no input or output.** It reads no file, opens no connection, asks for no clock or random number: what it needs is **given**, including the snapshot of the catalog (built at each release from the `describe` of the install scripts, which stay the source of truth) and any random value (the page draws it with the browser's, the CLI with the system's). This is what lets one source compile to a native program and to WebAssembly.
- **Written in Rust, and the install scripts stay bash.** The scripts of layer 1 (`apt`, `systemd`, Docker, nginx) and the orchestration of `apply`, `add`, `status` do not move: they are the part that touches a machine, and the CLI calls the native core where it uses `jq` programs today. This reopens [decision: scripting language](decision-scripting-language.md#revisit-when) **for the core only**, by steps (the validation first, then the generation and the sizing).
- **Sizing needs llmfit inside the core**, as a library compiled with the others: its hardware detection is not needed (the target is given by `--ram`, `--memory` and `--cpu-cores` already), but whether it builds as a library for WebAssembly is **not known** ([open questions](#open-questions)). Until it is, the page shows the sizing as not available, as the session does without llmfit ([llmfit is optional](spec-model-fit.md#llmfit-is-optional)); no figure is ever re-implemented in the page.
- **The documents are those of the CLI**, byte for byte: the CLI's `--json` is the output of the same core. There is no second description of a document.
- **Distribution.** The core is built by this repository and offered to the UI as a **package it depends on**, not as a binary kept in the CloudStack repository or a Rust toolchain in its build; whether the community accepts that is an [open question](#open-questions).
- **It runs in the page and nowhere else**: nothing is installed on the management server, and a cloud that does not use the project is unchanged.

#### What the project stores

Nothing outside CloudStack, and nothing that CloudStack already has. The configuration of a topology and its group of VMs are stored **in CloudStack** ([where a topology lives](#where-a-topology-lives)); the monitoring key is [read back from the VM](#reading-the-vms), not kept.

## Contributing to CloudStack

The page is built **in the repository of Apache CloudStack** and proposed there, so that it ships with the UI. This splits the work between two repositories:

| Where | What lives there |
| --- | --- |
| **`apache/cloudstack`** (`ui/`) | The section: its routes and menu entry, the three screens, the calls to the CloudStack API, the calls to the core, the reads of the status of the VMs, the translations, the tests of the UI, and the documentation of the feature in the CloudStack docs |
| **This repository** | The **core** (Rust, built for Linux and for WebAssembly) and the CLI that uses it, the install scripts, the [status document](#the-status-document) of the proxy, the specs (this one included), and the tests of all of these |

What this implies, to settle with the CloudStack community **before** writing the page:

- **The community has to accept a WebAssembly module in the UI**, built elsewhere and consumed as a dependency, whose logic is maintained in another repository. Nothing else of CloudStack depends on it, and no server is added. If it refuses, the alternatives are a section limited to what CloudStack knows (resources and metrics, [without the AI side](#not-in-this-version)), or the [other architectures](../search/cloudstack/architecture.md) (a service, the extensions framework), which add a component for the user.
- **The process of the project is followed**, not invented here: a discussion and a proposal on its mailing list or issue tracker before a large change, a pull request against the main branch, the project's licence headers, and its release cycle (the section reaches a release when it is merged for it). Where those rules are written is in the project's contribution guide, to read first ([to verify](#to-verify-on-cloudstack)).
- **The page is developed against a CloudStack that exists**: a development environment of the UI, pointed at a test management server, and a fork of the repository for the branch. Nothing here needs the project's own page to be installed on a production cloud before the merge.
- **The version it targets** is the main branch at the time, and a release later. A cloud on an older version does not have the page; the CLI works without it.
- **The page stays thin** ([principle 1](#principles)): the less logic the section holds, the less there is to review, translate and maintain upstream, and the less it moves when a capability of this repository changes.

## Screen 1: topology

A topology is edited as the [editor of spec: several VMs](spec-multi-vm.md#editing) does, with the same operations, as forms instead of a prompt:

| Part of the page | What it is | Capability and rule it shows |
| --- | --- | --- |
| **VMs** | A list; *add a VM* with a name (shape of [spec: config](spec-config.md#several-vms)) and an optional role (`engine`, `web`, `custom`, only a shortcut), rename, remove (with what goes with it announced) | [roles](spec-multi-vm.md#roles), `vm` fields |
| **Components of a VM** | One selector per type with the shipped components and their rank, the dependencies a choice drags in listed and accepted explicitly, the options as typed fields (a secret option offers its channels only, never a value) | `catalog`, `config schema`, [step 2 and 3 of the journey](spec-journey.md#2-components-and-dependencies) |
| **Models of an engine** | Hardware first (the specs of the VM, a ranked list of models that fit) or models first (the VM they need), each model with its fit verdict and the warning when llmfit disagrees; the place of a model is its VM and engine | [spec: model fit](spec-model-fit.md#choosing-models-in-a-session) |
| **Links** | For each VM that has a chat interface, the VMs whose engines it lists; the page draws them | [`links`](spec-config.md#links) |
| **Sizing of each VM** | The recommendation of `plan` for that VM, memory in two quantisations, the **estimated margin** shown as such with its sources, the models not covered, never a single total that looks measured | [estimated margin](spec-model-fit.md#estimated-margin) |
| **Warnings and errors** | Those of `config validate`, each with its `vm` and path, and the fix proposed as the editor's `f` does; **nothing can be created while an error stands** | [validation](spec-multi-vm.md#validation) |
| **File** | *Download* and *import* of the configuration | [spec: config](spec-config.md) |

Specifics of CloudStack at this screen, all asked as part of the same step, never decided silently:

- **Which CloudStack resources a VM maps to** (the [mapping](#mapping-to-cloudstack-resources)) is shown next to the sizing and is editable there: this is where the user turns "8 vCPU, 24 GB" into an actual compute offering, the zone, the template and the network. These choices are about CloudStack and are **not** part of the configuration file (the file stays valid for any cloud, like the target specs of the models step: an early opinion, see [spec: model fit](spec-model-fit.md#model-fit-for-a-machine-that-is-not-this-one)). Where they are kept is in [where a topology lives](#where-a-topology-lives).
- **A VM with a GPU** is offered only with a GPU compute offering the account can use, and the sizing is asked in GPU memory.
- **The size of a generated script** is shown per VM against the user-data limit of the cloud, which the page reads from CloudStack ([to verify](#to-verify-on-cloudstack)); above it, the VM cannot be created and the page says so before creation, not after.

## Mapping to CloudStack resources

For every VM of the configuration, the page proposes, from the sizing and the CloudStack inventory, the items below. **Every line is a proposal the user can change.** The page reads what the account may use (it lists, it does not guess).

| Needed | Proposed from | CloudStack object |
| --- | --- | --- |
| Compute (vCPU, RAM, GPU) | The sizing of `plan` for the VM: RAM without GPU or GPU memory with one, whichever applies, the cores of the `h` order if given | The smallest **compute offering** that covers it, or a custom one when the offerings allow it; none large enough is said, not worked around |
| Disk | The disk of `plan` (models plus system plus components) | The root disk size at deployment, or a data disk for the model store, per the offering rules of the cloud |
| Image | Ubuntu 24.04 or Debian, the targets of the project | A **template** the account may use, which must support cloud-init user-data; the user chooses, the page only filters by its name and OS type |
| Boot script | `script` (one script per VM, with the `VM:` header) | The **user-data** of the VM, base64, verified against the limit |
| Network | One network for the topology | An existing network of the account, or, if the user asks, a new isolated network (the page proposes, never creates a network silently) |
| Reachability | The ports the stack uses: 443 for each proxy (the engine VM's too: the web VM reaches it there), 8443 for the chat interface, 22 for SSH | Security-group rules or firewall and port-forwarding / static NAT rules, **depending on the kind of network**; and the rule that lets the `web_vm` of a link reach the `engine_vm` on the HTTPS port of its proxy ([next step 3](spec-multi-vm.md#next-steps)). The page lists each rule before creating it |
| Access | | An existing **SSH key pair** chosen by the user (the page does not create credentials) |
| Order | `links` | The engine VMs are deployed first, as the [next steps](spec-multi-vm.md#next-steps) say |

A rule of the project is kept: a model's engine listens on the loopback and only its proxy is exposed, so **no rule ever opens the engine's own port** (11434 for Ollama).

## Screen 2: creation

*Create* is a button on a topology with no error. It does nothing before showing the **plan of creation**: the exact list of what will be created, per VM, with the offering, template, disk, network, rules and tags, the size of each user-data, and a clear notice of what costs (the compute offerings, the public IPs). Only the user's `Create` after that list starts anything.

Then, in order, each step shown with its state and its CloudStack job:

1. The tags, the SSH key and the network items chosen (only what was not there).
2. The security-group, firewall or port-forwarding rules.
3. The VMs, engine VMs first, each as a CloudStack asynchronous job whose progress the page follows. The user-data is the script of that VM.
4. The VMs come up and **run their script at first boot** (cloud-init), which installs the stack. The page moves to the monitoring screen and shows this phase as [bootstrapping](#states-of-a-vm), because it takes minutes and models are downloaded in it.

Rules:

- **Idempotent and resumable.** The page finds what already exists by the [tags](#tags) and creates only what is missing, so that a failure in the middle, a closed tab or a second click leaves nothing doubled: *create* again continues. It never creates a second VM for a name that already exists in the topology.
- **The browser drives the creation, CloudStack runs it.** The order (engine VMs first) is kept by the page, and each step is a CloudStack job that goes on if the tab is closed. A closed tab leaves a topology **partly created, never wrong**: everything made is tagged, and opening the topology again shows what is missing and continues. Nothing else acts while no page is open.
- **A failure stops at that step**, says which job failed with the CloudStack error as given, and **removes nothing on its own**: the user chooses *retry*, *continue without*, or *destroy what was created* (listing it first).
- **The links are finished by hand once the VMs are up**, as today ([principle 3 of spec: several VMs](spec-multi-vm.md#principles)): the address of an engine VM and its API key do not exist when the scripts are generated, and no secret may travel through the user-data. The page shows the [next steps](spec-multi-vm.md#next-steps) of the validation, as written, **per link, with the real VM names, as a checklist**, and the [monitoring](#links-state) tells when each one is done. It does not run them: reaching inside a VM is beyond what the CloudStack API gives. A higher-level command that finishes a link is the [open question](spec-multi-vm.md#open-questions) of spec: several VMs, and would serve the page directly.
- **Editing after creation.** A script is a snapshot, so changing the configuration of a VM that exists is not changing the VM. The page offers, for an existing topology: add a VM (created like the others), and, for a change of a VM that exists, the **command to run on it** (`easy-cs-ai apply`, with the new slice) instead of silently recreating anything. It shows the drift between the file and what the VMs report ([states](#states-of-a-vm)). Replacing a VM is a destroy and a create, announced as such.
- **Destroy** a topology lists the tagged resources, asks whether to expunge (CloudStack's own choice) and whether to delete the data disks, and deletes nothing untagged. It is never offered on a resource created by hand.

## Tags

Every resource created by the page carries [CloudStack resource tags](#to-verify-on-cloudstack), what marks a resource as part of a topology (the page has no database of its own, and the [group of VMs](#where-a-topology-lives) holds the configuration):

| Key | Value |
| --- | --- |
| `easy-cs-ai.topology` | The name of the topology (a string of the shape of a [VM name](spec-config.md#several-vms)) |
| `easy-cs-ai.vm` | The name of the VM in the configuration, on the VM, its volumes and its rules |
| `easy-cs-ai.version` | The version of the package the scripts pin |

A resource without the topology tag is not part of it. Tag values are short and hold **no secret and no configuration**. A user may remove a tag by hand: that removes the resource from the topology, which is shown (the VM then appears as *not found* where it was expected), never guessed back.

## Where a topology lives

With no server of the project, a topology has to live **in CloudStack**, reachable by the users of the account, surviving a closed tab, shared between them, and following the permissions the account already has.

**Proposed:** the topology is a **group of VMs** (a CloudStack *instance group*, a label that groups VMs and has no effect on their placement), named after the topology, with each VM of the topology deployed into it, and the **configuration** (the file of [spec: config](spec-config.md), which holds no secret by [rule](spec-config.md#secrets)) saved as an **annotation** on that group. The groups of an account are the list of topologies the page opens with; the file stays downloadable at any time.

| Option | For | Against |
| --- | --- | --- |
| **Instance group + annotation** (proposed) | One object per topology, listed by CloudStack, visible next to the VMs; no new concept | The reference of 4.20 lists `INSTANCE_GROUP` among the entity types of annotations; **not confirmed**: the size limit of an annotation, who may add one, and that a group can be annotated and read by a user |
| Tags only, and the file downloaded | Nothing to store | The configuration is lost with the browser; the topology cannot be edited again |
| A registered user-data (`registerUserData`) holding the file | A stored text of the account, up to the user-data limit | A user-data is meant for a VM; its size limit (about 24 KB of text) is smaller than a large configuration |
| The browser (draft) | Nothing to build | Lost with the browser; not shared |

A draft is kept in the browser while editing, and saved when the topology is created or the user saves. Whatever the object, **a configuration that cannot be saved there is never silently kept elsewhere**: the page says so and offers the download.

## Screen 3: monitoring

A page per topology, built around one question: **is the local AI there, and is it used?** It is a dashboard of **status**, not a metrics system: it shows the state now and a short trend, and keeps no long history (nothing stores one: the page shows what it reads, and CloudStack keeps its own metrics for 12 hours by default).

### Sources

| What | From | Reach |
| --- | --- | --- |
| The VM exists, its state, offering, addresses, its job | CloudStack API (`listVirtualMachines`) | Always |
| CPU, memory, disk and network of the VM | CloudStack's own metrics of the VM | Always |
| What runs inside: components, models, links, use of the models | The [status document](#the-status-document) of the VM | From the browser, when the VM answers and [can be reached](#reaching-the-vms-from-a-browser) |

CloudStack tells **what the hypervisor sees**. Only the VM knows whether the engine answers, which models it holds and whether anyone is using them. The two are shown side by side and never merged into one verdict: a VM `Running` in CloudStack whose engine is down is the most useful thing the page can show.

### What it shows

**Header of the topology**: the overall state (the worst of the VMs, with the reason), the number of VMs, the models, and the age of the data ("updated 12 s ago") with a refresh control. A stale or missing source is shown as such, never as the last value.

**Per VM** (one card, `engine` and `web` here):

| Block | Content | Source |
| --- | --- | --- |
| State | One of the [states](#states-of-a-vm) | CloudStack and the status document |
| Components | Each installed component, with `running` and `healthy` (what `easy-cs-ai status` gives) | Status document |
| Resources against the plan | vCPU, RAM, disk in use against what the VM has, and **against what `plan` recommended for its models**: the page flags a VM whose RAM or disk use approaches the limit; the figures are the CloudStack ones, the recommendation is the capability's, and the margin is described as an estimate | CloudStack and `plan` |
| Certificate | The names it covers and its expiry (a self-signed certificate does not expire the same way as Let's Encrypt) | Status document |

**Per model** (a table across the VMs, each model with its [place](spec-config.md#where-a-model-goes)):

| Column | Meaning |
| --- | --- |
| Model, engine, VM | The place of the model |
| Loaded | Whether the engine reports it served (the [state of the engine](spec-script-contract.md#type-specific-actions)) |
| Use | **in use** (a request in the last 5 minutes), **idle** (none since, the last one dated), **never used** (none since the topology was created, or since the data starts) |
| Requests | Count over 5 minutes, 1 hour, 24 hours |
| Errors | Share of requests that were not answered successfully over the same windows |
| Latency | Typical and slow (median and 95th) over the last hour, when the proxy records it |
| Reached from | The chat-interface VMs whose [link](#links-state) lists it |

"**Never used**" and "**idle for a long time**" are what lets an administrator see that a costly GPU VM serves nothing. The thresholds are options of the page with these defaults, not rules of the project.

#### Links state

Each [link](spec-config.md#links) of the configuration is shown as `web → engine` with one of: **to do** (the `web_vm` reports no endpoint for the models of the `engine_vm`: the [step 4](spec-multi-vm.md#next-steps) is not done), **done** (the endpoint is in place), **broken** (it is in place but the `engine_vm` is not reachable from the `web_vm`, or the model list is empty). Each *to do* carries its checklist from the [next steps](spec-multi-vm.md#next-steps). Until a link is done, the model list of the chat interface is empty, which the page says in plain words.

#### States of a VM

One state per VM, the first that applies, each with what to do:

| State | Means |
| --- | --- |
| **Not found** | A VM of the configuration with no tagged VM in CloudStack (creation not done, or the tag removed) |
| **Stopped / Error** (as CloudStack's) | The hypervisor's state, shown as it is |
| **Bootstrapping** | Running in CloudStack, the [status document](#the-status-document) not available yet (cloud-init running, the script installing, a model downloading). Normal for several minutes; the page shows the time elapsed and says when it is long |
| **Unreachable** | Was reachable, no longer answers (firewall, proxy down, VM overloaded) |
| **Degraded** | Reachable, at least one component not running or not healthy, or a model not served |
| **Ready** | Reachable, every component of the configuration healthy, every model served |
| **Drifted** | `Ready`, but what the VM reports differs from the configuration (a component or a model added or removed by hand): shown, not "fixed" |

#### Alerts

Short and about the AI, not generic monitoring: an engine down, a model not served, a link broken or to do for more than a time, a certificate near its expiry, RAM or disk near the limit for the models held, a GPU VM whose models are never used. Alerts are shown on the page. Sending them anywhere (mail, CloudStack events) is [not specified](#open-questions).

### Reading the VMs

CloudStack's API does not look inside a VM, and the page may not log in to one. The project adds a **read-only status** that a VM publishes itself, and the page reads it.

#### The status document

Proposed, to add to the proxy component and its contract (**not implemented**): a document, refreshed by the VM every minute (a timer, **no new daemon**), served by the reverse proxy that already exposes the VM over HTTPS at a fixed path of its own (`/easy-cs-ai/status.json`), **never at a path of a model**. It is one JSON document, with its own `schema_version`, that holds only what is not secret:

| Field | Content |
| --- | --- |
| `vm`, `generated_at`, `package_version` | Who and when; `vm` is the name in the configuration when the slice carried it, else the host name |
| `components[]` | What `easy-cs-ai status --json` gives: name, type, version, `running`, `healthy` |
| `models[]` | Per model: name, engine, `served`, and the **use** of the model: requests and errors over 5 minutes, 1 hour and 24 hours, the date of the last request, latency (median, 95th). Counted from the **proxy's access log**, per model location, so that no engine is modified and every engine is covered alike |
| `endpoints[]` | For a chat interface, the endpoints it lists (name, model, URL), no key: it is what says a [link is done](#links-state) |
| `certificate` | The names it covers and its expiry |
| `system` | Free disk of the model store, memory seen by the VM |

- **It never holds a secret, a prompt or an answer.** The access log is read for counts, status codes, times and the model location only: the content of a request is not in the log and is never read. A log is not kept longer than the counters need.
- **It is read-only and read with a key of its own**, the **monitoring key**: accepted **only** on the status path and useless for inference. The API key is never the monitoring key, so a leak of the monitoring key leaks no access to the models. How the key is chosen and how the page gets it is an [open question](#open-questions), with a proposal: the page draws it and puts it in the user-data of the VM, which it can read back later, instead of a key generated on the VM and pasted.
- **A VM with no proxy** (no shipped stack, a proxy is required as soon as an engine holds a model) has no status document and is shown as `Unreachable`-by-design: only the CloudStack part is shown for it, and the page says so.
- The document is a capability of the VM, usable without CloudStack: `easy-cs-ai status --json` stays the local, root-free way, and the document is its remote form.

#### Reaching the VMs from a browser

The read is made **by the browser of the user**, so what the browser can reach decides what the page can show, and this is the main limit of having no server:

- **Reach.** The VM must have an address the user's network reaches (a public IP or a rule, a VPN). A VM on a private network the browser cannot reach is shown as **not reachable from here**, with the CloudStack side only, and the page says why. It is not an error of the VM.
- **Cross-origin.** The page is on the origin of the UI, the VM is another: the proxy of the VM must answer the browser's checks for **that origin only**, on the status path only. The origin is known when the script is generated (it is the one the page runs on), so it is an **option of the proxy** given at generation (name to settle), written in the configuration and never a wildcard.
- **The certificate.** A browser refuses a self-signed certificate until the user accepts it **for that VM**, and cannot be asked to by the page: the page shows a link to open the VM once, with the instruction, and reads again. A certificate the browser already trusts (Let's Encrypt, or the customer's) needs nothing. A change of certificate shows again as not trusted, which is the right behaviour.
- **Private networks.** Recent browsers add a check for a page that reaches a private address, a preflight the VM's proxy has to answer too ([Chrome's description](https://developer.chrome.com/blog/private-network-access-preflight), a rollout that has changed since 2022). **To test** on the browsers the users have.
- **Polling** is on demand and bounded: while a monitoring page is **open and visible**, every 30 seconds by default, never faster than the VM refreshes its document, and **never when no page is open**: nothing watches a topology that nobody looks at, which is why [alerts sent out](#not-in-this-version) are not in this version. A failed read is a state, not an error to hide, and is never retried in a tight loop.
- **Only the addresses CloudStack reports for the VMs of the topology are read**: the page never fetches an address it was given by anything else.

## Security

- The page uses the user's CloudStack session and API rights, and nothing else: there is no second door, since there is no service.
- **No secret in the configuration**, the tags, the group or the annotation, the status document or the logs. The **monitoring key** is the one exception under discussion ([open questions](#open-questions)): a key that reads status only, kept in the user-data of its VM, readable by those who can already see that VM in CloudStack.
- The API key of a proxy is generated on its VM and stays there, as today; the page never sees it, and the links are finished by hand.
- Data of the models (prompts, answers) never leaves the VMs and is never read by the status.
- The origin allowed by a VM's proxy for the status is the one of the UI, on the status path only.
- Destruction is only of tagged resources, after a listed confirmation.

## Not in this version

- **GPU set-up inside the VM** (drivers, passthrough): the scripts do not do it today and the project has not tested a GPU yet; the page offers a GPU offering and sizes for it, it does not make the VM able to use it.
- **Metrics history, dashboards of long periods, billing** and alerts sent out: the CloudStack usage and events services, or any monitoring tool, are the place.
- **Kubernetes, autoscaling, load balancing** several engine VMs for one model.
- **Replacing the CloudStack pages** (VMs, volumes, networks): the resources stay there, the page links to them.
- **Several clouds or several CloudStack zones in one topology.** A topology lives in one account of one CloudStack, in one zone.
- **Finishing the links automatically** (see [creation](#screen-2-creation)).

## To verify on CloudStack

The first reading of the documentation is in [search/cloudstack](../search/cloudstack/README.md) (2026-11-06, read and not tried): it confirms that a UI `plugins` entry shows a page in an iframe, that tags and registered user-data exist, and that the user-data limit counts **after base64** (about 24 KB of script, not 32 KB). The points below remain to check on a real instance of the version targeted; each is a premise, none is relied on as fact:

- **How a section is added to the UI and what the contribution requires**: the structure of `ui/` (sections, router, components, translations, tests), the version of its framework, the contribution guide and the proposal process of the project, whether a section may carry a WebAssembly module built elsewhere, and what the community expects for a feature of this size. [search/cloudstack](../search/cloudstack/ui-extension.md) found the way to add a section (`src/config/section`, `src/config/router.js`) in the UI guide only.
- **Resource tags** on VMs, volumes, networks and rules, their key and value limits, and that a tag on a rule or a network exists as needed.
- **Instance groups and annotations** as the place of a topology ([where a topology lives](#where-a-topology-lives)): that a group can be annotated and read by a user, the size limit of an annotation, the permissions, and how a VM is deployed into a group.
- **WebAssembly in the UI**: whether the UI's content security policy lets a module run, the MIME type the server gives `.wasm`, the size the UI can carry, and how the UI's build takes a package that contains a module.
- **Reading a VM from the UI's page**: the cross-origin and private-network checks of the browsers in use, and the `getVirtualMachineUserData` right of a user over the VMs of the account (for the [monitoring key](#reading-the-vms)).
- The **user-data size limit** (`vm.userdata.max.length`, default 32 KB per the [generator spec](spec-vm-generator.md#implementation-notes)) and how to read it from the API.
- **Metrics** of a VM through the API (CPU, memory, disk, network) and their freshness.
- **Networks**: what the account may create, and the differences between an isolated network (firewall and port forwarding), a shared one with security groups, and an advanced zone's VPC, for [reachability](#mapping-to-cloudstack-resources).
- **Compute offerings** with GPU and custom offerings, and the filtering of templates by the account.
- The **cloud-init** behaviour of the target templates, including the persistence of the journal ([contract open question](spec-script-contract.md#open-questions)).

## Definition of done

- A **parity** test, as that of the [journey](spec-journey.md#parity): the same decisions made in the page (against the core built for WebAssembly) and written by hand with the CLI give the same configuration, the same validation document and the same scripts; a configuration downloaded from the page and one loaded into it are byte for byte the same.
- Tests of the **core**: the same inputs give **the same documents** from the native build and the WebAssembly build (golden files, byte for byte); the CLI's `--json` is the core's output; the core opens no file, no connection and reads no clock (a test that runs it with none available); the snapshot of the catalog is rebuilt at each release and a test fails when it differs from the `describe` of the scripts; the size of the WebAssembly module is tracked.
- Tests of the **creation**, against a CloudStack API simulator or a mock: the plan lists exactly what is created and nothing that exists; it starts nothing before confirmation; the engine VMs are deployed first; a re-run after a failure at each step creates only what is missing; a failure removes nothing; an untagged resource is never listed for destruction nor touched; the user-data is the generated script and above the limit the creation is refused before any call; no secret in the user-data, the tags or the requests.
- Tests of the **status document** (proxy, `EASY_CS_AI_ROOT` mode): fields, counts from a sample access log per model, no content of requests, a refresh by the timer with no daemon, the monitoring key accepted on the status path only and refused on a model path, the API key refused on the status path, the document absent for a VM with no proxy.
- Tests of the **reading of the VMs**, from a browser (an automated one against fake VMs): the states of a VM for each case of the [table](#states-of-a-vm); a VM that cannot be reached is shown as such with the reason, and one whose certificate is not trusted shows the instruction; only the status path answers the UI's origin; the use classes (`in use`, `idle`, `never used`) at their thresholds; no polling when no page is open; a failed read shown as such.
- An **integration test** on a CloudStack (or its simulator): a topology of an engine VM and a web VM created from the page, scripts run at first boot, the links done by hand following the checklist, then the page showing `Ready`, the links `done` and the models as `in use` after a request, and `never used` before it.
- The section **meets the conventions of `apache/cloudstack`**: it builds with the UI, passes its checks and tests, has its translations and its documentation, and is merged upstream; the work done in this repository is limited to the core, the CLI, the scripts and the proxy.
- `docs/` and the README in step with the page's real behaviour.

## Open questions

- **The core's language and scope.** The core is Rust, compiled for Linux and WebAssembly ([the core](#the-core-webassembly)); this reopens [decision: scripting language](decision-scripting-language.md#revisit-when) for that part. To settle: the exact scope of the first step (the validation), how the catalog snapshot is produced and kept in step with the `describe` of the scripts, and the plan to migrate without rewriting the install scripts.
- **`llmfit` as a library for WebAssembly.** Whether it is published or can be used as a library, whether it builds for `wasm32` with no hardware detection, the size of its model data, and the licence terms for bundling it. The sizing depends on it; the other capabilities do not. **First thing to try** (see [the research](../search/cloudstack/architecture.md#what-to-try-in-this-order)).
- **The acceptance of a WebAssembly module in the CloudStack UI** ([contributing](#contributing-to-cloudstack)): built in another repository, consumed as a package, with its own build chain.
- **Where the configuration is saved** ([where a topology lives](#where-a-topology-lives)): the instance group and its annotation are proposed, not confirmed.
- **The monitoring key.** Three ways, none settled: **(a)** generated on the VM like the API key and pasted by the user into the page, which must then keep it somewhere per user (the browser) and breaks as soon as a second administrator opens the topology; **(b)** **drawn by the page and put in the user-data of the VM** (proposed), which the page reads back with the user's rights, so nothing is pasted or kept, at the price of an **exception to the rule that no secret travels through the user-data** and to the rule that [a literal secret is never in the configuration](spec-config.md#secrets) (a secret option that is a literal, for this key only); **(c)** **no key**, the document readable by whoever reaches the VM's HTTPS port, restricted to the UI's origin for browsers only, which leaks counts of requests to anyone on the network. The key of (b) reads status only, which is why the exception is proposed.
- **The origin option of the proxy.** The name and shape of the option that gives the UI's origin to the status path (and its CORS and private-network answers) in the nginx component, and what happens when the UI is reached by several addresses.
- **A path outside the proxy** for the status of a VM whose proxy is down: the VM can then only be `Unreachable`, with the CloudStack side. Is a guest-agent route worth the dependence on the hypervisor?
- **Metrics from the proxy's log** count requests, not tokens or GPU load. Whether the engines can report more (tokens per second, GPU use) in a way common to every engine, without breaking the rule that an engine is not modified, is open; vLLM and Ollama have their own metrics, and a type-specific action of the [contract](spec-script-contract.md#type-specific-actions) would be the way.
- **Sending alerts** (CloudStack events, mail, a webhook).
- **A credentials file** ([contract, Secrets](spec-script-contract.md#secrets)) for the API key: it would let a tool in the cloud fetch it without the logs, but it is a secret in a file at a known place, readable by whoever reaches the VM; the page does not depend on it (the user pastes the key to finish a link).
- **Roles in the page.** Whether a read-only user (watching the topologies, not creating) is a CloudStack role distinct from the one that creates, and how the page reads it.
- **Cost display.** Showing the cost of a VM from the offering, if the cloud publishes it, is outside what the capabilities give; the page would read CloudStack, never compute it.
