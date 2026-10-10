# Package directory

[← Back to project root](../README.md)

This directory contains the files specific to the packaging layer: the `easy-cs-ai` CLI dispatcher and the tarball/`.deb`/`.rpm` packaging definitions (see [docs/decision-packaging](../docs/decision-packaging.md)).

- `bin/easy-cs-ai` — the dispatcher: `status`, `install`, `uninstall`, `add`, `remove`, `apply`, `generate` (hands over to [vm_script](../vm_script/README.md)), component actions and `exec` (the component's own program). From a checkout it runs the scripts of [install_scripts](../install_scripts/README.md) directly.
- `build.sh` — stages the tree and builds the tarball (`package/build.sh --output dist`)
- `build-native.sh` — builds the `.deb` and the `.rpm` from that tree (`package/build-native.sh --output dist`, after `build.sh`), named `easy-cs-ai_<v>_all.deb` and `easy-cs-ai-<v>-1.noarch.rpm`, each with its `.sha256`. It needs [nfpm](https://nfpm.goreleaser.com/) in `PATH`, or `--nfpm <binary>` (a name or a path, relative or absolute)
- `nfpm.yaml` — their definition, for nfpm

The scripts are covered by [tests/unit/package.bats](../tests/unit/package.bats) (`build-native.sh` with a fake `nfpm`) and, with the real packages installed in containers, by [tests/packaging](../tests/packaging/README.md).

See also: [install_scripts](../install_scripts/README.md), the layer this package wraps, and [docs/cli-commands](../docs/cli-commands.md) for the command reference.
