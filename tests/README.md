# Tests directory

[← Back to project root](../README.md)

This directory contains the tests validating the install scripts, the package/CLI and the VM post-install scripts against fresh environments (VMs or containers).

See also: [.github/workflows](../.github/workflows/README.md), which runs these tests in CI.

## Unit tests

`bats --recursive tests/unit`, in `EASY_CS_AI_ROOT` mode (no root, no package, service or Docker change). Run by CI with `shellcheck`.

## Packaging tests

[tests/packaging](packaging/README.md): `packages.sh` builds the tarball, the `.deb` and the `.rpm` as the release workflow does, inspects them, installs the deb on Ubuntu and the rpm on Fedora in containers, runs the CLI and the generator from the installed package, and checks that the removal leaves nothing. By hand, after a change to the packaging (needs Docker; `nfpm` is downloaded and cached).

## Integration tests on a VM

[tests/integration](integration/README.md): `vm.sh` creates and drives a throw-away **Ubuntu 24.04** VM under libvirt/KVM, and `lifecycle.sh` runs the life of the default stack on it, as root, from the script produced by `easy-cs-ai generate`, with assertions:

1. install on an empty machine: llmfit, nginx (self-signed), Ollama, LibreChat (Docker installed by the script from its apt repository) and a model, in one run; health, API protection (401 without the key), site, endpoint, login, a chat through the API;
2. the same script again: nothing changes;
3. a reboot: the stack comes back by itself, the account is still there;
4. closing the registration recreates only the `api` container;
5. LibreChat uninstalled and installed again: database, password and account survive, `add` links the model again;
6. an install that fails its health check is reported (`status`) and cleaned (`uninstall`), and a normal install resumes;
7. `uninstall --all --purge` leaves nothing of the project, only what is shared (Docker, the nginx package).

Not run by CI (hardware virtualisation, several GB of downloads): by hand before a release and after a change to an install script. Found and fixed by these runs: the API key made `nginx -t` fail (hash bucket too small), `llmfit` refused `--purge`, a re-run of the Ollama script forgot its binary, FerretDB's state volume was never purged.

Not covered yet: Debian, the `provided` and `letsencrypt` certificates, a GPU, vLLM, and an install killed by a signal in the middle of a phase. Measured on the VM, the LibreChat health check answers 25 to 30 s after the start with the images present, well under its 300 s timeout.
