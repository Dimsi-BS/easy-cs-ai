# LibreChat

[← Back to search](README.md)

**Role:** chat web interface. **License:** MIT (confirmed in repo).

## Benefits
- Multi-provider UI; custom endpoints connect to any OpenAI-compatible API, so it can sit on top of the [reverse proxy](nginx.md) fronting [Ollama](ollama.md)/[vLLM](vllm.md).
- Multi-user, conversations, presets.

## Weaknesses / must-know
- Heavy stack: Docker + Docker Compose; MongoDB is **required** (`MONGO_URI`). Meilisearch is optional (search disabled by default, needs `MEILI_MASTER_KEY` if enabled); PGVector + RAG API are optional.
- MongoDB Community is SSPL, not OSI open source: this conflicts with the "open-source" rule. FerretDB (Apache 2.0, MongoDB-wire-compatible over PostgreSQL) is a candidate replacement, and the FerretDB maintainers confirmed in a LibreChat discussion that it works, with a published guide (`MONGO_URI=mongodb://user:pass@ferretdb:27017/LibreChat`; needs only FerretDB + PostgreSQL). Still to be tested in our own setup.
- Models are declared in `librechat.yaml`, so the CLI `add` command must edit that file and restart.

## Sources
- [Replacing MongoDB with FerretDB in LibreChat](https://blog.ferretdb.io/replacing-mongodb-with-ferretdb-librechat/)
- [LibreChat discussion #3985](https://github.com/danny-avila/LibreChat/discussions/3985)
- [LibreChat deploy guide](https://railway.com/deploy/librechat)
- [Getting started with LibreChat](https://aiindigo.com/tutorials/getting-started-with-librechat-self-host-unified-ai-access)
