# Install scripts directory

[← Back to project root](../README.md)

This directory contains the install-and-configure scripts layer.

See also: [spec: script contract](../docs/spec-script-contract.md), the rules every script follows, and [package](../package/README.md), the layer that chains them (`apply`).

## Contents

- `lib/common.sh` — shared helpers (logging, options, locks, state, templates, service control)
- `lib/cli-base.sh` — helpers shared by the CLI and the VM script generator (types, ranks, component lookup)
- `lib/cli-apply.sh` — `apply` of the CLI (validation of the configuration file, order, install, add, prune)
- `lib/cli-models.sh` — `add` and `remove` of the CLI, sourced by `package/bin/easy-cs-ai`
- `provisioning/llmfit.sh` — llmfit: installs the pinned release binary, `recommend` and `check <model>`
- `proxy/nginx.sh` — nginx: HTTPS (self-signed, provided or Let's Encrypt certificate) and an API key (Bearer), `add-upstream`, `remove-upstream`, `add-site`, `remove-site` (a web site for browsers on its own port, without the key), `show-key`
- `engine/ollama.sh` — Ollama; version and archive checksums pinned in the script
- `chat-interface/librechat.sh` — LibreChat on FerretDB and PostgreSQL, three containers run by Docker Compose (images pinned by digest) and a systemd unit; installs Docker itself (`ensure_docker`); `add-endpoint`, `remove-endpoint`
- `ranks.conf` — integration order, rank 1 first per type, read by the CLI for `--defaults`
- `default-models.conf` — default model of each engine, added by `install --defaults`
- `templates/<component>/` — `envsubst` templates rendered by the scripts

Unit tests run in `EASY_CS_AI_ROOT` mode (no root, no package or service changes): `bats --recursive tests/unit`. They need `bash`, `jq`, `flock` and `envsubst` (Linux or WSL).
