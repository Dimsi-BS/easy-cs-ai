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

## Observed behaviour (llmfit 1.1.16, run on a CPU-only machine)
- Release archives: `llmfit-v<version>-<arch>-unknown-linux-gnu.tar.gz` (x86_64 and aarch64, also `-musl`), each with a `.sha256` next to it. The archive holds `llmfit-v<version>-<arch>-unknown-linux-gnu/{llmfit,LICENSE,README.md}`. The install script downloads that archive, not the upstream `install.sh`.
- Global flags: `--json` on every subcommand; `--memory`, `--ram`, `--cpu-cores` override the detected hardware and **go before the subcommand**. `--no-dashboard` (a subcommand option) keeps it from starting its background dashboard server, so the scripts always pass it.
- `llmfit recommend --json` prints `{ "system": {…}, "models": [ … ] }` (5 models by default, `-n` to change). Every model carries `name` (a Hugging Face name), `fit_level`, `run_mode`, `score`, `memory_required_gb`, `memory_available_gb`, `estimated_tps`, `best_quant`, `ollama_name` (null for most) and more. Errors are `{ "error": { "kind", "message" } }` on stdout with exit 1.
- `llmfit fit --json -n 100000` lists every model scored for the machine (about 9,300 of the 14,000 in the catalogue, in 5 s). Levels seen: `Good`, `Marginal`, `Too Tight`; `Perfect` exists in the options. Only a few dozen models carry an `ollama_name`.
- `llmfit info "<name>" --json` gives `{ "system", "models": [ one entry with the same fields ] }` for one model, by exact or partial Hugging Face name. An Ollama tag is **not** accepted there (`llama3.2:3b` → `model_not_found`), and a partial name matching several models is `invalid_selector` (exit 1).
- Consequence for `provisioning check <model>`: the script asks `info` first, then looks the Ollama tag up in `fit` through `ollama_name` (the best `score` wins when several entries carry it). `fits` is false only for `Too Tight`. A name found by neither is exit 1 (`add --force` skips the check); models without an `ollama_name` are reachable by their Hugging Face name only.

## Health check
- No service: installation is a binary. The check is `llmfit --version` followed by one `llmfit recommend --json` run, which must output valid JSON (hardware detection is local and the tool does not need the network for it). Estimated timeout: **60 s** for the command.

## Sources
- [llmfit on docs.rs](https://docs.rs/llmfit)
- [llmfit guide](https://www.hongkiat.com/blog/llmfit-local-llm-guide/)
