# vLLM

[← Back to search](README.md)

**Role:** AI inference engine (production throughput). **License:** Apache 2.0 (open source, free).

## Benefits
- Continuous batching and PagedAttention: higher throughput under concurrent load.
- OpenAI-compatible API, interchangeable with [Ollama](ollama.md) on the client side.
- Suited to serving many requests with predictable latency.

## Weaknesses / must-know
- Heavy: ~6 GB Docker image and CUDA toolkit → effectively requires an NVIDIA GPU setup on the VM. How the project installs it (Python venv or Docker) is proposed in [decision: vLLM install](../docs/decision-vllm-install.md).
- More configuration than Ollama; overkill for single-user setups.
- Has `--api-key` (one or several keys) and `--ssl-keyfile`/`--ssl-certfile`, but the key only protects `/v1`, `/v2` and `/inference`; other endpoints stay open. Still wrap with the [reverse proxy](nginx.md) for uniform HTTPS + key handling.

## Health check
- `GET /health` returns 200 when the engine is alive and 503 when the engine is dead (checked in the vLLM source). The HTTP server starts listening only after the engine is initialised, so a connection refused means "still starting", not "failed".
- Startup is dominated by model loading, `torch.compile`, KV cache profiling and CUDA graph capture: from about a minute for a small model to well over 5 minutes for a ~30 GB model (published figures, not measured here). The wait must scale with the model.
- A vLLM process serves **one model** and cannot start without one. The project therefore runs **one instance per model**: `install` only installs the software, and `add-model` starts an instance and waits for this health check, see [the script contract](../docs/spec-script-contract.md#engines-with-one-instance-per-model). Estimated timeout of `add-model`: **600 s**, overridable.
- Several instances on one GPU must share its memory (`--gpu-memory-utilization`, 0.9 by default per instance): to be tested.

## Sources
- [Red Hat: vLLM vs Ollama](https://www.redhat.com/en/topics/ai/vllm-vs-ollama)
- [vLLM vs Ollama comparison](https://www.spheron.network/blog/ollama-vs-vllm/)
