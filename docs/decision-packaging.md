# Decision: packaging and entry point

[← Back to docs](README.md)

**Status:** accepted

## Context

Layer 2 was initially planned as a snap package. What is actually needed is a single unit (package or executable) that bundles the layer 1 install scripts and exposes them, plus extra commands (`status`, `install`, `add`), see [CLI commands](cli-commands.md).

## Decision

- A single CLI, **`easy-cs-ai`**, written in bash (see [scripting language](decision-scripting-language.md)). It is a `git`-style dispatcher: each sub-command calls the matching script from the install scripts layer.
- Distributed as:
  - a **tarball** (works anywhere with `bash` and `curl`);
  - **`.deb` and `.rpm` packages**, both built in CI from one definition with [`nfpm`](https://nfpm.goreleaser.com/).
- The VM post-install layer downloads the package (or tarball) from a pinned, checksummed and configurable source, installs it, then runs `easy-cs-ai apply` on a configuration embedded in the script (see [spec: config](spec-config.md) and [decision: VM script generator](decision-vm-generator.md)), or `easy-cs-ai install --defaults`. The package is not embedded in the script, VM user-data being size-limited.
- The layer 1 scripts remain usable on their own, without the CLI.
- Package files are named `easy-cs-ai_<version>_all.deb`, `easy-cs-ai-<version>-1.noarch.rpm` and `easy-cs-ai-<version>.tar.gz`, each published with a `<file>.sha256` (see [spec: VM script generator](spec-vm-generator.md#package-source)).
- Installed state lives in `/var/lib/easy-cs-ai/`, which feeds `status` and the defaults of `add`.

## Implementation

- `package/build.sh` stages the tree (`bin/easy-cs-ai`, `lib/easy-cs-ai/…` with the scripts, templates, `ranks.conf` and `vm_script/`, without the READMEs) and builds a reproducible tarball with its `.sha256`. The version is the `CLI_VERSION` of the dispatcher; the script refuses another one, so a tag, the CLI and the package names cannot drift apart.
- `package/build-native.sh` runs `nfpm` on `package/nfpm.yaml` from that tree and names the files after the version of the CLI, with a `.sha256` each. For a pre-release version (`0.1.0-rc1`) `nfpm` writes the package manager's form (`0.1.0~rc1`, which sorts before `0.1.0`) in the file name; the files are renamed so that the generated VM scripts find `easy-cs-ai_0.1.0-rc1_all.deb`, while the metadata inside keep the tilde.
- `package/nfpm.yaml` installs that same tree under `/usr` for the `.deb` and the `.rpm`, so the three formats ship identical files, and declares the dependencies the scripts need beyond the base system (`jq`, `util-linux` for `flock`, `gettext-base` / `gettext` for `envsubst`).
- `.github/workflows/release.yml` runs on a `v*` tag: lint and tests, tarball, `package/build-native.sh`, the packaging tests, then a GitHub release: a tag with a hyphen (`v0.1.0-rc1`) is published as a **pre-release**, any other (`v0.1.0`) as a release and the latest one. The tarball and the staging are covered by `bats` tests; `nfpm.yaml` is exercised by [tests/packaging](../tests/packaging/README.md) (build, inspection, install of the deb on Ubuntu and the rpm on Fedora). The workflow itself has **not been run yet** (no tag was pushed), so the first release is the first test of it.
- No maintainer scripts (`postinst`…): installing the package only drops files, nothing is enabled or started, the components are installed by `easy-cs-ai install`.

## Why

- A snap running our scripts would need **classic confinement** (the scripts run `apt`, create system services and edit `/etc`), which requires manual approval from the Snap Store, or an out-of-store install that is impractical for VM fleets.
- `snapd` is absent from many distributions and costs resources on minimal VMs.
- Native packages give dependency handling, upgrades and clean removal for free, and cover Debian/Ubuntu and RHEL/Fedora families.
- A tarball keeps a path for distributions that use neither format.

## Consequences

- The Debian/Ubuntu target remains primary; other distributions are supported to the extent that the individual component install scripts handle them. This is a per-component concern, no longer a packaging one.
- Automatic upgrades through `apt`/`dnf` require hosting a package repository; until then packages are downloaded directly (e.g. from GitHub Releases).
- The layer is renamed "Package / CLI" and its directory `snap_package` becomes `package`.

## Alternatives considered

| Option | Why not |
| --- | --- |
| Snap | Classic confinement needed, `snapd` not universal, see above |
| Single Go binary with embedded scripts (`embed.FS`) | Good fit for distribution, but adds a build chain; kept as a possible evolution |
| Self-extracting archive (`makeself`) | Redundant once the CLI is installed; could still serve as the VM one-liner |
| Container image | Our scripts install onto the host system, not into a container |
| Ansible | Requires Python and a controller; too heavy |
