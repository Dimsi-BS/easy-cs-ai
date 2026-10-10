# Package directory

[← Back to project root](../README.md)

This directory contains the files specific to the packaging layer: the `easy-cs-ai` CLI dispatcher and the tarball/`.deb`/`.rpm` packaging definitions (see [docs/decision-packaging](../docs/decision-packaging.md)).

- `bin/easy-cs-ai` — the dispatcher: `status`, `install`, `uninstall`, `add`, `remove`, `apply`, `generate` (hands over to [vm_script](../vm_script/README.md)), component actions and `exec` (the component's own program). From a checkout it runs the scripts of [install_scripts](../install_scripts/README.md) directly. - `build.sh` — stages the tree and builds the tarball (`package/build.sh --output dist`)
- `build-native.sh` — builds the `.deb` and the `.rpm` from that tree
- `nfpm.yaml` — their definition, for [nfpm](https://nfpm.goreleaser.com/)

See also: [install_scripts](../install_scripts/README.md), the layer this package wraps, and [docs/cli-commands](../docs/cli-commands.md) for the planned command reference.
