# Decision: how vLLM is installed

[← Back to docs](README.md)

**Status:** proposed

## Context

[vLLM](../search/vllm.md) is the second inference engine in the [integration order](decision-integration-order.md). Its contract is specified (one instance per model, `vllm@.service` template unit, `add-model` with a 600 s health check, see [Engines with one instance per model](spec-script-contract.md#engines-with-one-instance-per-model)), but nothing says **what the install step puts on the machine**: the contract only lists "software, CUDA check, a systemd template unit". The findings mention a ~6 GB Docker image, and the contract reserves `ensure_docker` for "the first Docker-based component", without saying that vLLM is one.

The choice shapes the unit file, the pinning and checksum rules, the `uninstall`, the state (`service.compose_file` or not) and the size of the VM disk.

What is common to every option:

- an **NVIDIA GPU and its driver** are required, the project does not install the driver. The preflight checks `nvidia-smi` and exits 3 when there is none (the "missing GPU when required" of the [exit codes](spec-script-contract.md#exit-codes));
- the CUDA runtime does not have to be installed on the host by the project: both formats carry theirs (to verify against the vLLM release used);
- one instance per model, so the unit is a **template** whatever the option.

## Options

| Option | Installs | Pros | Cons |
| --- | --- | --- | --- |
| **`venv`**: Python virtual environment in `/opt/vllm`, `pip install vllm==<version>` | `python3-venv` (apt), the wheel and its dependencies (PyTorch with CUDA runtime), several GB | No Docker, no second package source; the unit is a plain `ExecStart=/opt/vllm/bin/vllm serve …`; version pinned by `==`; `uninstall` is removing one directory | Needs a Python version the vLLM wheel supports, which the distribution may not ship (to check per Debian/Ubuntu LTS); the dependency tree is resolved at install time, so two installs of one version can differ unless a lock file is used; large download from PyPI and PyTorch's index |
| **`docker`**: image `vllm/vllm-openai:<tag>` run by systemd | Docker, the NVIDIA Container Toolkit (an extra apt repository), the ~6 GB image | Upstream's tested environment, reproducible by tag or digest; no Python on the host; the image digest is a natural checksum | Two more components to install and keep (Docker, NVIDIA toolkit, with package names that differ between Debian and Ubuntu, see `ensure_docker` in the contract); GPU access through the container runtime is one more failure point; the unit wraps `docker run` instead of the program |
| **distribution package** | – | – | None exists for vLLM; listed only so the option is not asked again |

## Decision

Proposed:

1. **Default: `venv`.** It matches the rest of layer 1 (a binary or a directory under `/opt` or `/usr/local`, a systemd unit, no container runtime), it keeps the VM minimal, and it leaves `ensure_docker` for the components that really need Docker (LibreChat, AnythingLLM).
2. **Pinned version** in the script (`DEFAULT_VERSION`), overridable with `--version`, as for Ollama. To remove the "resolved at install time" weakness, the script installs from a **lock file** shipped with the script (versions and hashes, `pip install --require-hashes`) for the pinned version; another `--version` is installed unlocked, with a `WARN`.
3. **Python**: the script uses the system `python3` when its version is supported by the wheel, else it exits 3 with the version required. It does not add third-party repositories or download an interpreter in a first version.
4. **`docker` is reserved, not implemented first**, as the other certificate strategies were: an option `--method venv|docker` is part of the interface from the start (`describe`, `apply`, the generator), the value is recorded in the state `params`, and `docker` is refused with exit 2 and a "not implemented yet" message. Adding it later changes only the vLLM script and `ensure_docker`.
5. **Preflight**: root, platform, systemd, `nvidia-smi` working (exit 3 otherwise), free disk space on `/opt` (an estimate to measure, several GB) and on the model cache directory, `python3` version.
6. **Models** (Hugging Face files) go to a data directory owned by a `vllm` system user, kept by `uninstall` and removed by `--purge`, like Ollama's.
7. **Template unit** `vllm@.service` rendered from a template, one instance per model with its own port and options, as in the contract. `install` starts nothing.

## Consequences

- `describe` for vLLM lists `--method` (default `venv`), and the state records it in `params`; no `compose_file`.
- `uninstall` removes `/opt/vllm`, the template unit and every instance; the Python packages of the distribution (`python3-venv`) stay, being shared.
- The first release of the script can be tested without a GPU for everything but the real start: argument parsing, templating, state, preflight failure (exit 3), as with Ollama in `EASY_CS_AI_ROOT` mode.
- The lock file has to be regenerated when `DEFAULT_VERSION` changes; that step goes in the script's maintenance notes.

## Open questions

- Which Python versions the pinned wheel supports, against the system Python of the Debian and Ubuntu LTS releases targeted. If a target ships an unsupported version, choose between `uv` (downloads its own interpreter) and the Docker method for that target.
- Size of the install (venv, model cache) on a minimal VM, to measure for the disk preflight.
- GPU memory sharing between instances, already open in the [contract](spec-script-contract.md#open-questions) and not settled here.
- Whether the `vllm` user needs the `video` or `render` group for the GPU devices (to check on a real machine).
