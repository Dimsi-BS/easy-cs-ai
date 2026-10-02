# Generators directory

[← Back to project root](../README.md)

This directory contains the script generators shared across layers. They take the install-and-configure scripts and produce parameterless versions with fixed parameters, for both the install scripts layer and the VM post-install layer.

Both generators are invoked from the layer 2 CLI through the `generate` command (`generate install-script` and `generate vm-script`, see [docs/cli-commands](../docs/cli-commands.md)).

See also: [install_scripts](../install_scripts/README.md) and [vm_script](../vm_script/README.md), the layers whose scripts these generators produce.
