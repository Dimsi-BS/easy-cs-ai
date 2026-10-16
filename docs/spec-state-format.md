# Spec: state format

[← Back to docs](README.md)

**Status:** accepted

## Purpose

The state records what `easy-cs-ai` and the layer 1 scripts installed. It feeds `status` and the defaults of `add` (see [packaging](decision-packaging.md)). It is written by the scripts following the [script contract](spec-script-contract.md) and read by the CLI.

Principles:

- **Declared, not observed.** The state says what was installed and configured; whether it is running right now is probed live by `status`, never stored.
- **Single source of truth.** Every fact lives in exactly one file; relations are references by name, so nothing can drift.
- **Plain files, `jq`-readable**, as required by [scripting language](decision-scripting-language.md). No secret in any state file.

## Layout

```text
/var/lib/easy-cs-ai/
  .lock                       state lock, flock target, empty
  locks/                      one component lock file per component, see the script contract
  pending/
    ollama.json               install in progress or failed, see Pending manifest
  components/
    ollama.json               one file per installed component, carries its own `default` flag
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

1. Take the **state lock** (`/var/lib/easy-cs-ai/.lock`) around every read-modify-write. The `state_*` and `defaults_*` helpers take it themselves, so callers never hold it (it is not reentrant); it is held for the write only, never across an install or a health wait. See [Locking](spec-script-contract.md#locking) in the contract.
2. Write to a temporary file in the same directory, then `mv` over the target (atomic on one filesystem).
3. Validate with `jq empty` before the `mv`; a failure leaves the previous file untouched.
4. State is written only after a verified install (see the install phases in the contract). A failed install never leaves a component file behind; a re-run converges thanks to idempotence. What a failed install did create is tracked in the [pending manifest](#pending-manifest), not in the component file.
5. Readers ignore unknown fields; writers preserve the fields they do not know. Both allow newer scripts to add fields without breaking older ones.

## Defaults

The default component of a type is **explicit**: it is the one whose file has `"default": true`. There is no separate defaults file, so a default cannot point to a component that no longer exists.

- At most one component per type is the default.
- The first component installed for a type becomes its default (so a single-component setup needs no extra step). Any later one is not, and never takes the default silently. `install … --default` makes it the default.
- `uninstall` of the default: if exactly one component of that type remains, it is promoted; otherwise the type has **no default** and `add` requires `--engine` / `--chat-interface` explicitly, with an error naming the candidates. Nothing is guessed.
- `add` reads the defaults of `engine` and `chat-interface` here when `--engine` / `--chat-interface` are not given.
- Changing the default touches two files (set the new flag, clear the old one), which is not atomic. The writer sets the new flag first, then clears the others, under the state lock. Readers take no lock: one finding several defaults for one type re-reads once (a change may be in progress), then stops with an error naming the files (exit 1); re-running `install <type> <name> --default` repairs it, since it sets the flag on the target and clears all the others.

## Helpers

`lib/common.sh` is the only code that reads and writes these files (see the [contract](spec-script-contract.md#libcommonsh)). Component names are lowercase letters, digits and dashes (exit 2 otherwise), so a name is never a path.

| Helper | Behaviour |
| --- | --- |
| `state_write <name> <json>` | Under the state lock, merges the JSON over the existing file (top-level fields the writer does not know are kept, the new value wins otherwise). `name` must match and `type` must be one of the four types (exit 1 otherwise). `schema_version` is added when missing, `installed_at` is kept from the first write, and `updated_at` changes only when the content does: writing the same content again does not touch the file. When `default` is absent, the component is the default if none of its type is, which implements "the first component of a type becomes its default". `"default": true` sets the flag first, then clears the others |
| `state_read <name>` | Prints the file, no lock. Returns 1 with no output when the component has no state. Exit 1 when the file is damaged or its `schema_version` is higher than the library knows |
| `state_list [<type>]` | Names of the components that have a state, sorted |
| `state_remove <name>` | Under the state lock, deletes the file (nothing to do if absent). If it was the default and exactly one component of its type remains, that one is promoted; otherwise the type is left without default |
| `defaults_get <type>` | Prints the default, no lock. Returns 1 with no output when there is none. Several defaults are read again once after one second, then it is an error (exit 1) naming the components and the repair command |
| `defaults_set <type> <name>` | Under the state lock, sets the new flag, then clears the others. Exit 4 if the component is not installed or is of another type |

## `components/<name>.json`

```json
{
  "schema_version": 1,
  "name": "ollama",
  "type": "engine",
  "default": true,
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
  "service": { "unit": "ollama.service" },
  "requires": [],
  "files": ["/usr/local/bin/ollama", "/usr/local/lib/ollama", "/etc/systemd/system/ollama.service"],
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
| `default` | boolean | `true` when this is the default component of its type, see [Defaults](#defaults) |
| `version` | string | Installed component version (the pinned or `--version` one) |
| `script_version` | string | Version of the install script that wrote the state |
| `installed_at`, `updated_at` | string | ISO 8601 UTC; `updated_at` changes on any rewrite that changes content |
| `params` | object | Resolved **non-secret** parameters, so a re-install or a generated script reproduces the setup |
| `endpoint` | object, optional | How other components reach this one. `protected` is `true` when it already enforces HTTPS and API key itself (so `add` does not wrap it with the proxy) |
| `service` | object | `unit` is the systemd unit that runs the component (systemd is mandatory, see the [script contract](spec-script-contract.md#platform)). `compose_file`, optional, is the path of the Compose file the unit runs, for Docker-based components (LibreChat, AnythingLLM). Absent for an engine with one instance per model (see below) |
| `requires` | array of names | Components that must stay installed; `uninstall` of any of them is refused without `--force` |
| `files` | array of paths | Everything the script created outside data directories; removed by `uninstall` |
| `data_dirs` | array of paths | User data, kept by `uninstall` unless `--purge` |
| `secrets` | array of paths | **Paths** of secret files, never values |
| `models` | array, engines only | See below |

### Type-specific fields

- **`engine`**: `models`, each with `name`, `added_at`, `exposed_via` (name of the `proxy` component, or `null` when the engine is `protected` or the model is not exposed) and `linked_to` (names of `chat-interface` components). The model list is the single source: `status` and `add` read it here, the chat interface and proxy hold no copy. For an engine running **one instance per model** (vLLM, see the [script contract](spec-script-contract.md#engines-with-one-instance-per-model)), each model also has `unit` (its systemd unit, e.g. `vllm@llama3-8b.service`) and `port`, the instance being an internal detail of the engine, not a separate component. `models` may be empty (installed, no model yet), and the component-level `service` and `endpoint` are then absent for such an engine: each model carries its own.
- **`proxy`**: `upstreams`, array of `{ "name", "url" }` with the engine models they front (`url` is the **internal** URL of the model, which no other machine can use; the URL an external client uses is built from the server name in `params` and `listen.port`, and printed by `list-upstreams` (proposed), see the [script contract](spec-script-contract.md#type-specific-actions)), `sites`, array of `{ "name", "url" }` with the web sites it serves for browsers (`add-site`), and `listen` (`{ "address", "port", "site_port", "tls": "letsencrypt" | "self-signed" | "provided", "certificate" }`, `certificate` being the path of the certificate nginx serves; the strategy is decided in [decision: certificates](decision-nginx-certificates.md)).
- **`chat-interface`**: `endpoints`, array of `{ "name", "url", "model" }` declared in its configuration (for LibreChat, the entries of `librechat.yaml`; `model` is absent when none was given), and `url` of the web site. An endpoint declared by hand for an engine on another VM ([spec: two VMs](spec-two-vm.md#contract-additions)) is listed the same way, with the file of its API key in `secrets`; no engine state knows it, so it has no `linked_to`. A component that keeps data in a Docker volume lists it in `data_dirs` as `docker-volume:<name>`, which is not a path.
- **`provisioning`**: none beyond the common fields.

## Pending manifest

`components/<name>.json` is written only after a verified install, but `uninstall` removes what the state lists in `files`, `data_dirs` and `service`. A script that fails halfway would therefore leave files that nothing knows about. The **pending manifest** closes that gap without weakening the rule that the component file means "installed and verified".

`pending/<name>.json`:

```json
{
  "schema_version": 1,
  "name": "ollama",
  "type": "engine",
  "started_at": "2026-10-02T09:10:02Z",
  "files": ["/usr/local/bin/ollama"],
  "units": ["ollama.service"],
  "data_dirs": ["/usr/share/ollama/.ollama"]
}
```

- **Write-ahead**: the path, unit or directory is added to the manifest *before* it is created (`track_file`, `track_unit`, `track_data_dir`, see the [contract](spec-script-contract.md#libcommonsh)). A crash between the two leaves an entry for something that does not exist, which is harmless; the opposite would leave an orphan.
- Written under the component lock only, since only the holder of that lock touches it; no state lock is needed. Same atomic write (temp file, `jq empty`, `mv`) as the state.
- Created at the start of `install` (or reused if it exists: a re-run completes it). It records only what this project creates, never shared system packages.
- On a successful *Record*, `files`, `data_dirs` and `service.unit` of the component file are the union of what the manifest and the script list, then the manifest is deleted. A failed upgrade leaves the old component file untouched, plus a manifest of what the upgrade added.
- `uninstall` acts on the union of the component file and the manifest, then deletes both (see the [contract](spec-script-contract.md#uninstall)).
- `status` ignores it: a component with only a manifest is "not installed" (exit 4). The CLI mentions leftovers in `status` on stderr (`WARN ollama: failed install pending, run: easy-cs-ai uninstall engine ollama`) and `uninstall --all` includes them (see [spec: CLI](spec-cli.md#uninstall)).
- Paths follow the same convention as `files` (logical absolute paths, `EASY_CS_AI_ROOT` applied when used).

## What `status` combines

`easy-cs-ai status` lists every `components/*.json` and, for each, calls `<script> status` (live probe). The output merges both:

```text
COMPONENT     TYPE            VERSION   DEFAULT  RUNNING  HEALTHY  MODELS
ollama        engine          0.5.7     yes      yes      yes      llama3.2:3b
nginx         proxy           1.24.0    yes      yes      yes      -
librechat     chat-interface  0.8.7     yes      yes      yes      -
```

A component with a state file but a failing probe is shown as installed and not healthy, never silently hidden. A component running on the machine but absent from the state is not reported: the state only covers what the tool installed.

## Versioning and evolution

- `schema_version` is an integer, bumped only for **breaking** changes (renamed or removed field, changed meaning). Adding an optional field is not a bump.
- A reader meeting a higher `schema_version` than it knows stops with a clear message (exit 1) rather than guessing.
- Migrations are done by the CLI (`easy-cs-ai` package upgrade step), one function per version step, applied under the state lock, writing a backup `components/<name>.json.bak-v<old>` first.

## Not stored

- Secret values, and anything derivable by a probe (running, healthy, resource usage).
- Cloud/VM provisioning information; that belongs to layer 3 and CloudStack, not designed yet.
- Logs and metrics ("is the model being used?" is a CloudStack idea, out of scope here). The history of actions is not kept here either: the scripts write it to the system journal, see the [Action journal](spec-script-contract.md#action-journal) of the contract.

## Open questions

- Multiple instances of the same *component* (two Ollama on two ports) are **not** supported by this format; `name` is unique. The only instances are the per-model ones of an engine like vLLM, kept inside `models`. Revisit if a use case appears.
