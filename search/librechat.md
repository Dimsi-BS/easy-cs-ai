# LibreChat

[← Back to search](README.md)

**Role:** chat web interface. **License:** MIT (confirmed in repo).

## Benefits
- Multi-provider UI; custom endpoints connect to any OpenAI-compatible API, so it can sit on top of the [reverse proxy](nginx.md) fronting [Ollama](ollama.md)/[vLLM](vllm.md).
- Multi-user, conversations, presets.

## Weaknesses / must-know
- Heavy stack: Docker + Docker Compose; MongoDB is **required** (`MONGO_URI`). Meilisearch is optional (search disabled by default, needs `MEILI_MASTER_KEY` if enabled); PGVector + RAG API are optional.
- MongoDB Community is SSPL, not OSI open source: this conflicts with the "open-source" rule. FerretDB (Apache 2.0, MongoDB-wire-compatible over PostgreSQL) is a candidate replacement, and the FerretDB maintainers confirmed in a LibreChat discussion that it works, with a published guide (`MONGO_URI=mongodb://user:pass@ferretdb:27017/LibreChat`; needs only FerretDB + PostgreSQL). **Tested in our own setup: it works** (see [FerretDB test](#ferretdb-test)).
- SSPL in short: since 2018 MongoDB is under the Server Side Public License, an AGPL-like licence with an extra clause. Anyone offering the software as a service to third parties must publish, under SSPL, all the code needed to run that service (management, automation, monitoring...). The OSI refused to recognise it as open source because this restricts a usage. For purely internal use on a VM the practical risk is low (the clause targets managed-service resellers), but it appears as soon as the project is distributed or used to serve customers; a legal review would then be needed (this summary is not legal advice).
- Fallback options, only if FerretDB later proves insufficient:
  1. FerretDB + PostgreSQL (**retained**, adds PostgreSQL to the stack);
  2. accept MongoDB and document the exception to the "open-source" rule (simplest install, weakest on licensing);
  3. promote [AnythingLLM](anythingllm.md) to rank 1 (no MongoDB, embedded LanceDB, but document-oriented rather than a generic chat UI).
- Models are declared in `librechat.yaml`, so the CLI `add` command must edit that file and restart.

## Health check
- `GET /health` returns 200 `OK` (liveness); `/livez` and `/readyz` also exist in the server source (`api/server/index.js`). `/readyz` is the better readiness signal for the install script, but its exact semantics (database connection) must be checked on a running instance.
- The official `docker-compose.yml` defines **no** `healthcheck`, so the script must add its own (or poll the endpoint itself), and order MongoDB (or FerretDB + PostgreSQL) before the API.
- The stack has several containers (api, MongoDB, optional Meilisearch, vector DB, RAG API). Image pull is part of *Install*, not of the health wait. Estimated timeout: **300 s**. Measured with FerretDB (see below): 25 s cold start and 10 s warm restart once the images are present, so 300 s leaves a wide margin for slow disks.

## FerretDB test
Run on 2026-10-09 in WSL2 Ubuntu 24.04 (Docker Engine 29.9.0, Compose v5.6.0).

**Stack:** `ghcr.io/danny-avila/librechat:latest` (v0.8.7), `ghcr.io/ferretdb/ferretdb:2.7.0` and `ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0`. The FerretDB guide uses the all-in-one `ferretdb-eval` image, which is documented as dev/test only: the install script must use the two separate images above (FerretDB 2.x needs the DocumentDB PostgreSQL build, a plain PostgreSQL is not enough). Config: `MONGO_URI=mongodb://<user>:<pass>@ferretdb:27017/LibreChat`, `POSTGRES_USER`/`POSTGRES_PASSWORD` on the PostgreSQL service and `FERRETDB_POSTGRESQL_URL=postgres://<user>:<pass>@postgres:5432/postgres` on FerretDB. The PostgreSQL service needs a `pg_isready` healthcheck and FerretDB a `depends_on: condition: service_healthy`; without it FerretDB starts too early.

**Result: OK.**
- `/health`, `/livez` and `/readyz` return 200 `OK`; the log shows `Connected to MongoDB`. `/readyz` only proves the API is up, it does not detect a FerretDB outage by itself.
- Registration, login, a streamed chat through a custom endpoint and the conversation display all work. Data is really stored in FerretDB (37 collections created, `users`, `conversations`, `messages` filled; the assistant text is in `messages.content[]`, not in `text`).
- Everything survives `docker compose down` + `up` (PostgreSQL volume), including the web session.
- Footprint at idle: API ~420 MiB, PostgreSQL ~100 MiB, FerretDB ~12 MiB. Images: DocumentDB PostgreSQL 2.31 GB, LibreChat 3.83 GB, FerretDB 54 MB.

**Known noise:** the API logs `The argument to $size must be an array, but was of type: missing` (`contextProjectionController`) on the first message. MongoDB 7 returns the exact same error, so it is not caused by FerretDB, and it does not break the chat.

**Not covered:** Meilisearch search, RAG API / PGVector, file uploads, agents and a real inference endpoint (a mock OpenAI-compatible server was used). Quantified behaviour under several concurrent users was not tested either.

## Sources
- [Replacing MongoDB with FerretDB in LibreChat](https://blog.ferretdb.io/replacing-mongodb-with-ferretdb-librechat/)
- [LibreChat discussion #3985](https://github.com/danny-avila/LibreChat/discussions/3985)
- [LibreChat deploy guide](https://railway.com/deploy/librechat)
- [Getting started with LibreChat](https://aiindigo.com/tutorials/getting-started-with-librechat-self-host-unified-ai-access)
