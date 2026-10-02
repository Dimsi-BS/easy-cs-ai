# AnythingLLM

[← Back to search](README.md)

**Role:** candidate chat interface (alternative to [LibreChat](librechat.md)). **License:** MIT (Mintplex Labs).

## Benefits
- Light: Docker deployment needs ~2 GB RAM, 2 cores, 5 GB storage with external model services.
- Built-in vector database, RAG over documents, no-code agent builder.
- Multi-user with role-based access, workspaces, admin UI, REST + OpenAI-compatible API (Docker only; the desktop app is single-user).
- Default vector database is LanceDB (embedded); PGVector, Qdrant, Chroma, Milvus etc. are optional. No MongoDB dependency found. (Relational storage engine not confirmed.)

## Weaknesses / must-know
- Only the Docker version fits the project (web server on the VM, reached through a browser, default port 3001). The desktop app is single-user and local, so it is not retained.
- Multi-user mode is not enabled by default: the install script must enable it (this creates the admin account and turns on roles).
- Document/workspace oriented rather than a pure multi-provider chat UI; fewer provider-switching features than LibreChat.
- Developer API (also at `/api/docs` on each instance) can configure everything the CLI `add` command needs: `POST /v1/system/update-env` (LLM provider settings), workspace create/update, and admin user management (`/v1/admin/users`). Model-specific env keys should still be tested on a running instance.

## Sources
- [AnythingLLM overview](https://dev.co/ai/frameworks/anything-llm)
- [Open WebUI vs AnythingLLM](https://wz-it.com/en/blog/open-webui-vs-anythingllm-comparison/)
