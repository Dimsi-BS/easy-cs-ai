# VM script directory

[← Back to project root](../README.md)

This directory contains the VM script layer (layer 3): the interactive generator of the VM post-install script and of the [configuration file](../docs/spec-config.md) it embeds. There is no generator for the layer 1 install scripts, see [decision: VM script generator](../docs/decision-vm-generator.md).

It is invoked from the layer 2 CLI through two commands: `easy-cs-ai config edit` (the interactive session, which creates or edits the configuration) and `easy-cs-ai script <file>` (the scripts, from a configuration, with no prompt), see [docs/cli-commands](../docs/cli-commands.md).

`config edit` is **interactive**: run by an administrator, it guides the choices (VMs, components, dependencies, options, models and the chat interface that shows them) and writes a configuration, after asking the name of the file to write; with a file it opens an existing configuration to add or change VMs. `script` turns a configuration into a small self-contained script (one per VM of the file, see [spec: several VMs](../docs/spec-multi-vm.md)) that downloads the package from a pinned source and runs `easy-cs-ai apply` on that configuration. Scripts and CLI never prompt, `config edit` is the only exception. How they behave is in [spec: VM script generator](../docs/spec-vm-generator.md).

Contents: `config.sh` (the session) and `script.sh` (the scripts), `lib/generator.sh` (the code they share), `lib/questions.sh` (the question engine) and `templates/vm-script.sh.tpl` (the shape of the generated script).
