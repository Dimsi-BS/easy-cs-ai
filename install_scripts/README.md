# Install scripts directory

[← Back to project root](../README.md)

This directory contains the install-and-configure scripts layer.

See also: [spec: script contract](../docs/spec-script-contract.md), the rules every script follows, and [package](../package/README.md), the layer that chains them (`apply`).

## Contents

- `lib/common.sh` — shared helpers (logging, options, locks, state, templates, service control)
- `engine/ollama.sh` — Ollama; version and archive checksums pinned in the script
- `templates/<component>/` — `envsubst` templates rendered by the scripts

Unit tests run in `EASY_CS_AI_ROOT` mode (no root, no package or service changes): `bats --recursive tests/unit`. They need `bash`, `jq`, `flock` and `envsubst` (Linux or WSL).
