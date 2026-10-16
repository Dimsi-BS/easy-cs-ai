# Spec: two VMs, the engine and the web interface apart

[← Back to docs](README.md)

**Status:** proposed, not implemented. The open questions at the end do not block starting.

## Purpose

Today a stack lives on **one machine**: the engine, the proxy and the chat interface share it, and the chat interface reaches the engine on the loopback (see [decision: LibreChat install](decision-librechat-install.md#4-reaching-the-models-from-the-container)). An administrator may want the inference engine on one VM (often the costly one, with a GPU) and the web interface on another, small one.

This spec lets one [configuration](spec-config.md) describe **several VMs**, lets the [generator](spec-vm-generator.md) produce **one script per VM**, and says what the administrator does once the VMs are running. It adds no deployment model: each VM is a stack like today's, and the link between them is made by hand afterwards.

The question "one VM or two?" is part of the [journey](spec-journey.md) like any other: a person answers it in the session, a program writes it in the configuration, and both end on the same file.

## Principles

1. **One VM stays as it is.** The question defaults to "one VM", a configuration with no `vm` is read as today, and the answers that give a one-VM script today give the same script, byte for byte. Nothing here changes the loopback link, the `add` orchestration, the exit codes or the JSON of the one-VM case.
2. **One configuration, one optional field.** A component may name its VM (`components[].vm`, see [spec: config](spec-config.md#several-vms)). The generator cuts the file into one **slice** per VM; each script embeds only its slice, with no `vm` field. A VM, and `apply` running on it, never see that another VM exists. `schema_version` stays 1.
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
- The engine stays on its loopback and the proxy exposes it, as `add` already does for any engine that is not `protected`. Nothing new on the engine side: its slice is the configuration an administrator who wants an API-only VM writes today. Its models are not linked to a chat interface of another VM ([spec: config](spec-config.md#models)).
- LibreChat `requires` nginx (for its web site), not an engine, so the `web` slice validates and installs on its own. It comes up with **no model**: its selector is empty until the link is made.
- Both VMs carry an nginx, each with its own options (server name, certificate strategy, ports): that is why the file may hold an entry per component **and per VM**.
- One engine VM and one web VM is what the session offers and what the [next steps](#next-steps) describe. The format and the generator take any number of VMs; several engine VMs for one interface, or several interfaces, are not specified (see [open questions](#open-questions)).

## Validation

The validation of [spec: config](spec-config.md#validation) applies, with the file cut into slices; its errors for `vm` are listed there. This spec adds **warnings**, which do not change the exit code, shown by `config validate`, by the summary of the session, and by `generate --config`:

| Code | When | Message (in substance) |
| --- | --- | --- |
| `engine_unreachable` | An engine is on a VM with no proxy, and a chat interface is on another VM | The engine listens on the loopback of its VM and nothing exposes it: the chat interface of the other VM cannot reach it. Add a proxy to that VM |

A warning has the same shape as the other warnings of [spec: capabilities](spec-capabilities.md#config-validate), with a `code` and the `vm` it is about.

## In the session

The session is the [journey](spec-journey.md) walked once per VM. It writes one configuration, whose components carry their `vm`.

### The question

At [step 1](spec-journey.md#1-discover), when the package ships at least one engine and one chat interface, the session asks:

```text
One VM for everything (1), or the web interface on a second VM, apart from the inference engine (2)? [1]
```

- Answered `1` (the default), the session runs exactly as before and writes no `vm`. With nothing shipped to split (no engine or no chat interface), the question is not asked.
- Answered `2`, the session runs the steps 2 to 5 **twice**, over the types of each VM (see [Topology](#topology)): first `engine`, then `web`. A pass is the session as it is today, restricted to those types; the models step belongs to the first pass only. Every component written gets the `vm` of its pass.
- Each pass ends on its own [summary](spec-journey.md#5-validate-show-confirm) (components in install order, options, models, platforms, warnings, and the recommended VM of the first pass), with the same confirm / redo (`c`, `o`, `m`) / cancel. Cancelling at any point cancels everything: nothing is written, exit 0.
- The recommended VM of the `engine` pass comes from `provisioning llmfit plan` **without** `--chat-interface`, so it carries no share for an interface that is not on this VM. The `web` VM has no recommendation in this version (see [open questions](#open-questions)).
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

The same file, written in one go: a program (or an agent working for a person) writes the configuration with the `vm` of each component, validates it with `config validate` (which cuts it into slices and checks each), then runs `generate --config <file>`, which gives the same scripts the session does. There is no other path and no other flag: the answer to the VM question **is** the `vm` fields, so that [rule 2 of the journey](spec-journey.md#rules) holds without exception, and `config schema` lists the field.

`generate --config <file> --json` extends its document for several VMs (see [spec: capabilities](spec-capabilities.md#commands)): `script` is `null` and `scripts` lists one entry per VM (`vm`, `path`, `bytes`, `written`, `package_version`, `package_format`), and `next_steps` carries the [next steps](#next-steps) as an array of strings. With one VM the document is unchanged.

The journey text of [`guide.txt`](../install_scripts/guide.txt) tells an agent to ask the user the VM question and to give the `vm` fields; a test checks that it names the same commands as the next steps.

## Next steps

After the scripts are written, when the file has several VMs, the generator prints on stderr (not asked to confirm) what remains, and puts the same lines in `next_steps` with `--json`. Step 1 is always there; steps 2 to 4 appear when a chat interface lies on a VM with no engine while an engine lies on another VM, which is the case this spec is about:

```text
Two scripts written, to run on two different VMs:
  ./easy-cs-ai-vm-engine.sh   VM engine  (<engine> behind HTTPS and an API key)
  ./easy-cs-ai-vm-web.sh      VM web     (<chat interface>)

What is left to do once the VMs are up:
  1. Run each script as root on its VM, the engine VM first.
  2. On the engine VM, read the API key and the URL of each model:
       sudo easy-cs-ai proxy nginx show-key
       jq -r '.upstreams[] | "\(.name) \(.url)"' /var/lib/easy-cs-ai/components/nginx.json
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
- **The text is the generator's, the commands are the contract's.** It never invents an option: a bats test checks that every option named in the text is in the `describe` of the script it names (`action_options` of the LibreChat script, see [Contract additions](#contract-additions)). The text is printed only by a package whose LibreChat script has them, so the generator never gives a command that fails.
- With `--config-only`, no script is produced and the step is one line naming the file written.
- With one VM, nothing is printed: the output is today's.

## Contract additions

Only the LibreChat `add-endpoint` action changes. Its calls without the new options behave exactly as today: `apiKey: "unused"`, the system trust store.

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

- The one-VM session, its summary, its output, its generated script and its JSON, byte for byte for the same answers.
- `apply` on a file with no `vm`, `config validate` on it, the configuration format of the one-VM case, `schema_version`, the exit codes of every command.
- The loopback link and `network_mode: host` of the one-VM stack, and the `add` / `remove` orchestration, which stay the rule when engine and chat interface share a machine.
- Every other script of layer 1.

## Implementation notes

- `install_scripts/lib/cli-apply.sh`: the `vm` field (shape, all-or-none, uniqueness per VM), the slices, `--vm`; the validation stays one `jq` program, run per slice, with the paths of the file as written.
- `vm_script/lib/questions.sh`: the question at step 1, and the session run per VM, with the selection, options and models state per pass (a pass restricts the types it asks and starts from an empty selection).
- `vm_script/generate.sh`: one script per slice, the VM in the names and the header, the all-or-nothing write, the next steps. The script template is unchanged: one slice, the same template.
- `install_scripts/lib/cli-ai.sh`: `config schema`, `config validate` and `generate --json` for the `vm` field and the documents above.
- `install_scripts/chat-interface/librechat.sh` and `templates/librechat/`: the two options, the key and certificate files, the compose change for the bundle.
- `install_scripts/guide.txt`: the VM question and the next steps.
- The sizing stays in `provisioning llmfit plan`: the session calls it without `--chat-interface` and holds no figure of its own ([rule 4](spec-journey.md#rules)).

## Definition of done

- `bats` tests of the configuration: see [spec: config](spec-config.md#definition-of-done) (the `vm` field, its errors, the slices, `apply --vm`).
- `bats` tests of the generator, answers on stdin: the default answer gives the same script as before (compared with a script generated by the previous behaviour); answer `2` gives one configuration with the `vm` of each component, models only on the engine, a `nginx` on each VM, and one script per VM; cancel after the first pass writes nothing; `--dry-run` writes nothing; `--output` and `--config-only` names; one script unwritable keeps none; the header line; the question absent when no engine or no chat interface is shipped; the `engine_unreachable` warning in the summary.
- `bats` tests of `generate --config` on a file with `vm`: the scripts, each embedding its slice without `vm` (extracted and compared), `--json` with `scripts` and `next_steps`, and the same files for the same decisions as the session.
- A test that the next steps are printed only for several VMs, carry the models of the file, and name only options present in the `describe` of the LibreChat script; and that `guide.txt` names the same commands.
- Parity: a scripted two-VM session and the equivalent hand-written file give the same configuration, the same plan (`config validate --target fresh --json`) and the same scripts ([parity test](spec-journey.md#parity)).
- `bats` tests of `add-endpoint` in `EASY_CS_AI_ROOT` mode: without the new options the rendered files are identical to today's; with `--api-key-file` (file, stdin, too-open file refused with exit 2, never in `librechat.yaml`, state, logs or `--dry-run`); with `--ca-file` (copied, bundle rebuilt, an invalid PEM refused); idempotence; `remove-endpoint` removes the key and the certificate.
- Integration test on two VMs: both scripts run, the link made as in the next steps, a message answered through the web VM, the scripts run a second time change nothing. The existing single-VM test stays as it is.
- `shellcheck` clean; `--help` of the generator and `guide` consistent with this spec.

## Open questions

- **Sizing of the web VM.** No figure in this version. The data exists (the 4 GB of the chat interface in the [estimated margin](spec-model-fit.md#estimated-margin), 12 GB of free disk for its images, see [LibreChat](decision-librechat-install.md#2-the-stack-its-pinning-and-its-unit)); `plan` would have to answer for a stack with no model, which it refuses today.
- **Reading the URLs of the engine VM.** The next steps read them with `jq` in the state file, which is not a command of the CLI. A way to print them (an action of the proxy, or `status`) would be cleaner.
- **A command to finish the link.** `add-endpoint` by hand is the smallest thing. A higher-level command that reads the key and the certificate from the engine VM would be easier to use, and needs access from one VM to the other that the project does not assume.
- **The models listed by the endpoint.** With `--model`, LibreChat shows that model only (`fetch: false`). Without, it fetches the list of the engine, through the key and the TLS, which adds a network dependency at start. To settle with the first real test.
- **Several engine VMs, or several interfaces.** The format allows them. The same engine component on two VMs makes `models[].engine` ambiguous (`ambiguous_engine`), and the next steps assume one of each. Each link is an `add-endpoint`, so no new mechanism is needed, but a model would need a way to say which VM.
- **The address of the engine VM and its certificate.** A self-signed certificate is valid for the server name given to the engine VM's nginx, so the web VM must use that very name. When the address is not known at generation, the administrator re-runs `install proxy nginx --server-name <name>` on the engine VM, which renews the certificate; this could be said in the next steps.
- **Going back to the first VM** from the second pass, without cancelling.
- **The next steps in the header** of each script, so that a script found on a VM says what is left to do. Only the VM line is in this version.
- **The version of the format.** `vm` is added without a bump (see [spec: config](spec-config.md#compatibility-of-the-vm-field)); a bump to 2 when `vm` is present would give a clearer message to an older CLI, and is to be reconsidered if configurations circulate across CLI versions.
