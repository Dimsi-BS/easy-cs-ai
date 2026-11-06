# Integration tests

[← Back to tests](../README.md)

The unit tests ([tests/unit](../unit)) run in `EASY_CS_AI_ROOT` mode and never touch a service. These tests run the scripts **for real**, as root, on a throw-away Ubuntu VM: they are what the "definition of done" of the [script contract](../../docs/spec-script-contract.md#definition-of-done-for-a-script) asks for. They are not run by CI (they need hardware virtualisation and download several GB); run them by hand before a release and after a change to an install script.

## What you need

A Linux with libvirt and KVM, and a user who may use them (group `libvirt`, and access to `/dev/kvm` through libvirt):

```bash
sudo apt install qemu-system-x86 libvirt-daemon-system virtinst xorriso jq curl openssl python3
sudo usermod -aG libvirt "$USER"   # then log in again
```

Under **WSL2** it works with nested virtualisation (`/dev/kvm` must exist). WSL stops a distribution that has no open `wsl.exe` session after a short idle time, which kills the VM: keep a session open while the tests run (the scripts are long-running, so a foreground run is enough).

Network access is needed from the VM (Ubuntu mirrors, Docker, GitHub, `ghcr.io`) and about 10 GB of disk for the image, the VM and the downloads.

## The VM: `vm.sh`

```text
tests/integration/vm.sh create | start | stop | status | ssh [command] | run <config.json> [--vm <name>] | destroy [--all | --net]
```

| Command | What it does |
| --- | --- |
| `create` | downloads the Ubuntu 24.04 cloud image (checked against the published SHA256SUMS, cached), makes a NAT network of its own and the VM `ecsai-test` (4 vCPU, 6 GB, 40 GB), waits for SSH |
| `start`, `stop`, `status` | power and address |
| `ssh [command]` | a shell on the VM as `tester` (passwordless sudo); commands as arguments or on stdin |
| `run <config> [--vm <name>]` | builds the package from **this working tree**, generates the VM script from the configuration with `easy-cs-ai script`, serves the package to the VM over HTTP, runs the script as root, prints its log lines and exits with its exit code. A configuration that names several VMs gives one script per VM: `--vm` says which one this VM runs |
| `destroy [--all \| --net]` | removes the VM, its disk and its network (a network shared through `ECSAI_VM_NETWORK` stays, unless `--net`); `--all` also removes the image cache |

`run` removes the installed package in the VM first: the generated script skips the download when the pinned version is installed, and the code that runs must be the one you just edited. The components installed by an earlier run stay, so a second `run` is also a test of the re-run.

Settings, by environment variable: `ECSAI_VM_DIR` (work directory, default `~/.cache/easy-cs-ai-vm`), `ECSAI_VM_NAME`, `ECSAI_VM_NETWORK` (the libvirt network, the VM's own by default, one shared with other VMs when set), `ECSAI_VM_MEMORY` (MB), `ECSAI_VM_VCPUS`, `ECSAI_VM_DISK` (GB), `ECSAI_VM_IMAGE_BASE` and `ECSAI_VM_IMAGE_FILE` (another image), `ECSAI_VM_HTTP_PORT`, `ECSAI_VM_RUN_TIMEOUT` (seconds, default 2400).

The network is separate from libvirt's `default` one and numbered (`192.168.151.0/24`, then 152…): a bridge that survives a restart of `libvirtd` makes libvirt refuse the same address, and `vm.sh` then moves to the next number by itself.

## The scenario: `lifecycle.sh`

```text
tests/integration/lifecycle.sh [--keep]
```

Creates the VM if needed, then, with assertions (`ok` / `FAIL`, exit 1 if anything fails):

1. installs llmfit, nginx (self-signed), Ollama, LibreChat and one model from a generated script, on an empty machine; checks the health of the four components, the API (401 without the key, 200 with it), the site (no key), the endpoint seen by LibreChat, the open registration, a login and a chat through the API;
2. runs the same script again: nothing changes;
3. reboots the VM: the stack is back by itself, the account is still there;
4. closes the registration: only the `api` container is recreated, new accounts get 403, the existing one still logs in;
5. uninstalls LibreChat and installs it again: the database, its password and the account survive, `add` links the model again;
6. makes an install fail its health check: exit 6, no state, a pending manifest that `status` reports and `uninstall` cleans, then a normal install resumes;
7. `uninstall --all --purge`: no state, file, unit, nginx configuration, container, volume, image, binary, user or listening port of the project is left.
8. `install --defaults` on the emptied machine: the default stack and the default model (`default-models.conf`), linked and served through the API; the same command again changes nothing; a last `uninstall --all --purge` leaves nothing.

It leaves the VM empty (`uninstall --all --purge`), unless `--keep` or a failure, so that you can look. The model is `llama3.2:1b` (`ECSAI_TEST_MODEL` to change it; llmfit must know it and it must fit the VM, 4.5 GB free).

It takes about 25 minutes the first time (the image, Docker, Ollama and the three images of LibreChat are downloaded) and 10 when the image is cached.

## The scenario of several VMs: `multi-vm.sh`

```text
tests/integration/multi-vm.sh [--keep]
```

The inference engine and **two** web interfaces on **three** VMs (`ecsai-engine`, `ecsai-web` and `ecsai-web2`, created if absent, on one network `ecsai-net` so that they reach each other), the case of [spec: several VMs](../../docs/spec-multi-vm.md): one engine VM, linked from more than one web VM. Its settings: `ECSAI_ENGINE_VM`, `ECSAI_WEB_VM` and `ECSAI_WEB2_VM` (the names), `ECSAI_ENGINE_MEMORY` (4096 MB), `ECSAI_WEB_MEMORY` and `ECSAI_WEB2_MEMORY` (3072 MB each), `ECSAI_ENGINE_DISK` (20 GB), `ECSAI_WEB_DISK` and `ECSAI_WEB2_DISK` (24 GB each, LibreChat needs 12 GB free for its images), and `ECSAI_TEST_MODEL` as for the first scenario. The three machines need about 10 GB of RAM together.

With assertions (`ok` / `FAIL`, exit 1 if anything fails):

0. one configuration names the three VMs (llmfit, nginx, Ollama and the model on the engine VM, nginx and LibreChat on each web VM) and links both web VMs to the engine VM: it is valid, and its validation gives the five steps left to do (one engine VM, two links) and the warning that the address of the engine VM is not known yet;
1. the script of the engine VM, then the one of each web VM, run as root: each VM is healthy, nothing of another VM is on it, the header of each script says its VM, and each LibreChat comes up with no model in its list;
2. the steps 2 and 3 of the instructions, read once on the engine VM (the API key, the URL and the names of the certificate; the host of the URL is one the certificate covers, an address of the VM is among them; when the name of the engine VM is not known to the DNS of the network, which is the case on the libvirt network of the test, the address replaces the host in the URL, as the instructions say), then step 3 checked from each web VM (401 without the key, 200 with it, the self-signed certificate refused without its copy);
3. the step 4, once per link: `add-endpoint` with the key and the certificate on each web VM. LibreChat lists the endpoint, the key is a secret of its own (mode 600, nowhere else), and the api container, with the key from its environment and the certificate from its bundle, gets a message answered by the engine VM; without the bundle the certificate is refused;
4. the three scripts again change nothing (the same files, key and certificate included, on every VM), and both links survive;
5. `uninstall --all --purge` on all three VMs leaves nothing of the project.

It leaves all three machines empty, unless `--keep` or a failure. It takes about an hour the first time (three images, Docker, Ollama, the model and, twice, the three images of LibreChat) and 20 minutes when everything is cached.

## What it does not cover

Debian, the `provided` and `letsencrypt` certificates, a GPU, vLLM, an install killed by a signal in the middle of a phase, and a chat in a browser (the browser of a developer machine refuses the self-signed certificate; the API-level chat is checked instead), and, in the several-VM scenario, a conversation sent through LibreChat itself (the call of its api container to the engine is checked, not its chat route), an address of the engine VM that changes after the install, and a name of the engine VM that a DNS resolves (the test uses the address of the VM, which its certificate covers).
