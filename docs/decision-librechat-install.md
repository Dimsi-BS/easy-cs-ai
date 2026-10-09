# Decision: how LibreChat is installed

[← Back to docs](README.md)

**Status:** accepted on 2026-10-09 (points 1 to 5). The open questions at the end are deferred and do not block the implementation.

## Context

[LibreChat](../search/librechat.md) is the first chat interface in the [integration order](decision-integration-order.md) and the first **Docker-based** component: the [script contract](spec-script-contract.md) reserves `ensure_docker` for it without implementing it, and the state format foresees `service.compose_file` for it. The generic contract (actions, phases, secrets, locks, exit codes) and the type-specific actions `add-endpoint` / `remove-endpoint` are specified, and the database question is settled: LibreChat runs on **FerretDB + PostgreSQL** instead of MongoDB (SSPL), tested with LibreChat v0.8.7, FerretDB 2.7.0 and PostgreSQL with the DocumentDB extension (see the [FerretDB test](../search/librechat.md#ferretdb-test)).

Five points are not specified, and the install script cannot be written without them:

1. how Docker is installed;
2. what the stack is made of, how it is pinned and run;
3. how the web interface is served over HTTPS, since [nginx](../search/nginx.md) currently requires the API key on **every** path and a browser cannot send it;
4. how the container reaches the models, which run on the same machine and listen on its loopback;
5. who can create an account, and how the first administrator is created without a prompt.

## Options and decision

### 1. Docker installation (`ensure_docker`)

| Option | Packages | Pros | Cons |
| --- | --- | --- | --- |
| **Docker's own apt repository** | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` | Same package names on Debian and Ubuntu (only the repository URL changes with the distribution ID); current Compose v2; this is what the FerretDB test ran on | Adds a third-party apt source and its signing key; needs access to `download.docker.com` |
| **Distribution packages** | `docker.io` plus a Compose package whose name and generation depend on the release (`docker-compose-v2`, `docker-compose`, to check per Debian/Ubuntu LTS) | No extra repository | Names and Compose generation differ between releases; a release may only offer the end-of-life Compose v1, whose CLI differs |

**Decision: Docker's apt repository.** `ensure_docker` in `lib/common.sh`:

- does nothing if `docker compose version` already works (an existing Docker, whatever its origin, is kept);
- otherwise adds the repository (signing key stored in `/etc/apt/keyrings/docker.asc`, source in `/etc/apt/sources.list.d/docker.list`, both tracked in the pending manifest), then installs the four packages through `apt_install` and enables `docker.service` through `systemd_enable_now`;
- exits 5 when the repository is unreachable, 3 on an unsupported distribution or architecture (Debian and Ubuntu, `amd64` and `arm64`);
- is **never undone by `uninstall`**: Docker is a shared system package (contract, `uninstall`). The apt source and key are shared too and stay.

### 2. The stack, its pinning and its unit

- **Three containers**: `api` (LibreChat), `ferretdb` and `postgres`. Meilisearch, the RAG API and PGVector are **not** part of the first version (see the [findings](../search/librechat.md): optional, search off by default), so `status` has three services to probe and no extra database.
- **Pinned in the script**, tag and digest, the ones of the FerretDB test:

| Service | Image | Digest |
| --- | --- | --- |
| `api` | `ghcr.io/danny-avila/librechat:v0.8.7` | `sha256:c5db3331b845e1f289f8d04c0c77936c4bbe372f76730a804abc1c37e44d23a9` |
| `ferretdb` | `ghcr.io/ferretdb/ferretdb:2.7.0` | `sha256:5706414241eb84f0515512c37b46db0f1b1eac9e5ceb7e4c2523211c184b1985` |
| `postgres` | `ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0` | `sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7` |

  The compose file references `image: <name>@<digest>`, so a moved tag changes nothing. `--version <x.y.z>` selects another **LibreChat** release, resolved by tag only, with a `WARN` (no known digest). FerretDB and PostgreSQL are a **pair** whose versions are tied together by the FerretDB project: they are pinned with the script and not exposed as options. The FerretDB guide for LibreChat uses an all-in-one `ferretdb-eval` image, documented as dev/test only, so it is **not** used (our test ran on the two separate images above): a plain PostgreSQL is not enough either, FerretDB 2.x needs the DocumentDB build.
- **Files**: compose file `/etc/easy-cs-ai/librechat/docker-compose.yml` (rendered from a template, recorded as `service.compose_file`), `/etc/easy-cs-ai/librechat/librechat.yaml`, and `/etc/easy-cs-ai/secrets/librechat.env` (mode `0600`, root) holding what the containers read from the environment. Data: the PostgreSQL named volume, recorded in `data_dirs` by its name, kept by `uninstall` and removed by `--purge` (`docker compose down -v`).
- **Unit** `easy-cs-ai-librechat.service`: `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=docker compose -f <compose_file> up -d`, `ExecStop=docker compose -f <compose_file> down`. The containers carry `restart: unless-stopped`, so Docker restarts them after a crash and the unit only restores the stack at boot. Fail fast (contract, Health check) reads `docker compose ps` instead of the unit state.
- **Startup order**: `postgres` has a `pg_isready` healthcheck, `ferretdb` waits with `depends_on: condition: service_healthy`. The healthcheck is required so that FerretDB never starts against a PostgreSQL that is not ready (the test ran with it).
- **Image pull belongs to Install**, with checksum verification by digest (exit 5 on a failure), not to Start and not to the health wait. About 6.2 GB on disk (LibreChat 3.8 GB, PostgreSQL 2.3 GB, FerretDB 54 MB): the preflight requires **12 GB free** on `/var/lib/docker`.
- **Health**: `GET /health` on the loopback port (the contract's probe), then `GET /readyz`. Default timeout kept at **300 s**: measured 25 s cold and 10 s warm with the images present, so the margin covers the pull being excluded and slow disks. `/readyz` does not prove FerretDB answers; `status` therefore also checks that the three containers are `healthy`/`running`.

### 3. Serving the web interface

LibreChat has no TLS of its own, and logins travel over this connection. The nginx of the project has one `server` block that answers 401 without the API key on every path (a deliberate choice for the models, see its template), so it cannot front a browser as it is.

| Option | Pros | Cons |
| --- | --- | --- |
| **A. LibreChat in clear HTTP on the network** | Nothing to change in nginx | Passwords and conversations in clear text; contradicts the HTTPS goal of the project |
| **B. A second `server` of nginx for the interface, on its own port, no API key** | The API surface stays strictly protected (key on every path); same certificate; browsers work | New proxy action in the contract; one more port to open |
| **C. `location /` without key on the existing port, upstream locations keep it** | One port | Turns "key everywhere" into "key except here": a forgotten `location` becomes an open path; a model named like the interface collides |

**Decision: B.**

- New proxy action **`add-site <name> <url>` / `remove-site <name>`**, added to the contract table of the `proxy` type. It writes `sites/<name>.conf` with its own `server` block on `--site-port` (nginx option, default **8443**), same certificate and key as the API `server`, no key check, WebSocket and streaming headers, `client_max_body_size 50m`, and reloads after `nginx -t`. It prints `{ "url": "https://<server-name>:<site-port>/" }`, idempotent as `add-upstream` is.
- LibreChat binds **`127.0.0.1:3080`** (`--port`, `--bind`, host networking, see point 4); only nginx reaches it from outside. `install` calls `proxy add-site librechat http://127.0.0.1:3080` and records the returned URL as the state `url`.
- Consequence: `requires: ["nginx"]` (the name, not the type, since the site action belongs to nginx). The certificate is therefore **shared** (answers the open question of the [certificate decision](decision-nginx-certificates.md#open-questions)), and the browser warning of `self-signed` applies to the interface as well, as that decision already notes.

### 4. Reaching the models from the container

LibreChat and the engines run on the **same machine**, so the link between them needs neither HTTPS nor an API key: nothing leaves the host. The authentication of the proxy protects the access **from the network**, not this local link. The only obstacle is that, in a bridge container, `127.0.0.1` is the container itself, and an engine listening on the loopback of the host (Ollama and vLLM both default to it) is out of reach.

| Option | Pros | Cons |
| --- | --- | --- |
| **A. `network_mode: host` for the `api` container** | The container reaches the engines on `127.0.0.1` as they are; no change to the engines, no certificate, no key, no name resolution | The container shares the host network (less isolation); its port must be free on the host |
| **B. Engine bound to the Docker bridge gateway** | `api` stays in the Compose network | The LibreChat script would have to reconfigure the engine (coupling between components); the gateway address depends on the network; a fallback to `0.0.0.0` would expose the engine to the network without authentication |
| **C. Through the proxy (HTTPS, API key)** | No change to the networking | The container needs the certificate (trust), the server name resolved to the host, the API key in a file, and nginx listening on a reachable address: four mechanisms for a link that does not need protection |

**Decision: A.** (C was the first proposal of this document, carried over from the [CLI spec](spec-cli.md#steps), which linked the chat interface through the proxy URL. That spec is amended below.)

- The `api` service has `network_mode: host`. LibreChat listens on `HOST=127.0.0.1` and `PORT=3080` (the `--bind` and `--port` options), set in `librechat.env`; no `ports:` entry, which host mode ignores. The preflight checks that the port is free (contract, Preflight).
- `postgres` and `ferretdb` stay in the Compose network. `ferretdb` publishes `127.0.0.1:27017` only, so `api` reaches it with `MONGO_URI=mongodb://…@127.0.0.1:27017/LibreChat`. The preflight also checks that port 27017 is free, which catches a MongoDB already on the machine. The database credentials still protect it from other local users.
- **Endpoint URL**: `chat-interface add-endpoint <name> <url>` receives the **internal** OpenAI base URL of the engine: its state `endpoint.openai_base_url` (`http://127.0.0.1:11434/v1` for Ollama), or `http://127.0.0.1:<port>/v1` from the model entry for an engine with one instance per model. Nothing depends on the proxy, so `requires` of the endpoint step is the engine only.
- **`apiKey`**: LibreChat requires the field for a custom endpoint, the engines ignore it. `librechat.yaml` carries the constant placeholder `apiKey: "unused"`. It is not a secret and no key file is involved.
- **Effect**: `add-endpoint` edits `librechat.yaml` (a `custom` entry with `name`, `baseURL`, `models.default: [<model>]`, `fetch: false`, `titleConvo: false`), then **recreates only the `api` container** (`docker compose up -d --force-recreate api`, 14 s measured), only when the rendered file changed. It prints `{ "url": "<baseURL>" }`, the URL it was given. `remove-endpoint` removes the entry the same way. The state `endpoints` list follows.
- **External access to the models stays**: `add` still exposes every model through the proxy (HTTPS and API key, step 3), exactly as before, for clients outside the machine. LibreChat simply no longer goes through it. The two paths are independent: removing the proxy exposure of a model does not affect the chat, and unwiring the chat does not affect the external access.
- **Security note**: with host networking, the `api` container can reach every service that listens on the loopback of the machine, which is the point here, and is the reason the engines can stay on `127.0.0.1` without authentication. The administrator must not run, on the same machine, an unauthenticated loopback service that LibreChat should not reach.

### 5. Accounts

Accepted. The target use is an administrator who creates the VM with the post-install script, tries the product with `--defaults`, and is **the first to connect**, on a VM and a network they manage. Installing must stay simple, so there is no account step in the install.

- `ALLOW_REGISTRATION=true` **by default** (`--allow-registration false` closes it). In the FerretDB test the first registered account became `ADMIN` and the next ones are plain users (to re-check in the host-network test), so the account created first by the administrator is the administrator of LibreChat, and nothing has to be created by the script: no `--admin-email`, no generated password, no `show-admin-password`.
- **The risk is written down, not hidden.** With an open registration, anybody who reaches the web site can create an account and use the models, and the first registrant is the administrator. It is acceptable because the administrator owns the VM and its network, but it must be seen:
  - **at generation time**: the [VM script generator](spec-vm-generator.md) shows the warning in its summary when the effective value is `true`, so the administrator reads it before creating any VM. This comes from the `describe` of the script (an option can carry a `warn` entry, see [`describe`](spec-script-contract.md#describe)), not from code specific to LibreChat in the generator;
  - **at install time**: `install` logs a `WARN` on stderr (`registration is open: the first account created becomes the administrator, and anyone who reaches the site can sign up; close it with: easy-cs-ai install chat-interface librechat --allow-registration false`).
- **After the first connection**, the administrator has two ways, both with what exists:
  1. connect to the VM and run the LibreChat commands they need: close the registration (`install … --allow-registration false`, idempotent, recreates only the `api` container), or create accounts with the native command (`easy-cs-ai chat-interface librechat exec api npm run create-user`, which asks for an email, a password of at least 8 characters, and optionally a name of at least 3 characters and a user name, interactively);
  2. generate a new VM script with the options they want (`--allow-registration false`) and start a new VM.
- Tested with the host-network stack: the native command works **with the registration closed** and reads the password from a **piped stdin**, so a later unattended option (`--admin-email` with a password channel) is possible without a command-line password. It is left out of the first version on purpose, see the open questions.

## Consequences

- **CLI spec and contract amended** (done with this decision): step 4 of `add` links the chat interface to the engine's **internal** URL instead of the proxy URL, and step 3 (external exposure) no longer feeds it; `add-endpoint` prints the URL it was given. See [spec: CLI](spec-cli.md#steps) and [Type-specific actions](spec-script-contract.md#type-specific-actions).
- **Contract**: `proxy` gains `add-site` / `remove-site` (printing a `url`). The `describe` option schema gains an optional `warn` entry (see point 5). Lock rules are the existing ones (component lock of the script called).
- **nginx script**: `add-site` / `remove-site`, a `site.conf` template, the `--site-port` option (default 8443, in `describe`), and the state `listen` gains `site_port`. Existing tests stay valid: the API `server` is untouched.
- **`lib/common.sh`**: `ensure_docker` implemented and covered by `bats` tests in `EASY_CS_AI_ROOT` mode (which skips the installation, as for the other package helpers).
- **State**: `service.compose_file` filled, `endpoints`, `url`, `requires: ["nginx"]`, `params` with `port`, `bind`, `allow-registration` (never a secret), `secrets` listing `librechat.env` (JWT and credentials keys, database password). The `status` example of the [state format](spec-state-format.md) shows `0.7.5` for LibreChat and must read `0.8.7`.
- **Uninstall**: stops and removes the containers, the unit and the generated files, calls `proxy remove-site`, keeps the volume and Docker; `--purge` removes the volume and the images of the stack.
- **`install --defaults`** can now install the whole default stack (nginx, Ollama, LibreChat) without a MongoDB exception; the [CLI spec](spec-cli.md) note on the "LibreChat/MongoDB question" can be removed.
- **Tests**: `bats` covers options, templates (compose, `librechat.yaml`, `librechat.env`), idempotence, state, the loopback preflight and the endpoint edit. The real install is covered by the integration tests on a VM, as the other scripts.

## Open questions

- **Closing the registration automatically** once the first account exists (the administrator would no longer have to do it), left out to keep the install simple; to reconsider if open registrations are found in the field.
- **Allowed e-mail domains** (`registration.allowedDomains` of `librechat.yaml`, to check in this version) as a middle way between open and closed, only useful with an e-mail service.
- **Default endpoint for a new account**: a new account must pick the model once (otherwise the first message fails with `agent_id is required`). A default `modelSpecs` entry or a default endpoint in `librechat.yaml` may avoid it; to test when the script writes `librechat.yaml`. Without a model the selector is empty anyway: a default model per engine is noted in the [CLI spec](spec-cli.md#open-questions).
- **Offline VMs**: the apt repository of Docker and the three images come from the Internet. A mirror option (like the package mirror of the [VM script generator](decision-vm-generator.md)) and an `--image-archive` to load images offline are not designed.
- **`--site-port` and the browser**: 8443 avoids a clash with the API `server`, but a deployment that wants the interface on 443 needs another `server_name` for it, which `self-signed` on an IP address cannot give.
- **Memory**: about 420 MiB for the `api` container at idle with an empty database. Not measured with many users or conversations.
- **Meilisearch, RAG API, PGVector**: left out of the first version. Adding them is a new option, not a change of this decision.
