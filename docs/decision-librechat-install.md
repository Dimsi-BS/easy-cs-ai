# Decision: how LibreChat is installed

[← Back to docs](README.md)

**Status:** accepted on 2026-10-09 (points 1 to 5); point 5 amended on 2026-10-10 (the registration closes by itself after the first account, specified here, **not implemented yet**). The open questions at the end are deferred and do not block the implementation.

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
- otherwise adds the repository (signing key stored in `/etc/apt/keyrings/docker.asc`, **its fingerprint checked** against the one Docker publishes, source in `/etc/apt/sources.list.d/docker.list`), then installs the four packages through `apt_install` and enables `docker.service`. The key, the source and the unit are **not** recorded in the pending manifest, so `uninstall` never removes them;
- exits 5 when the repository is unreachable or the key does not match, 3 on an unsupported distribution or architecture (Debian and Ubuntu, `amd64` and `arm64`; a derivative follows its parent, a release without a codename is refused);
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
- **Files**: compose file `/etc/easy-cs-ai/librechat/docker-compose.yml` (rendered from a template, recorded as `service.compose_file`), `/etc/easy-cs-ai/librechat/librechat.yaml`, and two secret files, `/etc/easy-cs-ai/secrets/librechat.env` (the api: keys, registration, database URI) and `librechat-db.env` (PostgreSQL and FerretDB: the database password), mode `0600`, root. Generated once and **kept by every later run**: the database holds the password, and the keys decrypt what LibreChat stored. Data: the PostgreSQL named volume, recorded in `data_dirs` as `docker-volume:<name>` (it is not a path), kept by `uninstall` and removed by `--purge` (`docker compose down -v --rmi all`).
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

- The sign-up is set by one option, `--registration` (`first-account` by default, see [below](#the-registration-option)). In the FerretDB test the first registered account became `ADMIN` and the next ones are plain users (to re-check in the host-network test), so the account created first by the administrator is the administrator of LibreChat, and nothing has to be created by the script: no `--admin-email`, no generated password, no `show-admin-password`.
- **The registration closes by itself after the first account** (amended 2026-10-10, see [below](#the-registration-option)). `install --defaults` is how an administrator **tries the product** (a proof of concept on a VM they manage): the first person to connect becomes the administrator, and nobody else can sign up afterwards, with no command to remember.
- **The risk is written down, not hidden.** Until the first account exists, anybody who reaches the web site can create it and becomes the administrator; this window stays, and it is the reason for the install-time and generation-time warnings. It is acceptable because the administrator owns the VM and its network and connects right after the install, but it must be seen:
  - **at generation time**: the [VM script generator](spec-vm-generator.md) shows the warning in its summary when the effective mode is `first-account` or `open`, so the administrator reads it before creating any VM. This comes from the `describe` of the script (an option can carry a `warn` entry, see [`describe`](spec-script-contract.md#describe)), not from code specific to LibreChat in the generator;
  - **at install time**: `install` logs a `WARN` on stderr while the registration is open (`registration is open until the first account is created: that account becomes the administrator, and whoever reaches the site first can create it; then the registration closes by itself`).
- **After the first connection**, the registration is closed, and the administrator has two ways to add people, both with what exists:
  1. connect to the VM and create accounts with the native command (`easy-cs-ai exec chat-interface librechat exec api npm run create-user`, which asks for an email, a password of at least 8 characters, and optionally a name of at least 3 characters and a user name, interactively);
  2. generate a new VM script with the options they want and start a new VM.
- Tested with the host-network stack: the native command works **with the registration closed** and reads the password from a **piped stdin**, so a later unattended option (`--admin-email` with a password channel) is possible without a command-line password. It is left out of the first version on purpose, see the open questions.

#### The `registration` option

- **Option** `--registration <mode>` (env `EASY_CS_AI_LIBRECHAT_REGISTRATION`, type `enum`, **`first-account` by default**, in the `describe`, so that `apply` and the generator validate it). It **replaces** `--allow-registration` (the two booleans it was going to be combined with made too many combinations). The modes:

  | Mode | Sign-up | Warning |
  | --- | --- | --- |
  | `first-account` (default) | Open until the first account exists, then closed | While open, yes (the window before the first connection) |
  | `open` | Open to anybody, for good (the former default) | Yes |
  | `domain` | Open for good to the e-mail domains of `registration-domains`, with e-mail verification, see [spec: e-mail verification](spec-librechat-mail-options.md) | No (verified, restricted) |
  | `closed` | Closed from the install; accounts are created with the native command | No |

  The generator and `config validate` show the mode in words in their summary; the `warn` entries of `describe` apply to `first-account` and `open`. A configuration or a generated script that still carries `allow-registration` is an unknown option (exit 2): the project is a release candidate, and the option is replaced rather than kept as an alias.
- **Mechanism of `first-account`**: a systemd timer and its oneshot service, installed with the stack, only in this mode while the registration is open. Each run counts the accounts of LibreChat; at the first one it closes the registration (the same render as `--registration closed`, which recreates only the `api` container), records the result in the state and disables the timer. The timer is persistent, so it survives a reboot, and `uninstall` removes both units. How the accounts are counted (a query on the FerretDB database, or a command in the `api` container) and the polling interval (a few seconds to a minute) are to be measured on the VM before the implementation; the check must not need a secret on a command line.
- **Idempotence**: a re-run of the install in `first-account` mode **never reopens** a closed registration, and an install that finds an account (a reinstall that kept the data, a re-run after the first connection) closes at once instead of opening and watching. Opening it again takes an explicit `--registration open` or `--registration domain`. A re-run without the option keeps the recorded mode, as for the other options.
- **State**: `params` gain `registration` (the mode asked), and the component records what is true now in `registration_state`: `open` or `closed`, with `closed_by` (`mode` or `first-account`). `status` shows it, so that an administrator can see whether the window is still open. Never a secret.
- **Purge**: `uninstall --purge` removes the data, so the next install finds no account and opens the registration again in `first-account` mode, as a first install.
- **Not covered, on purpose**: closing the window before the first connection (the administrator connects right after the install, see the risk above), an invitation or a first-login token, and the creation of other accounts by the product (the native command stays the way). E-mail based sign-up is planned separately, see the open questions.

## Consequences

- **CLI spec and contract amended** (done with this decision): step 4 of `add` links the chat interface to the engine's **internal** URL instead of the proxy URL, and step 3 (external exposure) no longer feeds it; `add-endpoint` prints the URL it was given. See [spec: CLI](spec-cli.md#steps) and [Type-specific actions](spec-script-contract.md#type-specific-actions).
- **Contract**: `proxy` gains `add-site` / `remove-site` (printing a `url`), and `chat-interface add-endpoint` takes `--model <model>` (the CLI passes it from `add`, otherwise LibreChat would fetch the models of the engine and list them all under each endpoint). The `describe` option schema gains an optional `warn` entry (see point 5). Lock rules are the existing ones (component lock of the script called).
- **nginx script**: `add-site` / `remove-site`, a `site.conf` template, the `--site-port` option (default 8443, in `describe`), and the state `listen` gains `site_port`. Existing tests stay valid: the API `server` is untouched.
- **`lib/common.sh`**: `ensure_docker` implemented and covered by `bats` tests in `EASY_CS_AI_ROOT` mode (which skips the installation, as for the other package helpers).
- **State**: `service.compose_file` filled, `endpoints`, `url`, `requires: ["nginx"]`, `params` with `port`, `bind`, `registration` (never a secret), `secrets` listing `librechat.env` (JWT and credentials keys, database URI) and `librechat-db.env` (database password), `endpoints` entries `{ name, url, model }`, `url` the public URL given by `proxy add-site`. The `status` example of the [state format](spec-state-format.md) shows `0.7.5` for LibreChat and must read `0.8.7`.
- **Uninstall**: stops and removes the containers, the unit and the generated files, then calls `proxy remove-site` (best effort), and keeps **the volume, the secrets** and Docker; `--purge` removes the volume, the images of the stack and the secrets. The secrets stay with the volume on purpose: a reinstall finds the database again only with its password.
- **`install --defaults`** can now install the whole default stack (nginx, Ollama, LibreChat) without a MongoDB exception; the [CLI spec](spec-cli.md) note on the "LibreChat/MongoDB question" can be removed.
- **To amend when the closing is implemented** (point 5, 2026-10-10): the `describe` of the LibreChat script (`registration` replaces `allow-registration`, with its `warn` entries), the `ALLOW_REGISTRATION` of the env template, the [state format](spec-state-format.md) (`params`, `registration_state`), `status`, the [config spec](spec-config.md) and the [AI interface](spec-ai-interface.md) examples that show `allow-registration`, the install warning (it names `--allow-registration`), the README (Getting started tells the administrator to close the registration by hand), and the unit and VM tests (the registration is closed after the first account, a re-run keeps it closed, a purge opens it again).
- **Tests**: `bats` covers options, templates (compose, `librechat.yaml`, `librechat.env`), idempotence, state, the loopback preflight and the endpoint edit. The real install is covered by the integration tests on a VM, as the other scripts.

## Open questions

- **Self-service sign-up for a domain, with e-mail verification** (planned, in steps, **not part of `install --defaults`**): the administrator, once connected, opens the sign-up to their own e-mail domain and turns the verification on. It cannot be a default because it depends on what the installer cannot know: a relay or an outbound path for the mail (port 25 is often blocked), the public URL that goes into the verification link (`DOMAIN_CLIENT`, today the host name and the site port), and a recipient mail server that accepts the VM. Planned order:
  1. an optional `mail` component (Postfix, send-only, on the loopback, never an open relay, with a relay-host option and a test action), installed on request;
  2. `--registration-domains` (`registration.allowedDomains` of `librechat.yaml`, to check in 0.8.7) and a `--public-url`, refused unless the verification and a mail path are set up: specified in [spec: LibreChat options for e-mail verification](spec-librechat-mail-options.md), with an SMTP relay given by the administrator (the `mail` component of 1 is optional, and the relay is checked at install rather than by a test mail). Without verification a domain list only checks the text of the address, anybody can type one: it is never offered as a protection.

  To test before specifying them: how LibreChat treats the administrator account created before the verification is on, which settings need a recreation of the `api` container, and the verification link behind a self-signed certificate.
- **Default endpoint for a new account**: a new account must pick the model once (otherwise the first message fails with `agent_id is required`). A default `modelSpecs` entry or a default endpoint in `librechat.yaml` may avoid it; to test when the script writes `librechat.yaml`. Without a model the selector is empty anyway: `install --defaults` now adds a [default model](spec-cli.md#default-model).
- **Offline VMs**: the apt repository of Docker and the three images come from the Internet. A mirror option (like the package mirror of the [VM script generator](decision-vm-generator.md)) and an `--image-archive` to load images offline are not designed.
- **`--site-port` and the browser**: 8443 avoids a clash with the API `server`, but a deployment that wants the interface on 443 needs another `server_name` for it, which `self-signed` on an IP address cannot give.
- **Memory**: about 420 MiB for the `api` container at idle with an empty database. Not measured with many users or conversations.
- **Meilisearch, RAG API, PGVector**: left out of the first version. Adding them is a new option, not a change of this decision.
