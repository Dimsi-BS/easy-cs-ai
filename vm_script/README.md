# VM script directory

[← Back to project root](../README.md)

This directory contains the VM script layer (layer 3): the interactive generator of the VM post-install script and of the [configuration file](../docs/spec-config.md) it embeds. There is no generator for the layer 1 install scripts, see [decision: VM script generator](../docs/decision-vm-generator.md).

It is invoked from the layer 2 CLI through the `generate` command (`generate`, or `generate --config-only` for the configuration alone, see [docs/cli-commands](../docs/cli-commands.md)).

The generator is **interactive**: run by an administrator, it guides the choices (components, dependencies, options, models) and writes a configuration, then a small self-contained script that downloads the package from a pinned source and runs `easy-cs-ai apply` on that configuration. Scripts and CLI never prompt, the generator is the only exception. How it behaves is in [spec: VM script generator](../docs/spec-vm-generator.md).

Contents: `generate.sh` (the generator), `lib/questions.sh` (the question engine) and `templates/vm-script.sh.tpl` (the shape of the generated script).

See also: [package](../package/README.md), the layer this script downloads and runs.
