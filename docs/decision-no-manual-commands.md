# Decision: no `easy-cs-ai` command typed on a VM

[← Back to docs](README.md)

**Status:** proposed, not implemented. This page fixes the principle and the shape of the follow-up scripts; the details that stay open are in [open questions](#open-questions), and the rest of the specs ([several VMs](spec-multi-vm.md#follow-up-scripts), [generator](spec-vm-generator.md#follow-up-scripts), [journey](spec-journey.md#6-produce)) follow it.

## Context

The generator produces one post-install script per VM, so the installation of a VM needs no command. What is left once the VMs are up is another matter: when a model of an engine VM is shown in the chat interface of **another** VM, the [next steps](spec-multi-vm.md#next-steps) tell the administrator to connect to the VMs and type `easy-cs-ai component proxy nginx show-key`, `list-upstreams`, `status`, then `easy-cs-ai component chat-interface librechat add-endpoint …` with a URL, a key file and a certificate to copy. It works, but:

- the administrator has to know the CLI, its `component` command and its options, which is what a generated script was meant to spare them;
- the commands are filled in by hand (the URL, the key file, the address) and the order matters, so a mistake is found late (the model list of the chat interface stays empty);
- a program or a page that provisions the VMs ([CloudStack](spec-cloudstack.md)) can hand over a script to run, not a procedure to read.

## Decision

**A person never types an `easy-cs-ai` command on a VM.** What they do on a VM is run a script that the generator wrote, or nothing at all when the cloud runs it (user-data). The `easy-cs-ai` command stays the tool of the scripts and of the experts (`apply`, `component`, `exec`, `status` are all still there); it is no longer part of the path that the documentation, the generator and the pages show.

To make that true, `script` writes, next to the post-install script of each VM, the scripts of **the steps that follow**, when the configuration has any:

| Script | Runs on | What it does | When it exists |
| --- | --- | --- | --- |
| **Post-install script** (`<output>-<vm>.<ext>`, as today) | each VM, once, as root (cloud-init or by hand) | Installs the package and runs `apply` on the slice of the VM. On an engine VM that holds a [steps link](spec-multi-vm.md#validation) it ends by writing the **link file** of the VM (see below) | Always |
| **Link script** (`<output>-<vm>-link.<ext>`) | a chat-interface VM that shows models of other VMs, as root | Takes the link files of the engine VMs it shows models of, and connects each model with the `add-endpoint` action (URL, key and certificate read from the link file) | When the VM holds the chat interface of at least one steps link |

- **The link file** is what the engine VM gives to the VMs that show its models: for each model of a steps link, its name and the URL a client uses, plus the API key and the certificate of the proxy (and the names and addresses the certificate covers). It is **written at run time, on the engine VM**, by the post-install script (it reads what the proxy already knows: `list-upstreams`, `show-key`, `certificate_names`), mode `0600`, at a fixed path. It is **not generated**: the principle that [no secret travels through a generated script](spec-multi-vm.md#principles) is unchanged, the key is produced on the VM and only moves when the administrator moves the file.
- **The administrator's part shrinks to two acts that are not commands of ours:** let the VMs reach one another (firewall, security group: it is the cloud's, no VM script can do it) and **copy the link file** of each engine VM to the chat-interface VM (any means: `scp`, the cloud's console, a shared volume), then run the link script on it with the file as argument.
- **Scripts never prompt**, are idempotent (running the link script twice changes nothing; a new link file replaces the endpoint of the old one), and say what they did or what is missing (a model that the link file does not hold, a certificate that does not cover the host) with the [contract exit codes](spec-script-contract.md#exit-codes).
- **What the scripts know comes from the configuration, as the post-install script does.** The link script embeds the list of the models it must connect (the `links` whose chat interface is on its VM) and checks it against the link files; the post-install script of the engine VM embeds the slice it already has, so the re-run that renews a self-signed certificate for a new address no longer needs the administrator to remember "the options the proxy was installed with": the script already knows them.

The steps that were commands of the administrator are now:

| Today (next steps) | With follow-up scripts |
| --- | --- |
| 1. Run each script as root, engine VMs first | Unchanged (cloud-init does it when the script is the user-data) |
| 2. On the engine VM: `show-key`, `list-upstreams`, `status` | Done by the post-install script, which writes the link file |
| 3. Let the VMs reach the engine VM (firewall, security group) | Unchanged: cloud side, no script. The [CloudStack page](spec-cloudstack.md) creates the rule itself |
| 4. On the chat-interface VM: `add-endpoint` per model, `--ca-file`, `--api-key-file`, and the re-run of `install proxy nginx` if the address changed | Copy the link file, run the link script with it. The certificate and the options are in the script and in the file |

## Why

- **The documentation promises a script, not a procedure.** The generated script is the unit a person or a cloud understands; a command to type is a second product to learn.
- **The commands are known by the generator.** The VM names, the models, the endpoint name (`<vm>-<engine>-<model>`), the proxy options and the `--model` are all in the configuration: generating the script removes the places where a person fills a placeholder wrongly.
- **It fits what provisions the VMs.** A script is what CloudStack gives to a VM at first boot ([generated per VM](spec-cloudstack.md)); the link script is the next thing to hand over, and the page can show which VM it is for and in which order.
- **The principles of the project hold.** The key is never generated into a script, `script` still never prompts, the scripts still contain no logic of their own (the actions are the contract's: `add-endpoint`, `list-upstreams`, `show-key`), and the CLI is still what does the work.

## Consequences

- `script` writes more files for a configuration with a steps link: one link script per chat-interface VM. They are written together with the post-install scripts, **all or nothing**, and the stale ones are listed like the others ([generator](spec-vm-generator.md#follow-up-scripts)).
- The [next steps](spec-multi-vm.md#next-steps) become short instructions that name the **scripts and the link file**, not commands. They are still computed by the validation; the file names are printed by `script`, which knows them, as the heading already is.
- The post-install script of an engine VM has one more output (the link file) and `show-key` and `list-upstreams` get a caller that is not a person; they stay actions of the contract, and `show-key` stays the only action that prints a secret.
- A program or an agent never types the commands either: `guide` tells it to hand the scripts and the instructions to the user ([rule 3 of the journey](spec-journey.md#rules)); the commands it may not run on its own ([`show-key` included](spec-journey.md#what-a-program-never-does-on-its-own)) are in the scripts, run by the user.
- Testing changes: the integration scenario [`multi-vm.sh`](../tests/integration/README.md) runs the follow-up scripts instead of the commands of the next steps, and a bats test checks that a link script and a link file give the endpoint that the commands gave.

## Alternatives considered

| Option | Why not |
| --- | --- |
| Keep the commands, document them better | The administrator still has to learn the CLI and fill the placeholders; the point is to remove that |
| One script that links the VMs by itself, over SSH from the engine VM or the web VM | The project assumes no access from one VM to another ([spec: several VMs](spec-multi-vm.md#open-questions)); it would need keys, hosts and ports we have no way to know. Kept as an option of the link script, see the open questions |
| Put the key in the generated link script | A script is a snapshot meant to be kept, shared and passed as user-data; the key does not exist when it is generated (principle 4 of [spec: several VMs](spec-multi-vm.md#principles)) |
| A shared place where the engine VM publishes its link file (an object store, the CloudStack API) | Not available on every cloud and the key would live outside the VMs; may be added later with the CloudStack integration |

## Open questions

- **How the link file travels.** By hand (a copy) is the smallest thing and assumes nothing. An `--from <user@host>` option of the link script, which reads the file over SSH, would remove the copy for those who have SSH between their VMs. To settle with the first real use.
- **Which address the URL uses.** The engine VM's address is usually not known when the scripts are generated, see [`engine_address_unknown`](spec-multi-vm.md#validation). The link file holds the names and addresses its certificate covers; the link script needs a rule to choose the host (the first that answers on the HTTPS port, or an option `--host`). The re-run that renews the certificate for another address becomes an option of the post-install script or a script of its own: to specify.
- **Where the link file is, and its lifetime.** A fixed path under `/var/lib/easy-cs-ai/`, mode `0600`, kept by `uninstall` and removed with `--purge` like the other secrets, or written only on demand. A key rotated after the file was written makes it stale: the link script must say so.
- **The size of the post-install script.** The limit of the user-data (32 KB by default on CloudStack, [generator](spec-vm-generator.md#open-questions)) must hold with the code that writes the link file. The link script is not user-data and has no such limit.
- **What `next_steps` holds.** It stays an array of strings computed by the validation with no file name; whether the strings name "the link script of the VM `web`" in words, or are objects with the VM and the step ([structured next steps](spec-multi-vm.md#open-questions)), is to settle with the structured steps.
