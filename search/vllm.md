# vLLM

[← Back to search](README.md)

**Role:** AI inference engine (production throughput). **License:** Apache 2.0 (open source, free).

## Benefits
- Continuous batching and PagedAttention: higher throughput under concurrent load.
- OpenAI-compatible API, interchangeable with [Ollama](ollama.md) on the client side.
- Suited to serving many requests with predictable latency.

## Weaknesses / must-know
- Heavy: ~6 GB Docker image and CUDA toolkit → effectively requires an NVIDIA GPU setup on the VM.
- More configuration than Ollama; overkill for single-user setups.
- Has `--api-key` (one or several keys) and `--ssl-keyfile`/`--ssl-certfile`, but the key only protects `/v1`, `/v2` and `/inference`; other endpoints stay open. Still wrap with the [reverse proxy](nginx.md) for uniform HTTPS + key handling.

## Sources
- [Red Hat: vLLM vs Ollama](https://www.redhat.com/en/topics/ai/vllm-vs-ollama)
- [vLLM vs Ollama comparison](https://www.spheron.network/blog/ollama-vs-vllm/)
