# Packaging tests

[← Back to tests](../README.md)

`packages.sh` builds the tarball, the `.deb` and the `.rpm` the way [release.yml](../../.github/workflows/release.yml) does and checks them, without a tag and without publishing anything:

```text
tests/packaging/packages.sh [--keep]
```

1. **Tarball**: built by `package/build.sh`, checksum verified, CLI and scripts tree present, no documentation shipped, no CRLF, the extracted CLI answers `--version` (the reproducibility and the staging are covered by [tests/unit/package.bats](../unit/package.bats)).
2. **deb and rpm**: built by `nfpm` from [package/nfpm.yaml](../../package/nfpm.yaml), with the file names the generated VM scripts download (`easy-cs-ai_<v>_all.deb`, `easy-cs-ai-<v>-1.noarch.rpm`). The deb is inspected with `dpkg-deb`: name, version, architecture, dependencies, the same files as the tarball under `/usr`, the CLI executable, no maintainer script.
3. **Install in containers** (Docker): the deb on `ubuntu:24.04`, the rpm on `fedora:latest`. Each is installed with its dependencies, the CLI runs (`--version`, `status`), `generate --config` writes a script that pins this very package (checksum included) and passes `bash -n`, then the package is removed and nothing is left in `/usr/bin` nor `/usr/lib`. Nothing is installed as a component: the test never starts a service.

Without Docker the container steps are skipped (reported as `skip`); without `dpkg-deb` the deb inspection is skipped too.

## What you need

`bash`, `curl`, `jq`, `tar`, `sha256sum`. `nfpm` is taken from `$ECSAI_NFPM`, then the `PATH`, then `~/.cache/easy-cs-ai-pkg`; if it is nowhere, version 2.47.0 is downloaded from its GitHub release (about 6.6 MB) and checked against the `checksums.txt` of that release. The container images are pulled the first time (Ubuntu and Fedora, under 100 MB each).

Settings, by environment variable: `ECSAI_NFPM` (a binary), `ECSAI_NFPM_VERSION`, `ECSAI_PKG_CACHE`, `ECSAI_DEB_IMAGE`, `ECSAI_RPM_IMAGE`.

It takes about a minute with the images and `nfpm` cached. Run by the `packaging` job of CI, and by hand after a change to `package/`, `nfpm.yaml` or the files shipped.

## What it does not cover

Debian and RHEL images, the upgrade of an installed package, and the publication itself (`gh release create`, only exercised by a real tag).
