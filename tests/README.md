# Tests directory

[← Back to project root](../README.md)

This directory contains the tests validating the install scripts, the package/CLI and the VM post-install scripts against fresh environments (VMs or containers).

See also: [.github/workflows](../.github/workflows/README.md), which runs these tests in CI.

## Unit tests

`bats --recursive tests/unit`, in `EASY_CS_AI_ROOT` mode (no root, no package, service or Docker change). Run by CI with `shellcheck`.

## Integration tests on a VM

Done by hand so far, on an **Ubuntu 24.04 LTS** cloud image booted under libvirt/KVM (4 vCPU, 6 GB of RAM, 40 GB of disk, NAT network), from the script produced by `easy-cs-ai generate`, as root, in this order:

1. install on a fresh VM: llmfit, nginx (self-signed), Ollama, LibreChat (Docker installed by the script from its apt repository) and the model `llama3.2:1b`, in one run (exit 0);
2. run the same script again: nothing changes (6 s), `status` healthy;
3. reboot the VM: the whole stack is back by itself in about 30 s;
4. close the registration (`install chat-interface librechat --allow-registration false`): only the `api` container is recreated, existing accounts keep working;
5. uninstall LibreChat (database and secrets kept), install it again: the account and its conversation are found, `add` links the model again;
6. an install that fails its health check (timeout of 1 s) leaves a pending manifest that `status` reports and `uninstall` cleans, and a normal install then resumes;
7. `uninstall --all --purge` leaves no state, file, unit, container, volume or image of the project, only what is shared (Docker and the nginx package);
8. a real chat in the browser (LibreChat, then Ollama on the loopback), the API refusing a request without the key (401) and accepting it, the site answering without a key on its own port.

Found and fixed by these runs: the API key made `nginx -t` fail (hash bucket too small), `llmfit` refused `--purge`, a re-run of the Ollama script forgot its binary, FerretDB's state volume was never purged.

Not covered yet: Debian, the `provided` and `letsencrypt` certificates, a GPU, vLLM, and an install killed by a signal in the middle of a phase. Measured with the VM, the LibreChat health check answers 25 to 30 s after the start with the images present, well under its 300 s timeout.

