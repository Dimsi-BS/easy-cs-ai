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

## Sources
- [llmfit on docs.rs](https://docs.rs/llmfit)
- [llmfit guide](https://www.hongkiat.com/blog/llmfit-local-llm-guide/)
