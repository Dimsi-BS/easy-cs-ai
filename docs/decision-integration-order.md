# Decision: integration order of alternative components

[← Back to docs](README.md)

**Status:** proposed

## Context

Several functions can be fulfilled by more than one open-source tool (inference engine, chat interface, ...). The findings in [search](../search/README.md) describe each candidate, but nothing says which one is integrated first, which ones follow, and which ones are out.

## Decision

For every function with several candidates, components are ranked. The rank is the **integration order**: rank 1 is the default shipped by the CLI and the first one implemented in the [roadmap](../README.md#roadmap); the next ranks are added only once the previous ones are done.

### Rules

1. **Eligibility**: the component must be open-source (OSI-approved licence) and free, see [search](../search/README.md). Others are *excluded*, not just ranked last. A chat interface must additionally be a **multi-user web server with authentication, hosted on the VM and reached through a browser**; desktop applications are excluded.
2. **Ranking criteria**, in this order:
   1. runs on a minimal Debian/Ubuntu VM, without a GPU when possible (project target, see [README](../README.md#requirements)). Docker is acceptable, provided the install script installs it itself;
   2. install and configuration can be fully scripted without manual steps (zero-conf goal);
   3. no extra mandatory service (database, cache) beyond the component itself;
   4. exposes or consumes an OpenAI-compatible API, so a component of the same function can replace another by changing a base URL.
3. **Same interface**: all alternatives of a function expose the same CLI-level interface, so switching is one parameter (e.g. `install engine ollama|vllm`).
4. **Revisiting**: the order is reviewed when a finding changes (licence, new release) and whenever a component is added to [search](../search/README.md).

### Inference engines

| Order | Component | Reason |
| --- | --- | --- |
| 1 | [Ollama](../search/ollama.md) | Light single binary, CPU-friendly, simplest to script |
| 2 | [vLLM](../search/vllm.md) | High throughput for multi-user GPU servers; heavy, CUDA required |
| 3 | [llama.cpp](../search/llama-cpp.md) | Efficient on CPU, but Ollama already covers that need (it is the engine under Ollama) |
| 4 | [LocalAI](../search/localai.md) | Many backends, but overlaps with the ones above |
| – | [LM Studio](../search/lm-studio.md) | Excluded: closed source |
| – | [Jan](../search/jan.md) | Excluded: desktop, single-user |

### Chat interfaces

| Order | Component | Reason |
| --- | --- | --- |
| 1 | [LibreChat](../search/librechat.md) | Already planned; multi-user. Needs MongoDB (SSPL issue), replaced by FerretDB + PostgreSQL (tested) |
| 2 | [AnythingLLM](../search/anythingllm.md) | Light, built-in RAG and vector DB; Docker version only, multi-user mode to enable at install |
| – | [Open WebUI](../search/open-webui.md) | Excluded: custom licence with branding clause, not OSI |
| – | [LobeChat](../search/lobechat.md) | Excluded: LobeHub Community License, not OSI |

### Functions with a single solution

No order needed, listed so that a second candidate triggers the rules above:

- Reverse proxy (HTTPS + API key): [nginx](../search/nginx.md)
- Model provisioning: [llmfit](../search/llmfit.md)
- API gateway: [LiteLLM](../search/litellm.md), candidate only, not in the roadmap

## Consequences

- The roadmap follows this order: Ollama before vLLM, LibreChat before AnythingLLM.
- The CLI default for each function is its rank 1.
- The excluded components stay documented in [search](../search/README.md) so the reason is not lost.
- **LibreChat rank 1 and MongoDB (SSPL): resolved by FerretDB.** LibreChat requires MongoDB, whose SSPL licence is not OSI-approved and conflicts with the eligibility rule. LibreChat v0.8.7 was tested on FerretDB 2.7.0 + PostgreSQL (DocumentDB) and works (register, login, chat, persistence across restart); see [LibreChat findings](../search/librechat.md). The install script must therefore deploy FerretDB + PostgreSQL instead of MongoDB, and LibreChat stays rank 1.
- A new function with several candidates gets its own table here before any implementation starts.
