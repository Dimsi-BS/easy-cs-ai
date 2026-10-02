# Spec: install script contract

[← Back to docs](README.md)

**Status:** proposed

## Purpose

Every layer 1 script (Ollama, vLLM, nginx, llmfit, LibreChat, AnythingLLM…) obeys the same contract. The layer 2 CLI is then a plain dispatcher, the generators know what to fix, and a component can be swapped for another of the same type by changing one parameter (see [integration order](decision-integration-order.md), rule 3).

This contract builds on the conventions of [scripting language](decision-scripting-language.md) and [packaging](decision-packaging.md); it does not repeat them. The state written by the scripts is specified in [state format](spec-state-format.md).

## Layout

```text
install_scripts/
  lib/common.sh            shared helpers, sourced by every script
  engine/ollama.sh         one script per component, grouped by type
  engine/vllm.sh
  proxy/nginx.sh
  provisioning/llmfit.sh
  chat-interface/librechat.sh
  templates/<component>/   envsubst templates and drop-in files
```

- Component **type** is one of `engine`, `chat-interface`, `proxy`, `provisioning`. The first two are the `<component-type>` values of `easy-cs-ai install` (see [CLI commands](cli-commands.md)).
- The script name is the component name used on the CLI (`install engine ollama` runs `engine/ollama.sh install`).
- A script must work **standalone** (without the CLI) and must be **inlinable** by the [generators](../generators/README.md): the only external code it needs is `lib/common.sh`, so the generator can concatenate library + script + fixed parameter values into one file. No script may source anything else or locate files relative to itself except through `EASY_CS_AI_LIB`.

## Invocation

```text
<component>.sh <action> [options]
```

Scripts **never prompt**. A missing mandatory parameter is a usage error (exit 2). This is what makes them usable from cloud-init and the generators.

### Mandatory actions

| Action | Effect |
| --- | --- |
| `install` | Install and configure the component, start it, verify it, record the state. Also reconfigures when run again with different parameters |
| `uninstall` | Stop and remove what the component installed, remove its state. Never removes shared system packages (Docker, `jq`…) nor user data unless `--purge` is given |
| `status` | Print the live status as JSON (see below) |
| `describe` | Print static metadata as JSON (see below), without needing root or any installed state |

### Type-specific actions

Components of one type expose the same actions, so switching is one parameter:

| Type | Actions |
| --- | --- |
| `engine` | `add-model <name>`, `remove-model <name>`, `list-models` |
| `proxy` | `add-upstream <name> <url>`, `remove-upstream <name>`, `show-key` |
| `chat-interface` | `add-endpoint <name> <url>`, `remove-endpoint <name>` |
| `provisioning` | `recommend` (JSON on stdout) |

These are the "component commands" mirrored by `easy-cs-ai <component-name> …`. `easy-cs-ai add` orchestrates them: `provisioning recommend` check → `engine add-model` → `proxy add-upstream` if needed → `chat-interface add-endpoint`.

## Parameters

- Options use `--kebab-case value`. Every option also has an environment variable `EASY_CS_AI_<COMPONENT>_<OPTION>` in upper snake case (`--port` for Ollama → `EASY_CS_AI_OLLAMA_PORT`).
- Precedence: command line > environment > built-in default. A generated script replaces the built-in defaults by fixed values; nothing else changes.
- Parsing lives in one function of the script (`parse_args`), so the generator has a single place to inject fixed values.
- Common options, accepted by every action unless it makes no sense: `--help`, `--version`, `--verbose`, `--dry-run`, `--json`.
- `--dry-run` prints what would be done (packages, files, units) on stderr, changes nothing, and exits 0 if the real run would pass preflight.
- Unknown options are a usage error (exit 2), never ignored.

### Secrets

- Never on the command line (see conventions). Accepted channels: `--<name>-file <path>` (file mode must be `0600` or stricter, else exit 2), the environment variable, or `-` to read stdin.
- If a secret is needed and none is given, the script **generates** one (`/dev/urandom`, at least 32 random bytes, base64url) and stores it in `/etc/easy-cs-ai/secrets/<component>.<name>` with mode `0600`, owner root. Generated secrets are never printed by `install`; they are read back with the dedicated action (`proxy show-key`).
- Secrets never appear in logs, `--dry-run` output, `describe`, `status` or the state files.

## Output

- **stderr**: logs, one line each, `[LEVEL] message` with LEVEL in `INFO`, `WARN`, `ERROR`, plus `DEBUG` with `--verbose`.
- **stdout**: reserved for machine-readable output (JSON of `status`, `describe`, `list-models`, `recommend`, or a secret printed on explicit request). Nothing else may write to stdout, including the commands the script runs (redirect them to stderr).
- Dates are ISO 8601 UTC.

### `describe`

```json
{
  "schema_version": 1,
  "name": "ollama",
  "type": "engine",
  "script_version": "0.1.0",
  "component_version": "pinned default, e.g. 0.5.7",
  "requires": [],
  "provides": ["openai-api"],
  "platforms": ["debian", "ubuntu"],
  "options": [
    { "name": "port", "env": "EASY_CS_AI_OLLAMA_PORT", "default": "11434", "secret": false, "description": "…" }
  ],
  "actions": ["install", "uninstall", "status", "describe", "add-model", "remove-model", "list-models"]
}
```

`describe` is the single source for `--help` text, CLI completion, and the parameter list the generators expose.

### `status`

```json
{ "schema_version": 1, "name": "ollama", "installed": true, "running": true, "healthy": true, "version": "0.5.7" }
```

`status` probes the real system (unit state, health endpoint) and compares it to the recorded state; it does not trust the state file alone. Exit code: 0 if healthy, 6 if installed but not healthy, 4 if not installed.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, including "nothing to do" |
| 1 | Unexpected runtime error |
| 2 | Usage error: bad or missing option, unknown action |
| 3 | Unsupported platform (distribution, architecture, missing systemd or GPU when required) |
| 4 | Precondition not met: not root, required component not installed or not running, target not installed |
| 5 | Network or download failure (checksum mismatch included) |
| 6 | Post-install verification failed (health check) |

Anything else is reserved. The CLI maps these codes to its own messages.

## Behaviour of `install`

Phases, in order. A failure in any phase stops the script with the matching exit code; the state is written only at the end of a fully verified install.

1. **Preflight**: root, supported platform, `requires` satisfied (the script **checks** other components, it never installs them), free disk/RAM when it matters, port not taken by another process. No side effect.
2. **Acquire**: take the global lock (`flock` on `/var/lib/easy-cs-ai/.lock`, waits up to 60 s, then exit 1). Download with checksum verification; versions are **pinned** in the script, `--version` overrides.
3. **Install**: system packages through `apt-get` (non-interactive, `DEBIAN_FRONTEND=noninteractive`), binaries to `/opt` or `/usr/local`, Docker installed by the script when the component needs it and absent.
4. **Configure**: generate whole files from templates or drop-ins (see conventions). Written atomically (temp file in the same directory, then `mv`), with explicit owner and mode.
5. **Start**: enable and start the service (`systemd` unit, or `docker compose` managed by a unit).
6. **Verify**: poll the component's health endpoint, up to a documented timeout (default 120 s). Failure → exit 6.
7. **Record**: write the component state, update the defaults (see [state format](spec-state-format.md)).

### Idempotence

Running `install` again must converge, never break:

| Situation | Behaviour |
| --- | --- |
| Same version, same parameters | No change, exit 0, log `already installed` |
| Same version, different parameters | Re-render configuration, restart only if the rendered files changed, update state |
| Different `--version` | Upgrade in place; user data (models, databases) kept |
| Previous run failed halfway | Resume: every step checks before acting |

A configuration file is rewritten only if its rendered content differs from what is on disk, so a restart is never triggered needlessly.

### `uninstall`

Stops and disables the service, removes the files recorded in the state (`files` list), removes the component state, and removes it from the defaults. Data directories (models, databases) are kept unless `--purge`. Uninstalling a component another one depends on (`requires` in the state) fails with exit 4 unless `--force`.

## Paths and testability

| Variable | Default | Role |
| --- | --- | --- |
| `EASY_CS_AI_ROOT` | `/` | Prefix applied to every absolute path the script writes (`/etc`, `/var/lib`, `/opt`), so `bats` tests run against a temporary directory without root |
| `EASY_CS_AI_STATE_DIR` | `/var/lib/easy-cs-ai` | State |
| `EASY_CS_AI_CONFIG_DIR` | `/etc/easy-cs-ai` | Generated configuration and secrets |
| `EASY_CS_AI_LIB` | directory of the script `/../lib` | Location of `common.sh` |

With `EASY_CS_AI_ROOT` set, the script skips package installation and service control (they are replaced by logging), so unit tests exercise argument parsing, templating, state writing and idempotence. Real installs are covered by the integration tests in fresh containers or VMs (see [tests](../tests/README.md)).

## `lib/common.sh`

Provides at least:

- logging: `log_info`, `log_warn`, `log_error`, `log_debug`, and `die <exit-code> <message>`;
- `require_root`, `require_platform`, `require_component <name>`;
- `parse_common_options`, `set_option_default`, `read_secret`;
- `with_lock`;
- `render_template <template> <destination> <mode> <owner>` (envsubst, atomic, returns 0 when changed and 10 when identical);
- `apt_install`, `ensure_docker`, `systemd_enable_now`, `wait_for_http <url> <timeout>`;
- `state_read <component>`, `state_write <component> <json>`, `state_remove <component>`, `defaults_get <type>`, `defaults_set <type> <name>` (see [state format](spec-state-format.md)).

Every function is covered by `bats` tests; `shellcheck` runs on the library and on every script.

## Definition of done for a script

- Implements the four mandatory actions and the type-specific ones.
- `describe` output is valid against the schema above.
- `shellcheck` clean; `bats` tests for options, secrets handling, idempotence and state in `EASY_CS_AI_ROOT` mode.
- Integration test: `install` twice on a fresh Debian and Ubuntu LTS container or VM, `status` healthy, `uninstall` leaves the system as found (except shared packages).
- Documented in its component finding under [search](../search/README.md) when it differs from the general behaviour.

## Open questions

- Whether `install` should print the generated API key once on a TTY (convenient) in addition to `show-key` (safer for logs).
- Per-component health check timeouts, to be set when each script is written.
- Whether `systemd` is mandatory or a `sysvinit`/container fallback is wanted (assumed mandatory for now).
