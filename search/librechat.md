# LibreChat

[← Back to search](README.md)

**Role:** chat web interface. **License:** MIT (confirmed in repo).

## Benefits
- Multi-provider UI; custom endpoints connect to any OpenAI-compatible API, so it can sit on top of the [reverse proxy](nginx.md) fronting [Ollama](ollama.md)/[vLLM](vllm.md).
- Multi-user, conversations, presets.

## Weaknesses / must-know
- Heavy stack: Docker + Docker Compose; MongoDB is **required** (`MONGO_URI`). Meilisearch is optional (search disabled by default, needs `MEILI_MASTER_KEY` if enabled); PGVector + RAG API are optional.
- MongoDB Community is SSPL, not OSI open source: this conflicts with the "open-source" rule. FerretDB (Apache 2.0, MongoDB-wire-compatible over PostgreSQL) is a candidate replacement, and the FerretDB maintainers confirmed in a LibreChat discussion that it works, with a published guide (`MONGO_URI=mongodb://user:pass@ferretdb:27017/LibreChat`; needs only FerretDB + PostgreSQL). Still to be tested in our own setup.
- SSPL in short: since 2018 MongoDB is under the Server Side Public License, an AGPL-like licence with an extra clause. Anyone offering the software as a service to third parties must publish, under SSPL, all the code needed to run that service (management, automation, monitoring...). The OSI refused to recognise it as open source because this restricts a usage. For purely internal use on a VM the practical risk is low (the clause targets managed-service resellers), but it appears as soon as the project is distributed or used to serve customers; a legal review would then be needed (this summary is not legal advice).
- Options if the FerretDB test fails or is not enough:
  1. FerretDB + PostgreSQL (preferred, adds PostgreSQL to the stack);
  2. accept MongoDB and document the exception to the "open-source" rule (simplest install, weakest on licensing);
  3. promote [AnythingLLM](anythingllm.md) to rank 1 (no MongoDB, embedded LanceDB, but document-oriented rather than a generic chat UI).
- Models are declared in `librechat.yaml`, so the CLI `add` command must edit that file and restart.

## Health check
- `GET /health` returns 200 `OK` (liveness); `/livez` and `/readyz` also exist in the server source (`api/server/index.js`). `/readyz` is the better readiness signal for the install script, but its exact semantics (database connection) must be checked on a running instance.
- The official `docker-compose.yml` defines **no** `healthcheck`, so the script must add its own (or poll the endpoint itself), and order MongoDB (or FerretDB + PostgreSQL) before the API.
- The stack has several containers (api, MongoDB, optional Meilisearch, vector DB, RAG API). Image pull is part of *Install*, not of the health wait. Estimated timeout: **300 s**, to be recalibrated with the FerretDB test.

## Sources
- [Replacing MongoDB with FerretDB in LibreChat](https://blog.ferretdb.io/replacing-mongodb-with-ferretdb-librechat/)
- [LibreChat discussion #3985](https://github.com/danny-avila/LibreChat/discussions/3985)
- [LibreChat deploy guide](https://railway.com/deploy/librechat)
- [Getting started with LibreChat](https://aiindigo.com/tutorials/getting-started-with-librechat-self-host-unified-ai-access)
