# CloudStack: where do the capabilities run?

[← Back to CloudStack](README.md)

**The question.** The page is a native section of the CloudStack UI ([decision](ui-extension.md)). It must offer the features of the project: choose components and options, size the VMs with llmfit, validate, generate the post-install scripts, then monitor the VMs. Those features are today **bash, `jq` and a Rust binary (`llmfit`)**, run by the CLI. Three ways to get them to the page:

1. **Recode everything in the web interface.**
2. **Call an API server**, hosted somewhere (the service of the [spec](../../docs/spec-cloudstack.md#the-service)): a component to install and to protect.
3. **Embed `easy-cs-ai` in Apache CloudStack**: the management server runs it.

> **Decision (2026-11-06):** no server of the project, and no tool to install on the management server. The core of the logic is written once, in Rust, and compiled both for Linux (the CLI) and to WebAssembly (the page): **option 4** below, which is option 1 with the llmfit and the language questions answered by a rewrite of the core. What CloudStack stores is the group of VMs and its configuration. See [spec: CloudStack](../../docs/spec-cloudstack.md#the-core-webassembly). The comparison below is kept as the reasoning; what option 4 leaves open is under [option 4](#option-4-a-rust-core-built-for-linux-and-webassembly-decided).

Research of 2026-11-06, from the documentation and the `main` branch of `apache/cloudstack`; nothing was tried on an instance. What was not confirmed is listed at the end and in each row.

## What has to run, and what it needs

| Capability (of [the service](../../docs/spec-cloudstack.md#the-service)) | Made of | Where it can run |
| --- | --- | --- |
| `catalog`, `config schema` | The `describe` of each shipped script: **data that only changes with a release** | Anywhere, as a file generated at release |
| `config validate` | One `jq` program run per slice ([spec: config](../../docs/spec-config.md#implementation-notes)), reading the `describe` data | Needs `jq`, or a port |
| `script` | Filling a small script template with the slice, the package version and its checksum | Needs the template, no tool beyond `bash` (or a port, with a test that both give the same bytes) |
| `plan`, `suggest`, `check` | **`llmfit`** (Rust) with `--ram`, `--memory`, `--cpu-cores` overrides, so **no hardware detection is needed**, plus bash and `jq` for the margin | Needs the binary: 10 to 19 seconds per model ([spec: model fit](../../docs/spec-model-fit.md#recommended-vm)) |
| Collect the status of the VMs ([status document](../../docs/spec-cloudstack.md#the-status-document)) | An HTTPS read with a key and a pinned certificate | Needs **network reach to the VMs**, which depends on where it runs (below) |

### Who can reach the VMs

The same read gives different results depending on where it starts from. This matters more than the packaging for the monitoring:

| Vantage point | Reaches a VM when | Issues |
| --- | --- | --- |
| **The browser of the administrator** | The VM has an address the administrator's network reaches (a public IP, a VPN) | Cross-origin rules (the VM's proxy would have to allow the UI's origin), a **self-signed certificate** the browser refuses until it is accepted for each VM, the monitoring key kept in the browser, no reading when no page is open |
| **The management server** | The management network reaches the guest network. Not a given: the management server is usually on its own network, and an isolated network's VMs have private addresses | The management server is the machine the cloud's own tools run on: what it may reach is the operator's policy |
| **A service host the operator chooses** | The operator puts it where it reaches the VMs | One more machine to install, protect, and keep in step |

None of them is always possible. A design that assumes one reach fails on the clouds where it does not hold, which the spec has to say ([open question](../../docs/spec-cloudstack.md#open-questions)).

## Option 1: everything in the web interface

The capabilities are re-implemented in, or compiled for, the browser.

| Part | Feasibility found |
| --- | --- |
| `catalog`, `schema` | Easy: static files generated at release |
| `script` | Easy: a template; the risk is two implementations drifting, which a test of byte parity answers |
| `config validate` | `jq` exists as WebAssembly: [`jq-web`](https://www.npmjs.com/package/jq-web) (npm 0.6.2, Emscripten) and [`jq-wasm`](https://github.com/paolosimone/jq-wasm), which says it moves to jq 1.6. The validation is **one `jq` program**, so it could run **as it is** in the browser, if it is kept in a file of its own and uses only what that version of jq has. The version of `jq` the project requires, and what the scripts use of it, **were not compared**: to check |
| `plan`, `suggest`, `check` | **No sign of a WebAssembly build of llmfit**; the sources found speak of Cargo, Homebrew, Scoop and Docker, and of detection through native tools (`nvidia-smi`, `rocm-smi`, `system_profiler`), which the overrides avoid. Whether the crate builds for `wasm32` was **not checked**. If not, the sizing cannot move to the browser, or needs the rules and the models' figures re-implemented, which breaks [principle 1](../../docs/spec-cloudstack.md#principles) |
| Monitoring | The browser vantage point above: workable for a VM with a public address and a trusted certificate, awkward otherwise |

**For**: nothing to install, nothing to host; the logic runs where the user is. **Against**: sizing is the blocker unless llmfit compiles to WebAssembly; the validation port is a real piece of work and the project's `jq` and the browser's must stay in step; the monitoring is the weakest of the three vantage points; the UI repository would carry compiled assets or a second copy of logic to review upstream.

## Option 2: an API server

What the spec says today: a stateless HTTP wrapper of the CLI capabilities, run where the operator chooses.

**For**: the CLI runs unchanged, with the same documents, so there is no second logic and no porting; the vantage point for the monitoring is chosen by the operator; llmfit and its 10 to 19 seconds fit a service. **Against**: **one more component to install, host, update and protect**; it is a second origin for the page (cross-origin, authentication of the user against CloudStack, see the [open question](../../docs/spec-cloudstack.md#open-questions)); and the community has to accept a section that depends on it. This is the option the user finds heavy, and it is.

## Option 3: `easy-cs-ai` embedded in CloudStack

The management server runs the CLI. Two mechanisms exist or could exist; **both put the tools (`bash`, `jq`, `llmfit`) on every management server**, as one package installed once on machines the operator already administers.

### 3a. The extensions framework (exists, "new")

Read from the [admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/extensions.html) and the 4.22 API reference:

| Point | Found |
| --- | --- |
| What it is | "An external binary (written in any programming language)", stored at `/usr/share/cloudstack-management/extensions/<name>`, owned by the `cloud` user and group, **the same on every management server** (a path that differs is reported "Not Ready") |
| Where it runs | **On the management server**, with the payload as a JSON file under `/var/lib/cloudstack/management/extensions`; no SSH to a remote host is described |
| Protocol | The executable is called with the action, the payload file and a timeout; stdout comes back to the caller; for a VM action, a message is shown in the UI when the output carries `"printmessage": "true"` (the documentation of the output is partly a summary: to verify) |
| Custom actions | `addCustomAction`: name, **parameters** typed (string, number, boolean, date, with validation and value lists), roles allowed (**Admin, Resource Admin, Domain Admin, User**), success and error messages, `timeout` (**5 seconds by default**, settable). The UI builds a "Run Action" form from the parameters |
| Bound to | A **resource**: VirtualMachine for an orchestrator extension, Network or Vpc for a network one. `runCustomAction` requires a `resourceid`. **A global action (no resource) is not documented** |
| Registration | An orchestrator extension is registered with a **cluster**; whether one can exist with only custom actions is **not confirmed** |
| Maturity | The documentation says it is "a new mechanism"; the built-in extensions (Proxmox, HyperV, MaaS) "may undergo changes … backwards compatibility is not guaranteed"; its version of introduction was **not confirmed** (4.22 appears in the API reference) |

**What fits.** It is the CloudStack-supported way to run an external program from the management server, with typed parameters, roles, and a form in the UI, and **it needs no change to the core of CloudStack**: the extension is registered by an operator (a user-defined one, `isuserdefined` in the response). The project could ship the extension as a small package that depends on `easy-cs-ai`.

**What does not fit (to test).**
- The actions are **tied to a VM, a network or a VPC** and are not documented as global: `catalog`, `validate`, `plan` and `script` have **no resource**, since they act on a topology that does not exist yet. A workaround (an action on any existing VM or network as a pretext) is poor, and unconfirmed to be possible.
- It is a **call and a message**, not a data API: how the output of the executable reaches the page (the `result` of `runCustomAction`, an asynchronous job to poll) was **not confirmed**, nor any limit on its size.
- A **timeout** per action, and each `plan` takes 10 to 19 seconds per model: workable if the maximum timeout allows it.
- Orchestrator extensions bring **limits to extension-managed VMs** (no data volumes, no user-data, no SSH key injection, no live migration) that must not apply here: the project's VMs are ordinary VMs created through the normal API, and the extension would only **act on** them. That has to be tested, since the documentation describes extensions as the owner of the VMs they orchestrate.
- The monitoring through it reads the status document **from the management server** (a custom action on a VM, called by the page), so the vantage point is the management network.

### 3b. A backend plugin in CloudStack (would be contributed)

A new API command in the management server (`listLocalAi…`, `validateLocalAiConfig`…) that runs the CLI on the management host, so that the UI would call only `/client/api` and get the session, the permission checks and the asynchronous jobs of CloudStack for free.

- **Precedents found**: `plugins/integrations` of `main` holds `cloudian`, `kubernetes-service`, `prometheus` and `veeam-control-service`, each a Maven module; and `SshHelper` (`com.cloud.utils.ssh`, with the trilead library) runs a command over SSH with a key, a password and timeouts of 180 s (connect), 60 s (key exchange) and 120 s (result). That a management server can run commands elsewhere is therefore established; **running a local external program from a plugin was not checked** (the `Script` and `ProcessBuilder` usages were not read).
- **Not confirmed**: how an optional plugin is declared and packaged (the developer guide describes storage plugins only, with `client/pom.xml` and `componentContext.xml`), what an API command needs, how the UI lists it.
- **Contribution rules found** (`CONTRIBUTING.md`): a feature branch from `main`, a PR with two approvals, the tests run and how to test them, screenshots for the UI, a note in the pending release notes; **no design-document or mailing-list requirement found on the pages read** (not the same as none).
- **Against**: Java code to write, review and keep in the CloudStack repository for a feature whose logic is bash; the community may refuse a core module that shells out to a toolbox, which is the same acceptance risk as for the external service, moved to the backend. The alternative, re-implementing the logic in Java, breaks [principle 1](../../docs/spec-cloudstack.md#principles).
- **A path with SSH into the VMs** (reading `easy-cs-ai status --json` inside them) was considered and **not retained**: it needs a private key the management server does not hold (CloudStack key pairs are registered by public key).

## Option 4: a Rust core, built for Linux and WebAssembly (decided)

The computations of the project (catalog, schema, validation, sizing, script generation, next steps) are written **once, in Rust, as pure functions with no input or output**, then built **natively** (what the CLI calls, in place of the `jq` programs) and **for WebAssembly** (what the page runs). The catalog is a snapshot of the `describe` of the install scripts, given as an input. The install scripts and the orchestration (`apply`, `add`, `status`) stay in bash. Nothing runs on the management server and there is no service.

- **What it settles**: the single logic (one source for both targets), the sizing blocker **if** llmfit can be used as a library for `wasm32`, the extra component (none), and the authentication towards a service (none to build: the page has the user's session). The `jq` WebAssembly route of option 1 is not needed, since the validation is rewritten in the core.
- **What the store is**: CloudStack. The group of VMs (an instance group) and an annotation on it for the configuration, to confirm ([api-resources](api-resources.md#annotations)). `listInstanceGroups` and `createInstanceGroup` exist in the API references from 4.1; groups are labels with no effect on placement; the annotation entity type `INSTANCE_GROUP` is in the 4.20 reference. Not confirmed: that a group can be annotated and read by a user, the size limit of an annotation, and how a VM is deployed into a group.
- **What it leaves open**
  - **Monitoring from the browser.** The browser reaches a VM only if the user's network does; a self-signed certificate is refused until accepted for that VM; the VM's proxy must answer the UI's origin on the status path (and, from a private address, Chrome's [private-network preflight](https://developer.chrome.com/blog/private-network-access-preflight), the 2022 description of a rollout that has since changed). A VM the browser cannot reach shows only CloudStack's side. Nothing watches when no page is open.
  - **The monitoring key.** Without a server to hold it, the proposal is that the page draws it and puts it in the user-data of the VM, from where it reads it back with the user's rights: an exception to "no secret in the user-data", justified because it only reads status.
  - **`llmfit` as a library for `wasm32`**, and its size and licence terms for bundling (it is MIT, per its README).
  - **The decision on the language**, which reopens [decision: scripting language](../../docs/decision-scripting-language.md#revisit-when) for the core, by steps; the cost of the rewrite (the validation in `jq`, the generation, the `bats` tests) and the drift between the catalog snapshot and the scripts.
  - **Distribution into the UI**: a package built in this repository that the UI depends on, not a binary or a Rust toolchain in the CloudStack repository; the content security policy of the UI, the MIME type of `.wasm` and the size are to test.

## Comparison

| | 1. In the browser | 2. API server | 3a. Extension | 3b. Backend plugin | **4. Rust core, WebAssembly (decided)** |
| --- | --- | --- | --- | --- | --- |
| **Component to install** | None | **A service**, to host and protect | The CLI package **and** the extension on each management server | The CLI package on each management server, and a CloudStack release that has the plugin | None |
| **Same logic as the CLI** | Only with `jq` in WebAssembly and **llmfit compiled** (unknown); else a second logic | Yes | Yes | Yes (if it runs the CLI) | **Yes, one source built twice** |
| **Sizing with llmfit** | Blocked unless it builds for WebAssembly | Yes | Yes, with a long enough timeout | Yes | Needs llmfit as a library for `wasm32` (to try) |
| **Authentication and rights** | The UI's session, nothing more | **To design** (second origin) | The extension's roles and the UI's session | Native (API ACL, jobs) | The UI's session, nothing more |
| **Monitoring vantage point** | The administrator's browser | The operator's choice | The management network | The management network | The administrator's browser |
| **Change in CloudStack itself** | The UI section only | The UI section only | The UI section, calling `runCustomAction` | The UI section **and** Java code | The UI section only |
| **Resource-less actions** | Not an issue | Not an issue | **Not documented**: the main doubt | Not an issue | Not an issue |
| **Upstream acceptance risk** | Large assets and a second logic | An external dependency | Low for the extension itself (supported mechanism); the UI section as before | Highest | A WebAssembly module consumed as a package |
| **Maturity of what it relies on** | jq WebAssembly exists | Nothing new | A new mechanism, may change | CloudStack's plugin API | WebAssembly is common; the Rust core is to write |

## Reading of the comparison

- **No option is free.** Each trades the user's burden against a risk found here: a component to host (2), the llmfit blocker (1), the unknowns of a new mechanism (3a), the Java contribution (3b).
- **3a is the closest to "embedded in CloudStack" and needs no change to the core**, which is why it is worth testing **first**. It stands or falls on two questions that only an instance answers: can an action exist **without a resource** (or can the topology be tied to a real resource, such as the SSH key pair or a network of the account), and does the output of an action come back **as data** to the page.
- **1 is attractive for the part that is only data** (`catalog`, `schema`, `script` and the validation through `jq` in WebAssembly) **and cannot do the sizing and the monitoring well**: a mix is possible, the browser for what it can do and a server-side mechanism for llmfit and for reading the VMs.
- **2 stays as the fallback that works on any cloud**, since nothing here depends on CloudStack's internals; its cost is the one the user named.

## What to try, in this order

**For the decided option 4**, no CloudStack is needed for the first two:

- **A.** Does `llmfit` build as a library for `wasm32`, with the detection left out and the overrides only, and what is the size of the module with its model data?
- **B.** A prototype of `config validate` in Rust, with the catalog snapshot as input, run against the cases of the current `bats` tests and compared with the `jq` output; then built for `wasm32` and called from a bare page.
- **C.** On a test CloudStack: can an instance group be annotated and read back by a user, and how large may an annotation be; does the UI's content security policy let a WebAssembly module run, and with which MIME type; can a browser read a status document from a VM across origins (self-signed and trusted certificates, private addresses)?

The experiments below are for the options that were **not** retained, in case option 4 fails at A or B.

1. **Extension without a resource** (3a): register a user-defined extension with a trivial executable on a test CloudStack (4.22 or later); can a custom action be run with no VM, or tied to a network or an SSH key pair? Does `runCustomAction` return the standard output, and up to which size and timeout? Does it need a registration with a cluster?
2. **An extension that only acts on ordinary VMs** (3a): does it leave their user-data, volumes and SSH keys alone?
3. **`llmfit` for `wasm32`** (option 1): does the crate build with the detection disabled and the overrides only? And does the project's validation `jq` program run unchanged in `jq-web`, once extracted into a file of its own? A day each, no CloudStack needed.
4. **Reach**: from the management server of the target clouds, can the guest addresses (isolated and shared networks) be reached on 443? This decides whether monitoring may run from the management server.
5. **A Java API command that runs a local program** (3b): only if 3a fails.

## Not confirmed

Global custom actions; the shape of `runCustomAction`'s result; registration of an extension that has only actions; the introduction version of extensions; whether an extension may act on VMs it does not manage; the `Script` / `ProcessBuilder` precedents; the packaging and enabling of optional plugins; any design-document or mailing-list requirement for a new feature; outbound-host restrictions of the management server; whether llmfit builds for WebAssembly; the `jq` version the project needs against that of `jq-web`; how a CloudStack operator would react to a toolbox installed on the management server. The Java source of the extensions (`server/src/main/java/org/apache/cloudstack/extension/`) returned 404 on `main` and was not read.

## Sources

- [Extensions, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/extensions.html); API reference 4.22: [createExtension](https://cloudstack.apache.org/api/apidocs-4.22/apis/createExtension.html), [registerExtension](https://cloudstack.apache.org/api/apidocs-4.22/apis/registerExtension.html), [addCustomAction](https://cloudstack.apache.org/api/apidocs-4.22/apis/addCustomAction.html), [runCustomAction](https://cloudstack.apache.org/api/apidocs-4.22/apis/runCustomAction.html)
- [`plugins/` of `apache/cloudstack`](https://github.com/apache/cloudstack/tree/main/plugins), [`plugins/integrations`](https://github.com/apache/cloudstack/tree/main/plugins/integrations)
- [`SshHelper.java`](https://raw.githubusercontent.com/apache/cloudstack/main/utils/src/main/java/com/cloud/utils/ssh/SshHelper.java)
- [Developer guide: plugins](https://docs.cloudstack.apache.org/en/latest/developersguide/plugins.html), [programmer guide](https://docs.cloudstack.apache.org/en/latest/developersguide/dev.html)
- [`CONTRIBUTING.md`](https://github.com/apache/cloudstack/blob/main/CONTRIBUTING.md)
- [`jq-web`](https://www.npmjs.com/package/jq-web), [`jq-wasm`](https://github.com/paolosimone/jq-wasm), [llmfit](llmfit.md)
