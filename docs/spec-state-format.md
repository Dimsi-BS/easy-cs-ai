# Spec: state format

[← Back to docs](README.md)

**Status:** proposed

## Purpose

The state records what `easy-cs-ai` and the layer 1 scripts installed. It feeds `status` and the defaults of `add` (see [packaging](decision-packaging.md)). It is written by the scripts following the [script contract](spec-script-contract.md) and read by the CLI.

Principles:

- **Declared, not observed.** The state says what was installed and configured; whether it is running right now is probed live by `status`, never stored.
- **Single source of truth.** Every fact lives in exactly one file; relations are references by name, so nothing can drift.
- **Plain files, `jq`-readable**, as required by [scripting language](decision-scripting-language.md). No secret in any state file.

## Layout

```text
/var/lib/easy-cs-ai/
  .lock                       flock target, empty
  defaults.json               default component per type
  components/
    ollama.json               one file per installed component
    nginx.json
    librechat.json
/etc/easy-cs-ai/
  secrets/                    mode 0700, root; files 0600
    nginx.api-key
  <component>/                generated configuration, mode 0755 (files 0644 unless secret)
```

- The state directory is mode `0755`, files `0644`, owner root. Nothing sensitive is stored there, so `status` can run unprivileged.
- Paths honour `EASY_CS_AI_ROOT`, `EASY_CS_AI_STATE_DIR` and `EASY_CS_AI_CONFIG_DIR`.

## Writing rules

1. Take the global lock (`/var/lib/easy-cs-ai/.lock`) around every read-modify-write.
2. Write to a temporary file in the same directory, then `mv` over the target (atomic on one filesystem).
3. Validate with `jq empty` before the `mv`; a failure leaves the previous file untouched.
4. State is written only after a verified install (see the install phases in the contract). A failed install never leaves a component file behind; a re-run converges thanks to idempotence.
5. Readers ignore unknown fields; writers preserve the fields they do not know. Both allow newer scripts to add fields without breaking older ones.

## `defaults.json`

```json
{
  "schema_version": 1,
  "engine": "ollama",
  "chat-interface": "librechat",
  "proxy": "nginx"
}
```

- Keys are component types, values are component names; a type with nothing installed has no key.
- The first component installed for a type becomes its default. `install … --default` forces it; `uninstall` of the default clears the key (or promotes the only remaining component of that type).
- `add` reads `engine` and `chat-interface` from here when `--engine` / `--chat-interface` are not given.

## `components/<name>.json`

```json
{
  "schema_version": 1,
  "name": "ollama",
  "type": "engine",
  "version": "0.5.7",
  "script_version": "0.1.0",
  "installed_at": "2026-10-02T09:12:44Z",
  "updated_at": "2026-10-02T09:12:44Z",
  "params": { "port": "11434", "bind": "127.0.0.1" },
  "endpoint": {
    "url": "http://127.0.0.1:11434",
    "openai_base_url": "http://127.0.0.1:11434/v1",
    "protected": false
  },
  "service": { "manager": "systemd", "unit": "ollama.service" },
  "requires": [],
  "files": ["/usr/local/bin/ollama", "/etc/systemd/system/ollama.service.d/easy-cs-ai.conf"],
  "data_dirs": ["/usr/share/ollama/.ollama"],
  "secrets": [],
  "models": [
    {
      "name": "llama3.2:3b",
      "added_at": "2026-10-02T09:20:01Z",
      "exposed_via": "nginx",
      "linked_to": ["librechat"]
    }
  ]
}
```

### Fields

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Format version of this file, see below |
| `name`, `type` | string | Component name and type (`engine`, `chat-interface`, `proxy`, `provisioning`), same as in `describe` |
| `version` | string | Installed component version (the pinned or `--version` one) |
| `script_version` | string | Version of the install script that wrote the state |
| `installed_at`, `updated_at` | string | ISO 8601 UTC; `updated_at` changes on any rewrite that changes content |
| `params` | object | Resolved **non-secret** parameters, so a re-install or a generated script reproduces the setup |
| `endpoint` | object, optional | How other components reach this one. `protected` is `true` when it already enforces HTTPS and API key itself (so `add` does not wrap it with the proxy) |
| `service` | object | `manager` is `systemd` or `docker-compose`, plus the unit name or compose path |
| `requires` | array of names | Components that must stay installed; `uninstall` of any of them is refused without `--force` |
| `files` | array of paths | Everything the script created outside data directories; removed by `uninstall` |
| `data_dirs` | array of paths | User data, kept by `uninstall` unless `--purge` |
| `secrets` | array of paths | **Paths** of secret files, never values |
| `models` | array, engines only | See below |

### Type-specific fields

- **`engine`**: `models`, each with `name`, `added_at`, `exposed_via` (name of the `proxy` component, or `null` when the engine is `protected` or the model is not exposed) and `linked_to` (names of `chat-interface` components). The model list is the single source: `status` and `add` read it here, the chat interface and proxy hold no copy.
- **`proxy`**: `upstreams`, array of `{ "name", "url" }` with the engine models they front, and `listen` (`{ "address", "port", "tls": "letsencrypt" | "self-signed" | "provided" }`; the strategy is still an open design decision, see [nginx](../search/nginx.md)).
- **`chat-interface`**: `endpoints`, array of `{ "name", "url" }` declared in its configuration (for LibreChat, the entries of `librechat.yaml`), and `url` of the web site.
- **`provisioning`**: none beyond the common fields.

## What `status` combines

`easy-cs-ai status` lists every `components/*.json` and, for each, calls `<script> status` (live probe). The output merges both:

```text
COMPONENT     TYPE            VERSION   DEFAULT  RUNNING  HEALTHY  MODELS
ollama        engine          0.5.7     yes      yes      yes      llama3.2:3b
nginx         proxy           1.24.0    yes      yes      yes      -
librechat     chat-interface  0.7.5     yes      yes      yes      -
```

A component with a state file but a failing probe is shown as installed and not healthy, never silently hidden. A component running on the machine but absent from the state is not reported: the state only covers what the tool installed.

## Versioning and evolution

- `schema_version` is an integer, bumped only for **breaking** changes (renamed or removed field, changed meaning). Adding an optional field is not a bump.
- A reader meeting a higher `schema_version` than it knows stops with a clear message (exit 1) rather than guessing.
- Migrations are done by the CLI (`easy-cs-ai` package upgrade step), one function per version step, applied under the lock, writing a backup `components/<name>.json.bak-v<old>` first.

## Not stored

- Secret values, and anything derivable by a probe (running, healthy, resource usage).
- Cloud/VM provisioning information; that belongs to layer 3 and CloudStack, not designed yet.
- Logs and metrics ("is the model being used?" is a CloudStack idea, out of scope here).

## Open questions

- Whether `defaults.json` should be derived on the fly from the component files plus an explicit `default: true` flag (one fewer file, but ties the default to the file of the component).
- Whether an append-only `history.log` of installs and changes is wanted for support and audit.
- Multiple instances of the same component (two Ollama on two ports) are **not** supported by this format; `name` is unique. Revisit if a use case appears.
