# Decision: how LibreChat is installed

[← Back to docs](README.md)

**Status:** proposed

## Context

[LibreChat](../search/librechat.md) is the first chat interface in the [integration order](decision-integration-order.md) and the first **Docker-based** component: the [script contract](spec-script-contract.md) reserves `ensure_docker` for it without implementing it, and the state format foresees `service.compose_file` for it. The generic contract (actions, phases, secrets, locks, exit codes) and the type-specific actions `add-endpoint` / `remove-endpoint` are specified, and the database question is settled: LibreChat runs on **FerretDB + PostgreSQL** instead of MongoDB (SSPL), tested with LibreChat v0.8.7, FerretDB 2.7.0 and PostgreSQL with the DocumentDB extension (see the [FerretDB test](../search/librechat.md#ferretdb-test)).

Five points are not specified, and the install script cannot be written without them:

1. how Docker is installed;
2. what the stack is made of, how it is pinned and run;
3. how the web interface is served over HTTPS, since [nginx](../search/nginx.md) currently requires the API key on **every** path and a browser cannot send it;
4. how the container reaches the models, through a proxy with a self-signed certificate and an API key;
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

  The compose file references `image: <name>@<digest>`, so a moved tag changes nothing. `--version <x.y.z>` selects another **LibreChat** release, resolved by tag only, with a `WARN` (no known digest). FerretDB and PostgreSQL are a **pair** whose versions are tied together by the FerretDB project: they are pinned with the script and not exposed as options. The test used the all-in-one `ferretdb-eval` image of the FerretDB guide, documented as dev/test only, so it is **not** used: a plain PostgreSQL is not enough either, FerretDB 2.x needs the DocumentDB build.
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
- LibreChat binds **`127.0.0.1:3080`** (`--port`, `--bind`); only nginx reaches it from outside. `install` calls `proxy add-site librechat http://127.0.0.1:3080` and records the returned URL as the state `url`.
- Consequence: `requires: ["nginx"]` (the name, not the type, since the site action belongs to nginx). The certificate is therefore **shared** (answers the open question of the [certificate decision](decision-nginx-certificates.md#open-questions)), and the browser warning of `self-signed` applies to the interface as well, as that decision already notes.
- Since the site shares the certificate, `proxy`'s `listen.certificate` is what the next point uses.

### 4. Reaching the models from the container

`chat-interface add-endpoint <name> <url>` receives the URL printed by `proxy add-upstream`: `https://<server-name>:<port>/<upstream>/v1`, a self-signed certificate valid for `<server-name>`, `localhost` and `127.0.0.1`, and an API key.

- **Name resolution**: the container resolves `<server-name>` to the host with `extra_hosts: "<server-name>:host-gateway"` in the compose file (skipped when `<server-name>` is an IP address). The URL stays **identical** and the certificate stays valid, where `host.docker.internal` would fail the name check.
- **Reachability**: nginx must listen on an address the Docker network can reach. Preflight reads the proxy state: if `listen.address` is the loopback, **exit 4** with the message `nginx listens on 127.0.0.1, the LibreChat container cannot reach it: reinstall nginx with --bind 0.0.0.0` (the nginx default is `0.0.0.0`, so this only catches an explicit choice). The firewall is not managed (out of scope, like for nginx).
- **Trust**: the certificate file recorded in the proxy state (`listen.certificate`) is mounted read-only into the `api` container and `NODE_EXTRA_CA_CERTS` points to it. With `letsencrypt`, the system store of the image is enough and the mount is skipped. With `provided`, the certificate is mounted like the self-signed one (it may come from an internal CA).
- **API key**: `librechat.yaml` never contains it. Each endpoint has `apiKey: "${EASY_CS_AI_<NAME>_KEY}"`, and the value is written to `librechat.env` (mode `0600`), read by the script from the nginx secret file listed in the proxy state `secrets` (`/etc/easy-cs-ai/secrets/nginx.api-key`). It is neither printed nor put in the state (contract, Secrets). Rotating the key at nginx is followed by a re-run of `add-endpoint` for each endpoint (idempotent, re-renders `librechat.env`).
- **Effect**: `add-endpoint` edits `librechat.yaml` (a `custom` entry with `name`, `baseURL`, `models.default: [<model>]`, `fetch: false`, `titleConvo: false`), then **recreates only the `api` container** (`docker compose up -d --force-recreate api`, a few seconds), only when the rendered file or `librechat.env` changed. It prints `{ "url": "<baseURL>" }`. `remove-endpoint` removes the entry the same way. The state `endpoints` list follows.

### 5. Accounts

- `ALLOW_REGISTRATION=false` **by default**. In the test the first registered account became `ADMIN`, so an open registration on a reachable VM would hand the instance to whoever registers first. `--allow-registration true` opens it, with a `WARN` naming that consequence.
- **First administrator**: optional `--admin-email <address>` (with `--admin-name`, default the part before the `@`) creates the account at install, through LibreChat's own command (`npm run create-user`, run by `docker compose exec -T api`, so the project reimplements nothing, see [Wrapping native tools](spec-script-contract.md#wrapping-native-tools)). The password follows the secret channels (`--admin-password-file`, environment variable, or `-` for stdin), and is **generated** when none is given, stored in `/etc/easy-cs-ai/secrets/librechat.admin-password`. It is never put on a command line (including `docker exec`, visible in `ps`) nor printed.
- Without `--admin-email`, no account exists and nothing is guessed: the administrator creates it with the native command, `easy-cs-ai chat-interface librechat exec api npm run create-user` (interactive, the CLI forwards the TTY).
- Retrieving a generated password is a new action **`show-admin-password`**, like `proxy show-key`, over SSH only.

## Consequences

- **Contract**: `proxy` gains `add-site` / `remove-site` (printing a `url`), and `chat-interface` gains `show-admin-password` in its table. Their lock rules are the existing ones (component lock of the script called).
- **nginx script**: `add-site` / `remove-site`, a `site.conf` template, the `--site-port` option (default 8443, in `describe`), and the state `listen` gains `site_port`. Existing tests stay valid: the API `server` is untouched.
- **`lib/common.sh`**: `ensure_docker` implemented and covered by `bats` tests in `EASY_CS_AI_ROOT` mode (which skips the installation, as for the other package helpers).
- **State**: `service.compose_file` filled, `endpoints`, `url`, `requires: ["nginx"]`, `params` with `port`, `bind`, `allow-registration` (never the password or the key), `secrets` listing `librechat.env` and `librechat.admin-password`. The `status` example of the [state format](spec-state-format.md) shows `0.7.5` for LibreChat and must read `0.8.7`.
- **Uninstall**: stops and removes the containers, the unit and the generated files, calls `proxy remove-site`, keeps the volume and Docker; `--purge` removes the volume and the images of the stack.
- **`install --defaults`** can now install the whole default stack (nginx, Ollama, LibreChat) without a MongoDB exception; the [CLI spec](spec-cli.md) note on the "LibreChat/MongoDB question" can be removed.
- **Tests**: `bats` covers options, templates (compose, `librechat.yaml`, `librechat.env`), idempotence, state, the loopback preflight and the endpoint edit. The real install is covered by the integration tests on a VM, as the other scripts.

## Open questions

- **First administrator without a command-line password**: whether `npm run create-user` reads the password from a piped stdin must be tested. If it does not, the options are a one-shot invitation or password-reset link, or leaving the account creation to the native command only.
- **Offline VMs**: the apt repository of Docker and the three images come from the Internet. A mirror option (like the package mirror of the [VM script generator](decision-vm-generator.md)) and an `--image-archive` to load images offline are not designed.
- **`--site-port` and the browser**: 8443 avoids a clash with the API `server`, but a deployment that wants the interface on 443 needs another `server_name` for it, which `self-signed` on an IP address cannot give.
- **Rotation of the API key**: re-running `add-endpoint` for each endpoint is manual. A `chat-interface` action to refresh the key of every endpoint would avoid the loop.
- **Memory**: about 420 MiB for the `api` container at idle with an empty database. Not measured with many users or conversations.
- **Meilisearch, RAG API, PGVector**: left out of the first version. Adding them is a new option, not a change of this decision.
