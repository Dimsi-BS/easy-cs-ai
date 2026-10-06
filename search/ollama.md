# Ollama

[← Back to search](README.md)

**Role:** AI inference engine (developer-friendly). **License:** MIT (open source, free).

## Benefits
- Very light install: ~120 MB single binary, no Docker or config files required.
- Model pull/run in a couple of minutes; fits small teams and prototyping.
- OpenAI-compatible API surface, so clients can swap with [vLLM](vllm.md) by changing the base URL.
- Supported as a runtime by [llmfit](llmfit.md).

## Weaknesses
- Lower throughput than vLLM beyond ~4 concurrent users on the same GPU (reported 2.3x–4x gap).
- No built-in authentication or HTTPS → needs the [reverse proxy](nginx.md).

## Integration notes
- Streaming responses must not be buffered by the proxy (see nginx notes).
- Must be reachable from the LibreChat host ([LibreChat](librechat.md)).

## Install script notes
- Installed from the release archive `ollama-linux-<arch>.tar.zst` (about 1.4 GB, GPU libraries included, needs `zstd`) unpacked under `/usr/local`, not through the upstream `install.sh`, so the version and sha256 are pinned by the project.
- Runs as the `ollama` user from a full unit `/etc/systemd/system/ollama.service` rendered from a template (`OLLAMA_HOST` set from `--bind` and `--port`); models live in `/usr/share/ollama/.ollama`.
- `uninstall` keeps the models and the user; `--purge` removes both.

## Health check
- `GET /api/version` answers `{"version": …}` as soon as the server listens; no model is loaded at startup, so readiness is fast (seconds). Estimated timeout for the install script: **60 s** (to confirm in integration tests).
- `systemctl is-active` is not enough: the process can be up without answering on the expected host/port.
- Model loading is a separate matter: `OLLAMA_LOAD_TIMEOUT` (default 5 min) is a *stall* detector for loads, and a model pull can take much longer. Neither belongs to the install health check; `add-model` has its own, size-dependent wait.

## Sources
- [Red Hat: Ollama or vLLM](https://developers.redhat.com/articles/2025/07/08/ollama-or-vllm-how-choose-right-llm-serving-tool-your-use-case)
- [Ollama vs vLLM enterprise comparison](https://petronellatech.com/blog/ollama-vs-vllm-enterprise-ai-inference-comparison-2026)
