# Spec: two VMs, the engine and the web interface apart

[← Back to docs](README.md)

**Status:** proposed, not implemented. The open questions at the end do not block starting.

## Purpose

Today a stack lives on **one machine**: the engine, the proxy and the chat interface share it, and the chat interface reaches the engine on the loopback (see [decision: LibreChat install](decision-librechat-install.md#4-reaching-the-models-from-the-container)). An administrator may want the inference engine on one VM (often the costly one, with a GPU) and the web interface on another, small one.

This spec lets the [generator](spec-vm-generator.md) produce **two scripts**, one per VM, and says what the administrator does once the two VMs are running. It adds no deployment model: each VM is a stack like today's, and the link between them is made by hand afterwards.

## Principles

1. **One VM stays as it is.** The choice offered is "one VM" by default, and the answers that give a one-VM script today give the same script, byte for byte. Nothing in this spec changes the loopback link, the `add` orchestration, the configuration format or the exit codes of the one-VM case.
2. **Two configurations, no new field.** Each VM gets an ordinary [configuration](spec-config.md) that `apply` and `generate --config` already understand. `schema_version` stays 1. The configuration does not know that another VM exists.
3. **The link is finished by the administrator, once both VMs are up.** The address of the engine VM and its API key do not exist when the scripts are generated, so nothing about them goes into a script. The generator tells the administrator what is left to do (see [Next steps](#next-steps)).
4. **No secret travels through a generated script.** The API key is generated on the engine VM, as today (see [Secrets](spec-script-contract.md#secrets)), and read from there on demand with `proxy nginx show-key`.

## Topology

| | Engine VM | Web VM |
| --- | --- | --- |
| Types | `provisioning`, `proxy`, `engine` | `proxy`, `chat-interface` |
| Typical content | `llmfit`, `nginx`, `ollama` (or `vllm`) and the models | `nginx`, `librechat` |
| Models | All of them | None |
| Reached by | The web VM, over HTTPS with the API key, through its proxy | The browsers, over HTTPS on the site port of its proxy |

- The engine stays on its loopback and the proxy exposes it, as `add` already does for any engine that is not `protected`. Nothing new on the engine side: its configuration is the one an administrator who wants an API-only VM writes today. Its models carry no chat interface, since the file lists none ([`models`](spec-config.md#models)).
- LibreChat `requires` nginx (for its web site), not an engine, so the web VM validates and installs on its own. It comes up with **no model**: its selector is empty until the link is made.
- Both VMs carry an nginx, each with its own options (name, certificate strategy, ports): they are two different machines.
- The proxy is **not optional** on the engine VM: without it nothing can reach the engine from the other VM. The session refuses `none` for it, with that reason.
- One engine VM and one web VM. Several engine VMs for one interface, or several interfaces for one engine VM, are not specified (see [open questions](#open-questions)); nothing in the design forbids them, as each link is one `add-endpoint`.

## In the session

The session is the [journey](spec-journey.md) walked once per VM.

### The question

At [step 1](spec-journey.md#1-discover), when the package ships at least one engine and one chat interface, the session asks:

```text
One VM for everything (1), or the web interface on a second VM, apart from the inference engine (2)? [1]
```

- Default `1`, which runs the session exactly as before. With nothing shipped to split (no engine or no chat interface), the question is not asked.
- Answered `2`, the session runs the steps 2 to 5 **twice**, over the types of each role (see [Topology](#topology)): first the engine VM, then the web VM. A pass is the session as it is today, restricted to those types; the models step belongs to the first pass only.
- Each pass ends on its own [summary](spec-journey.md#5-validate-show-confirm) (components in install order, options, models, platforms, warnings, and the recommended VM of the engine pass), with the same confirm / redo (`c`, `o`, `m`) / cancel. Cancelling at any point cancels everything: nothing is written, exit 0.
- The recommended VM of the engine pass comes from `provisioning llmfit plan` **without** `--chat-interface`, so it carries no share for an interface that is not on this VM. The web VM has no recommendation in this version (see [open questions](#open-questions)).
- The [package source](spec-vm-generator.md#package-source) is asked once and is the same for both scripts.

### What is written

| Mode | One VM (unchanged) | Two VMs |
| --- | --- | --- |
| Script | `./easy-cs-ai-vm.sh` | `./easy-cs-ai-vm-engine.sh` and `./easy-cs-ai-vm-web.sh` |
| `--config-only` | `./easy-cs-ai.json` | `./easy-cs-ai-engine.json` and `./easy-cs-ai-web.json` |

- With `--output <path>`, the role is inserted before the extension: `--output vm.sh` gives `vm-engine.sh` and `vm-web.sh`.
- The two files are written together: if one cannot be written, neither is kept.
- `--dry-run` runs the whole session and prints both results to stderr.
- The header of each script gains one line, `VM role: engine (1 of 2)` or `web (2 of 2)`, so that a script found on a VM says which side of a pair it is. One-VM scripts have no such line.
- The size warning (32 KB) applies to each script.

### Next steps

After the files are written, and only for two VMs, the session prints (on stderr, not asked to confirm) what remains:

```text
Two scripts written, to run on two different VMs:
  ./easy-cs-ai-vm-engine.sh   engine VM  (<engine> behind HTTPS and an API key)
  ./easy-cs-ai-vm-web.sh      web VM     (<chat interface>)

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

- **Fixed text, filled with what the configuration says.** The component names and the models are those of the two configurations (one `add-endpoint` line per model, with its `--model`). The address, the port, the endpoint name, the URL and the files stay placeholders: they do not exist yet.
- **The text is the generator's, the commands are the contract's.** It never invents an option: a bats test checks that every option named in the text is in the `describe` of the script it names (`action_options` of the LibreChat script, see [Contract additions](#contract-additions)). The text is printed only by a package whose LibreChat script has them, so the generator never gives a command that fails.
- With `--config-only`, no script is produced and the step is one line naming the two files written.
- `generate --config <file>` produces one script from one file, does not know that it is half of a pair, and prints no next steps.

## For a program

There is no flag for two VMs, and no field: the configuration does not carry the topology. A program that wants two VMs, or an agent working for a person, does what the session does by hand:

1. writes two configurations, one per role (the types of the [topology](#topology)), with the options of each VM;
2. runs `generate --config <file>` on each, with the same package source;
3. tells the person the [next steps](#next-steps).

The text of the next steps is in [`guide.txt`](../install_scripts/guide.txt), which is how an agent that has only the binary gets it; it is the same wording as the session's, and a test checks that the two name the same commands. The two-VM session and this procedure give the **same two configurations and the same two scripts** for the same decisions, which extends the [parity test](spec-journey.md#parity).

This is a deliberate exception to [rule 2](spec-journey.md#rules) of the journey ("a question is a field"): the answer to the VM question fills no field, it decides how many configurations come out. The journey spec carries a note to that effect. Another way would be a `--split` argument of `generate`; it is not retained because the two VMs need different options (the server name of each nginx), which one configuration cannot hold without a new field (see [open questions](#open-questions)).

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

- The one-VM session, its summary, its output and its generated script, byte for byte for the same answers.
- `apply`, `config validate`, the configuration format, `schema_version`, the exit codes of every command.
- The loopback link and `network_mode: host` of the one-VM stack, and the `add` / `remove` orchestration, which stay the rule when engine and chat interface share a machine.
- Every other script of layer 1.

## Implementation notes

- `vm_script/lib/questions.sh`: the question at step 1, and the session run per role. The selection, options and models state is per pass, so a pass restricts the types it asks and starts from an empty selection.
- `vm_script/generate.sh`: two outputs, the role in the names and in the header, the atomic pair, and the next steps. The script template is unchanged: two configurations, the same template.
- `install_scripts/chat-interface/librechat.sh` and `templates/librechat/`: the two options, the key and certificate files, the compose change for the bundle.
- `install_scripts/guide.txt`: the two-VM procedure and the next steps.
- The sizing stays in `provisioning llmfit plan`: the session calls it without `--chat-interface` and holds no figure of its own ([rule 4](spec-journey.md#rules)).

## Definition of done

- `bats` tests of the generator, answers on stdin: the default answer gives the same script as before (compared with a script generated by the previous behaviour); answer `2` gives two configurations with the right types, models only in the engine one, and a `nginx` in each; `none` refused for the proxy of the engine VM; cancel after the first pass writes nothing; `--dry-run` writes nothing; `--output` and `--config-only` names; one file unwritable keeps neither; the header role line; the question absent when no engine or no chat interface is shipped.
- A test that the next steps are printed only for two VMs, carry the models of the configuration, and name only options present in the `describe` of the LibreChat script; and that `guide.txt` names the same commands.
- Parity: a scripted two-VM session and the two hand-written configurations give the same configurations, the same plans (`config validate --target fresh --json` of each) and the same scripts.
- `bats` tests of `add-endpoint` in `EASY_CS_AI_ROOT` mode: without the new options the rendered files are identical to today's; with `--api-key-file` (file, stdin, too-open file refused with exit 2, never in `librechat.yaml`, state, logs or `--dry-run`); with `--ca-file` (copied, bundle rebuilt, an invalid PEM refused); idempotence; `remove-endpoint` removes the key and the certificate.
- Integration test on two VMs: both scripts run, the link made as in the next steps, a message answered through the web VM, the script run a second time changes nothing. The existing single-VM test stays as it is.
- `shellcheck` clean; `--help` of the generator and `guide` consistent with this spec.

## Open questions

- **Sizing of the web VM.** No figure in this version. The data exists (the 4 GB of the chat interface in the [estimated margin](spec-model-fit.md#estimated-margin), 12 GB of free disk for its images, see [LibreChat](decision-librechat-install.md#2-the-stack-its-pinning-and-its-unit)); `plan` would have to answer for a stack with no model, which it refuses today.
- **Reading the URLs of the engine VM.** The next steps read them with `jq` in the state file, which is not a command of the CLI. A way to print them (an action of the proxy, or `status`) would be cleaner.
- **A command to finish the link.** `add-endpoint` by hand is the smallest thing. A higher-level command that reads the key and the certificate from the engine VM would be easier to use, and needs access from one VM to the other that the project does not assume.
- **The models listed by the endpoint.** With `--model`, LibreChat shows that model only (`fetch: false`). Without, it fetches the list of the engine, through the key and the TLS, which adds a network dependency at start. To settle with the first real test.
- **Several VMs.** More than one engine VM, or several interfaces. Each link is an `add-endpoint`, so it needs no new mechanism, but the session and the next steps assume one of each.
- **The address of the engine VM and its certificate.** A self-signed certificate is valid for the server name given to the engine VM's nginx, so the web VM must use that very name. When the address is not known at generation, the administrator re-runs `install proxy nginx --server-name <name>` on the engine VM, which renews the certificate; this could be said in the next steps.
- **Going back to the first VM** from the second pass, without cancelling.
- **The role line in the header** and the same next steps copied in the header of each script, so that a script found on a VM says what is left to do. Only the role line is in this version.
- **Rule 2 of the journey.** Whether the exception above should instead become a field of the configuration (a `role`) if a second topology ever appears.
