# Search directory

[← Back to project root](../README.md)

This directory contains the findings about the various components and tools that are used by the project. It describes the benefits and weaknesses of each one and the potential complexity or must-known specificity for being included in the project. All of them must be open-source and free to use.

See also: [docs](../docs/README.md) for the design decisions made from these findings.

## Findings

| Component | Role | License | Notes |
| --- | --- | --- | --- |
| [Ollama](ollama.md) | Inference engine | MIT | Light, easy; lower concurrency |
| [vLLM](vllm.md) | Inference engine | Apache 2.0 | High throughput; heavy, CUDA |
| [nginx](nginx.md) | Reverse proxy | BSD-2 | HTTPS + API key; streaming tweaks |
| [llmfit](llmfit.md) | Model provisioning | MIT | Hardware-aware model choice |
| [LibreChat](librechat.md) | Chat UI | MIT | Needs MongoDB (SSPL issue) |
| [AnythingLLM](anythingllm.md) | Chat UI (candidate) | MIT | Light, built-in RAG/vector DB |
| [Open WebUI](open-webui.md) | Chat UI (candidate) | Custom (branding clause) | Not OSI open source |
| [LiteLLM](litellm.md) | API gateway (candidate) | MIT | Virtual keys; needs Postgres |
| [llama.cpp](llama-cpp.md) | Inference engine (candidate) | MIT | Efficient on CPU; engine under Ollama |
| [LocalAI](localai.md) | Inference engine (candidate) | MIT | 60+ backends incl. llama.cpp and vLLM; CPU-only OK |
| [LobeChat](lobechat.md) | Chat UI (candidate) | LobeHub Community License | Not OSI open source |
| [LM Studio](lm-studio.md) | Inference engine | Closed source | Excluded |
| [Jan](jan.md) | Inference engine | Apache 2.0 | Desktop, single-user |

Remaining: test FerretDB with LibreChat and AnythingLLM `update-env` on a running instance; nginx certificate strategy (design decision, not a finding).
