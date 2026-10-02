# llmfit

[← Back to search](README.md)

**Role:** model provisioning – picks models that fit the machine. **License:** MIT (AlexsJones/llmfit).

## Benefits
- Detects CPU, RAM, GPU(s), VRAM and scores models on quality, speed, fit and context.
- Catalog of ~5,700 models with pre-computed memory requirements; handles MoE and quantization choice.
- TUI plus classic CLI mode (scriptable); knows local runtimes (Ollama, llama.cpp, MLX, LM Studio…).

## Weaknesses / must-know
- Recommendations are estimates; vLLM is **not** listed among its runtime providers (Ollama, llama.cpp, MLX, Docker Model Runner, LM Studio), so for vLLM it can only help choose a model, not provision it.
- Catalog must stay up to date; project is young and fast-moving (pin a version).
- Non-interactive use is supported: `llmfit recommend --json`. Install via `curl ... | sh`, brew, `uv tool`, Docker or GitHub release binaries.

## Health check
- No service: installation is a binary. The check is `llmfit --version` followed by one `llmfit recommend --json` run, which must output valid JSON (hardware detection is local and the tool does not need the network for it). Estimated timeout: **60 s** for the command.

## Sources
- [llmfit on docs.rs](https://docs.rs/llmfit)
- [llmfit guide](https://www.hongkiat.com/blog/llmfit-local-llm-guide/)
