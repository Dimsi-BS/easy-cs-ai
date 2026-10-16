# Spec: two VMs, the engine and the web interface apart

[← Back to docs](README.md)

**Status:** proposed, not implemented. The open questions at the end do not block starting.

## Purpose

Today a stack lives on **one machine**: the engine, the proxy and the chat interface share it, and the chat interface reaches the engine on the loopback (see [decision: LibreChat install](decision-librechat-install.md#4-reaching-the-models-from-the-container)). An administrator may want the inference engine on one VM (often the costly one, with a GPU) and the web interface on another, small one.

This spec lets one [configuration](spec-config.md) describe **several VMs**, lets the [generator](spec-vm-generator.md) produce **one script per VM**, and says what the administrator does once the VMs are running. It adds no deployment model: each VM is a stack like today's, and the link between them is made by hand afterwards.

The question "one VM or two?" is part of the [journey](spec-journey.md) like any other: a person answers it in the session, a program writes it in the configuration, and both end on the same file.

## Principles

1. **One VM stays as it is.** The question defaults to "one VM", a configuration with no `vm` is read as today, and the answers that give a one-VM script today give the same script, byte for byte. The one thing that is not the same is the session itself: the VM question is one more prompt, so a file of answers written for the previous session needs one more line at that place (an empty one takes the default `1`), see [the question](#the-question). Nothing in **this spec** changes the loopback link, the `add` orchestration, the exit codes or the JSON of the one-VM case. Two things come from the specs it relies on: the sizing text ([spec: model fit](spec-model-fit.md)) and the refusal of a model that cannot finish ([spec: config](spec-config.md#what-a-model-needs)), see [what does not change](#what-does-not-change).
2. **One configuration, one optional field.** A component may name its VM (`components[].vm`, see [spec: config](spec-config.md#several-vms)), and so may a model, which gives it a [place](spec-config.md#where-a-model-goes) with its engine. The generator cuts the file into one **slice** per VM; each script embeds only its slice, with no `vm` field. A VM, and `apply` running on it, never see that another VM exists. `schema_version` stays 1.
3. **The link is finished by the administrator, once the VMs are up.** The address of the engine VM and its API key do not exist when the scripts are generated, so nothing about them goes into a script. The generator tells the administrator what is left to do (see [Next steps](#next-steps)).
4. **No secret travels through a generated script.** The API key is generated on the engine VM, as today (see [Secrets](spec-script-contract.md#secrets)), and read from there on demand with `proxy nginx show-key`.

## Topology

The session proposes two VMs, named `engine` and `web`. The names are labels: a file written by hand may use others (see [spec: config](spec-config.md#several-vms)), and nothing below depends on them but the wording of the session.

| | `engine` | `web` |
| --- | --- | --- |
| Types the session asks | `provisioning`, `proxy`, `engine` | `proxy`, `chat-interface` |
| Typical content | `llmfit`, `nginx`, `ollama` (or `vllm`) and the models | `nginx`, `librechat` |
| Models | All of them | None |
| Reached by | The `web` VM, over HTTPS with the API key, through its proxy | The browsers, over HTTPS on the site port of its proxy |

- This is what the session proposes, **not a rule of the format**: any component may be given any VM, and the validation checks each slice as it checks a one-VM file. The rules that are about the link are warnings, see [Validation](#validation).
- The engine stays on its loopback and the proxy exposes it, as `add` already does for any engine that is not `protected`. The proxy is therefore **required** on the engine VM as soon as it holds a model of an engine that is not `protected` (none of the shipped ones is), and the validation says so (see [Validation](#validation)). Nothing new on the engine side: its slice is the configuration an administrator who wants an API-only VM writes today. Its models are not linked to a chat interface of another VM ([spec: config](spec-config.md#models)).
- LibreChat `requires` nginx (for its web site), not an engine, so the `web` slice validates and installs on its own. It comes up with **no model**: its selector is empty until the link is made.
- Both VMs carry an nginx, each with its own options (server name, certificate strategy, ports): that is why the file may hold an entry per component **and per VM**.
- One engine VM and one web VM is what the session offers and what the [next steps](#next-steps) describe. The format and the generator take any number of VMs; several engine VMs for one interface, or several interfaces, are not specified (see [open questions](#open-questions)).

## Validation

The validation of [spec: config](spec-config.md#validation) applies, with the file cut into slices; its errors for `vm` are listed there. This spec adds **warnings**, which do not change the exit code, shown by `config validate`, by the summary of the session, and by `generate --config`:

| Code | When | Message (in substance) |
| --- | --- | --- |
| `engine_unreachable` | An engine that is not `protected` is on a VM with no proxy, **holds no model in the file**, and a chat interface is on another VM | The engine listens on the loopback of its VM and nothing exposes it: the chat interface of the other VM cannot reach it. Add a proxy to that VM before the first model |

An engine that is not `protected`, **holds a model** and has no proxy on its VM is not a warning but an **error**: `missing_requirement`, see [what a model needs](spec-config.md#what-a-model-needs). The script of that VM could not finish (`add` needs the proxy, exit 4, after the engine is installed), so the validation refuses the file before any script is written, with or without a chat interface on another VM. The warning is what remains for the valid case, an engine installed first whose models come later; it never comes with the error for the same engine.

A warning has the same shape as the other warnings of [spec: capabilities](spec-capabilities.md#config-validate), with a `code` and the `vm` it is about.

## In the session

The session is the [journey](spec-journey.md) walked once per VM. It writes one configuration, whose components carry their `vm`.

### The question

At [step 1](spec-journey.md#1-discover), when the package ships at least one engine and one chat interface, the session asks:

```text
One VM for everything (1), or the web interface on a second VM, apart from the inference engine (2)? [1]
```

- Answered `1` (the default), the session runs exactly as before and writes no `vm`. The question is asked in every session of a package that ships an engine and a chat interface, so the answers that a script feeds to a session (stdin) gain one line at the place of that question, empty to take the default: the scripted answers of the existing tests and of the [parity scenarios](../tests/unit/parity/README.md) are updated with it, and the configuration and script they give stay the same. With nothing shipped to split (no engine or no chat interface), the question is not asked.
- Answered `2`, the session runs the steps 2 to 5 **twice**, over the types of each VM (see [Topology](#topology)): first `engine`, then `web`. A pass is the session as it is today, restricted to those types; the models step belongs to the first pass only, and ends, if the engine is not `protected` and the pass has no proxy, with the [proposal of a proxy](spec-journey.md#4-models) (the engine VM then gets its own nginx, with its own options). Every component written gets the `vm` of its pass, and so does every model, with the `engine` it was asked for: the file says where each model goes ([spec: config](spec-config.md#where-a-model-goes)).
- Each pass ends on its own [summary](spec-journey.md#5-validate-show-confirm) (components in install order, options, models, platforms, warnings, and the recommended VM of the pass when it is computed: in the `m` order, or for a pass with no model, see [model fit](spec-model-fit.md#recommended-vm)), with the same confirm / redo (`c`, `o`, `m`) / cancel. Cancelling at any point cancels everything: nothing is written, exit 0.
- The recommended VM of each pass comes from `provisioning llmfit plan`, called with the components **of that VM**, so the `engine` VM carries no share for an interface that is not on it. The `engine` pass gives the models, each as `<model>@<engine>` with the engine of its [place](spec-config.md#where-a-model-goes), and its components (`--component` for each); the `web` pass has no model and gives its components only, with no cores (the cores of the `h` order belong to the VM they were given for, so its `vcpu` is `null` and the text says `not sized`), which `plan` answers as [a stack with no model](spec-model-fit.md#a-stack-with-no-model), with no warning about models, since this VM has no engine and will hold none (the warning that the models come on top belongs to a VM that has an engine). Both rely on the [declared resources](spec-model-fit.md#declared-resources) of the components. On the `engine` VM, the models of an engine that runs one instance per model (vLLM) are **added up** by `plan`, since the instances run together, where a one-process engine counts its largest model ([models loaded together](spec-model-fit.md#models-loaded-together)): the engine VM, which holds all the models, is where the difference shows.
- The [package source](spec-vm-generator.md#package-source) is asked once and is the same for every script.

### What is written

| Mode | One VM (unchanged) | Several VMs |
| --- | --- | --- |
| Script | `./easy-cs-ai-vm.sh` | `./easy-cs-ai-vm-engine.sh`, `./easy-cs-ai-vm-web.sh` (one per VM) |
| `--config-only` | `./easy-cs-ai.json` | `./easy-cs-ai.json`, **one file**, with the `vm` fields |

- With `--output <path>`, the VM name is inserted before the extension of each script: `--output vm.sh` gives `vm-engine.sh` and `vm-web.sh`. With `--config-only`, `--output` names the one file.
- The scripts are written together: if one cannot be written, none is kept.
- `--dry-run` runs the whole session and prints every result to stderr.
- The header of each script gains one line, `VM: engine (1 of 2)`, so that a script found on a VM says which side of a set it is. One-VM scripts have no such line.
- The size warning (32 KB) applies to each script.

## For a program

The same file, written in one go: a program (or an agent working for a person) writes the configuration with the `vm` of each component, validates it with `config validate <file> --target fresh` (which cuts it into slices and checks each; the default target `this` is one machine and needs `--vm`, see [spec: capabilities](spec-capabilities.md#config-validate)), then runs `generate --config <file>`, which gives the same scripts the session does. There is no other path and no other flag: the answer to the VM question **is** the `vm` fields, so that [rule 2 of the journey](spec-journey.md#rules) holds without exception, and `config schema` lists the field.

`generate --config <file> --json` extends its document for several VMs (see [spec: capabilities](spec-capabilities.md#commands)): `script` is `null` and `scripts` lists one entry per VM (`vm`, `path`, `bytes`, `written`, `package_version`, `package_format`), and `next_steps` carries the [next steps](#next-steps) as an array of strings. `config validate --json` carries the same `next_steps`, since they depend on the file only. They depend on **all** its VMs, so a validation of one slice alone (`--vm <name>`) has neither `next_steps` (`[]`) nor the `engine_unreachable` warning, which also needs to know what the other VMs hold. With one VM the documents are unchanged.

The journey text of [`guide.txt`](../install_scripts/guide.txt) tells an agent to ask the user the VM question and to give the `vm` fields; a test checks that it names the same commands as the next steps.

## Next steps

When the file has several VMs, the validation computes the list of what remains for the administrator (see [Where they are computed](#where-they-are-computed)). After the scripts are written, the generator prints it on stderr (not asked to confirm), and with `--json` it is the array `next_steps`. Step 1 is always there; steps 2 to 4 appear when exactly one VM has an engine and no chat interface and exactly one other VM has a chat interface and no engine, which is the case this spec is about, **and the engine VM has a proxy** (steps 2 and 3 are actions of the proxy: without one, they would be commands that fail; a file with a model on such a VM is refused, see [Validation](#validation), and one without a model has the [`engine_unreachable` warning](#validation) that says what to fix) **and its engine is not `protected`** (a `protected` engine enforces HTTPS and its key itself and `add` does not put it behind the proxy, so `list-upstreams` would be empty and the key of the proxy would be useless to the web VM; see the [open questions](#open-questions)) **and the engine VM holds at least one model in the file** (steps 2 to 4 read the URL of each model and link it: with none, there is nothing to read or link, and the models that come later are linked by hand with the `add-endpoint` of the contract); with any other layout only step 1 is given. For that case a person reads the text below. Its first lines, the scripts written, are the **generator's own**: they name the files it wrote, which the validation cannot know (`--output` changes them, and `config validate` writes nothing). The list proper starts at `What is left to do` and is what the validation computes and what `next_steps` holds:

```text
Two scripts written, to run on two different VMs:
  ./easy-cs-ai-vm-engine.sh   VM engine  (<engine> behind HTTPS and an API key)
  ./easy-cs-ai-vm-web.sh      VM web     (<chat interface>)

What is left to do once the VMs are up:
  1. Run each script as root on its VM, the engine VM first.
  2. On the engine VM, read the API key and the URL of each model:
       sudo easy-cs-ai proxy nginx show-key
       easy-cs-ai proxy nginx list-upstreams
  3. Let the web VM reach the engine VM on the HTTPS port of its proxy
     (443 unless you set --port): firewall, security group.
  4. On the web VM, link each model:
       sudo easy-cs-ai chat-interface librechat add-endpoint <name> <url> \
         --model <model> --api-key-file <file>
     <name> is free, <url> is the one read in step 2, <file> holds the key
     (mode 0600, or - for stdin).
     With the default self-signed certificate, copy the certificate of the
     engine VM (/etc/easy-cs-ai/nginx/server.crt) to the web VM and add
     --ca-file <file>. The host name in <url> must be the server name of the
     engine VM's proxy, which is the one in its certificate.
Until step 4 is done, the model list of LibreChat stays empty.
```

Rules for the text:

- **Fixed text, filled with what the configuration says.** The component names, the VM names and the models are those of the file (one `add-endpoint` line per model, with its `--model`). The address, the port, the endpoint name, the URL and the files stay placeholders: they do not exist yet.
- **The text is the validation's, the commands are the contract's.** It never invents an action or an option: a bats test checks that every action and option named in the text is in the `describe` of the script it names (`actions` of nginx, `action_options` of the LibreChat script, see [Contract additions](#contract-additions)). The list is given only by a package whose scripts have them, so the CLI never gives a command that fails.
- **Who writes which lines.** The heading (`Two scripts written…` and the file of each VM) is printed by the generator from what it wrote, and is never part of `next_steps`. The lines from `What is left to do` to the last one are the validation's, with no file name of a script in them (step 1 says "each script", not its path).
- With `--config-only`, no script is produced: the generator prints one line naming the file written instead of the list. `--json` needs `--config`, which excludes `--config-only`, so this line is never in a `next_steps`.
- With one VM, nothing is printed and there is no `next_steps`: the output is today's.

### Where they are computed

The list is computed by the validation of [spec: capabilities](spec-capabilities.md#config-validate), in the same place as the warnings, from the file and the `describe` of the shipped scripts: nothing of the machine, and no script written. The condition, the text and the models filled in are a rule of the capability, not of the generator ([rule 4](spec-journey.md#rules)), so improving them improves both ways at once. It follows that:

- `generate` computes nothing of the list: it prints its own heading (the scripts written), then the list after writing the scripts, and puts the list in its `--json`.
- `config validate --json` returns it too, so a program can show it before generating; it needs nothing from the machine.
- The list a person reads (from `What is left to do`) and the array `next_steps` are the same lines in the same order.
- `guide.txt` carries the procedure for a reader that is a model. It is written by hand, not generated, and a test keeps it in step with the list (see [Definition of done](#definition-of-done)).

## Contract additions

Two actions change, and the existing calls behave exactly as today.

### `proxy nginx list-upstreams`

```text
proxy nginx list-upstreams
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
chat-interface librechat add-endpoint <name> <url> [--model <model>] [--api-key-file <path|->] [--ca-file <path>]
```

| Option | Meaning |
| --- | --- |
| `--api-key-file <path>` | The API key the endpoint expects. A file of mode `0600` or stricter, or `-` for stdin, never on the command line (see [Secrets](spec-script-contract.md#secrets)). Without it, the placeholder key of the local link |
| `--ca-file <path>` | PEM certificate (or CA) the endpoint is verified against, for an engine VM whose proxy uses a self-signed or private-CA certificate. Without it, the system trust store. Verification is never turned off |

- **The key is stored as a secret**: in a file of mode `0600` owned by root under `/etc/easy-cs-ai/secrets/`, referenced by the api container through its environment file, and **never written in `librechat.yaml`**, in the state, in the logs or in `--dry-run`. The path goes in the state `secrets`, the value nowhere.
- **The certificate is public**: copied to `/etc/easy-cs-ai/librechat/`, mounted read-only in the api container and trusted there. The endpoints share one bundle, rebuilt from the certificates of all of them, since the container takes one file.
- Both options are declared under `action_options` of `add-endpoint` in `describe` (they are not options of the configuration), so a program can discover them.
- Like today, the action recreates only the `api` container, and only when the rendered files changed. It is idempotent: the same arguments change nothing, a new key or certificate replaces the old one. `remove-endpoint` removes the entry, its key file and its share of the bundle.
- A remote endpoint is recorded in the state `endpoints` like a local one (`name`, `url`, `model`), with the key file in `secrets`.
- `easy-cs-ai add` never passes these options: it links models of an engine of the same machine. The remote link is made by hand, with the component action.
- **To check before implementing**: that LibreChat 0.8.7 reads the key of a custom endpoint from an environment variable reference in `librechat.yaml`, and that `NODE_EXTRA_CA_CERTS` is honoured by the image. If either fails, the mechanism changes, not the options above.

## What does not change

- The one-VM session, its output, its generated script, the configuration it writes and the JSON of `generate` and `config validate`, byte for byte for the same answers that give a stack able to finish. **Two exceptions, which come from the specs this one relies on and not from the VMs**:
  - [spec: model fit](spec-model-fit.md#declared-resources): the text of the recommended VM in the summary changes (the RAM margin of the reference stack, 4 GB instead of 6, the disk margin, the source of each part, the `not covered` line), and a one-VM session that names no model gets a recommendation, with the warning that the models come on top when the stack has an engine ([a stack with no model](spec-model-fit.md#a-stack-with-no-model)). The script and the configuration are not concerned.
  - [spec: config](spec-config.md#what-a-model-needs): a one-VM file whose model needs a proxy or llmfit that the file does not give is now refused by `config validate` and `generate --config` (`missing_requirement`, exit 2), where it passed the validation and `apply` stopped at the model step (exit 4). `apply` keeps exit 4 for it. A session that would have written such a file shows the error at its summary.
- `apply` on a file with no `vm` and `config validate` on a file that can finish, the configuration format of the one-VM case, `schema_version`, the exit codes of every command (apart from the case above).
- The loopback link and `network_mode: host` of the one-VM stack, and the `add` / `remove` orchestration, which stay the rule when engine and chat interface share a machine.
- Every other script of layer 1.

## Implementation notes

- `install_scripts/lib/cli-apply.sh`: the `vm` field (shape, all-or-none, uniqueness per VM), the slices, `--vm`; the validation stays one `jq` program, run per slice, with the paths of the file as written.
- `vm_script/lib/questions.sh`: the question at step 1, and the session run per VM, with the selection, options and models state per pass (a pass restricts the types it asks and starts from an empty selection).
- `vm_script/generate.sh`: one script per slice, the VM in the names and the header, the all-or-nothing write, and the printing of the next steps, which it receives from the validation. The script template is unchanged: one slice, the same template.
- `install_scripts/lib/cli-ai.sh`: `config schema`, `config validate` and `generate --json` for the `vm` field and the documents above, and the computation of the next steps (the condition, the text, the models filled in).
- `install_scripts/proxy/nginx.sh`: the `list-upstreams` action (JSON on stdout, read-only, listed in `actions` of `describe`), built on the `public_url` the script already has.
- `install_scripts/chat-interface/librechat.sh` and `templates/librechat/`: the two options, the key and certificate files, the compose change for the bundle.
- `install_scripts/guide.txt`: the VM question and the next steps.
- The sizing stays in `provisioning llmfit plan`: the session calls it with the components of the VM of the pass and holds no figure of its own ([rule 4](spec-journey.md#rules)). The figures come from the `resources` of the components, see [spec: model fit](spec-model-fit.md#declared-resources).
- `install_scripts/provisioning/llmfit.sh`, and the `describe` of the shipped scripts: `--component`, `<model>@<engine>`, `resources`, the stack with no model, as specified in [spec: model fit](spec-model-fit.md#declared-resources). This is a prerequisite of the `web` pass's recommendation, not of the generation of the scripts. A package that ships no `provisioning/llmfit` script has no `plan`: the passes then print no recommendation and say so, see [a stack with no model](spec-model-fit.md#a-stack-with-no-model).

## Definition of done

- `bats` tests of the configuration: see [spec: config](spec-config.md#definition-of-done) (the `vm` field, its errors, the slices, `apply --vm`).
- `bats` tests of the generator, answers on stdin: the default answer gives the same script as before (compared with a script generated by the previous behaviour, the answers of that behaviour with the empty line of the VM question added, and the existing answers files of the tests and of the parity scenarios updated the same way); answer `2` gives one configuration with the `vm` of each component, models only on the engine VM and each with its `vm` and `engine`, a `nginx` on each VM, and one script per VM; cancel after the first pass writes nothing; `--dry-run` writes nothing; `--output` and `--config-only` names; one script unwritable keeps none; the header line; the question absent when no engine or no chat interface is shipped; a model named on a pass with no proxy proposes nginx (`y` adds it to that VM with its options, `n` removes the models of that engine, asked again after a redo of the components, not asked for a `protected` engine or when no proxy is shipped); the `engine_unreachable` warning in the summary for an engine VM with no proxy and no model; an engine VM with a model and no proxy refused with `missing_requirement` before any script is written (and the warning not given for it).
- `bats` tests of the recommended VM of each pass, with a fake llmfit and fake components that declare `resources` (see [spec: model fit](spec-model-fit.md#definition-of-done)): the `engine` pass calls `plan` with its models (as `<model>@<engine>`) and its own components and no share for the chat interface; the `web` pass calls it with its components and no model, and prints the stack with no model, without the `models not included` line (no engine on that VM), while an engine VM with no model has it; the session computes no figure.
- `bats` tests of `generate --config` on a file with `vm`: the scripts, each embedding its slice without `vm` (extracted and compared), `--json` with `scripts` and `next_steps`, and the same files for the same decisions as the session.
- Tests of the next steps: computed by the validation from the file and the shipped `describe`s, with no script name in them (the same list whatever `--output` is); the heading of the scripts written is the generator's and is not in `next_steps`; only for several VMs; step 1 alone for a layout other than one engine VM and one chat-interface VM, or when the engine VM holds no model in the file (with a proxy: no warning, since the VM can finish and its models come later), or when the engine VM has no proxy (then it has no model, since a model would make the file invalid, and the `engine_unreachable` warning is there), or when its engine is `protected`, **with or without a proxy on its VM** (a `protected` engine needs no proxy and gets no warning; with a proxy, `list-upstreams` would be empty; either way the web VM could reach the engine directly, which the steps do not describe), with a test for each of the two cases; a validation of one slice alone with neither `next_steps` nor `engine_unreachable`; the models of the file filled in; the same lines in the text of `generate`, in `generate --json` and in `config validate --json`; only options present in the `describe` of the LibreChat script; and `guide.txt` names the same commands.
- Parity: a scripted two-VM session and the equivalent hand-written file give the same configuration, the same plan (`config validate --target fresh --json`) and the same scripts ([parity test](spec-journey.md#parity)).
- `bats` tests of `list-upstreams` in `EASY_CS_AI_ROOT` mode: the public URL of each upstream (port 443 and another port, with the server name), `[]` when there is none, exit 4 when the proxy is not installed, no root needed, nothing journaled, the API key never printed, and the action listed in `actions` of `describe`.
- `bats` tests of `add-endpoint` in `EASY_CS_AI_ROOT` mode: without the new options the rendered files are identical to today's; with `--api-key-file` (file, stdin, too-open file refused with exit 2, never in `librechat.yaml`, state, logs or `--dry-run`); with `--ca-file` (copied, bundle rebuilt, an invalid PEM refused); idempotence; `remove-endpoint` removes the key and the certificate.
- Integration test on two VMs: both scripts run, the link made as in the next steps, a message answered through the web VM, the scripts run a second time change nothing. The existing single-VM test stays as it is.
- `shellcheck` clean; `--help` of the generator and `guide` consistent with this spec.

## Open questions

- **Sizing of the web VM.** Settled by [declared resources](spec-model-fit.md#declared-resources) and [a stack with no model](spec-model-fit.md#a-stack-with-no-model): the `web` pass is sized from what nginx and LibreChat declare. What stays open is the quality of the figures (LibreChat's 2 GB of RAM is a guess, about three times the idle measure of 694 MiB), which is the calibration of the [estimated margin](spec-model-fit.md#open-questions), not something specific to this spec.
- **A command to finish the link.** `add-endpoint` by hand is the smallest thing. A higher-level command that reads the key and the certificate from the engine VM would be easier to use, and needs access from one VM to the other that the project does not assume.
- **The models listed by the endpoint.** With `--model`, LibreChat shows that model only (`fetch: false`). Without, it fetches the list of the engine, through the key and the TLS, which adds a network dependency at start. To settle with the first real test.
- **Several engine VMs, or several interfaces.** The format allows them, and a model says which engine VM it goes to with its [place](spec-config.md#where-a-model-goes) (`vm` and `engine`). What stays open is the rest: the next steps assume one engine VM and one chat-interface VM, and with several, which chat interface links to which model, and with what name, is not described. Each link is an `add-endpoint`, so no new mechanism is needed.
- **The address of the engine VM and its certificate.** A self-signed certificate is valid for the server name given to the engine VM's nginx, so the web VM must use that very name. When the address is not known at generation, the administrator re-runs `install proxy nginx --server-name <name>` on the engine VM, which renews the certificate; this could be said in the next steps.
- **Structured next steps.** `next_steps` is an array of strings, enough for an agent that reads them and for the text. If a program has to act on a step (find the `add-endpoint` command of a model), the entries would become objects (`id`, `vm`, `text`); documents of one VM are not concerned.
- **A `protected` engine on its own VM.** No shipped engine is `protected`, so the next steps give step 1 only for one, whether its VM has a proxy or not. Linking a chat interface to such an engine would need its URL and its key, which the [contract](spec-script-contract.md#describe) does not say how a `protected` engine publishes (a proxy action does not apply, since `add` does not front it). To specify with the first `protected` engine.
- **More than two VMs.** With any layout other than one engine VM and one chat-interface VM, only step 1 is given and the links between the VMs are not described. A rule for a pair per link would extend it.
- **Going back to the first VM** from the second pass, without cancelling.
- **The next steps in the header** of each script, so that a script found on a VM says what is left to do. Only the VM line is in this version.
- **The version of the format.** `vm` is added without a bump (see [spec: config](spec-config.md#compatibility-of-the-vm-field)); a bump to 2 when `vm` is present would give a clearer message to an older CLI, and is to be reconsidered if configurations circulate across CLI versions.
