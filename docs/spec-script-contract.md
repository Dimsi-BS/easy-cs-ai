# Spec: install script contract

[← Back to docs](README.md)

**Status:** accepted

## Purpose

Every layer 1 script (Ollama, vLLM, nginx, llmfit, LibreChat, AnythingLLM…) obeys the same contract. The layer 2 CLI is then a plain dispatcher, the [configuration](spec-config.md) can name any component and option, and a component can be swapped for another of the same type by changing one parameter (see [integration order](decision-integration-order.md), rule 3).

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
- A script must work **standalone** (without the CLI): the only external code it needs is `lib/common.sh`. No script may source anything else or locate files relative to itself except through `EASY_CS_AI_LIB`. There is no generator at layer 1 (see [decision: VM script generator](decision-vm-generator.md)), so scripts do not have to be concatenable into one file.

## Invocation

```text
<component>.sh <action> [options]
```

Scripts **never prompt**. A missing mandatory parameter is a usage error (exit 2). This is what makes them usable from cloud-init and from the CLI.

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
| `proxy` | `add-upstream <name> <url>`, `remove-upstream <name>`, `add-site <name> <url>`, `remove-site <name>`, `show-key` |
| `chat-interface` | `add-endpoint <name> <url> [--model <model>]`, `remove-endpoint <name>` |
| `provisioning` | `recommend` (JSON on stdout), `check <model>` (JSON on stdout), `size <model>` (JSON on stdout) |

Output of the actions that return something other than the standard `status` / `describe` / `list-models`:

- `proxy add-upstream`, `proxy add-site` and `chat-interface add-endpoint` print `{ "url": "…" }` on stdout: for the proxy, the URL under which the model is now reachable from outside (through HTTPS); for the chat interface, the URL of the declared endpoint, which is the **internal** URL it was given (the chat interface and the engine share the machine, see [decision: LibreChat install](decision-librechat-install.md#4-reaching-the-models-from-the-container)). The proxy URL is what an external client uses, the CLI does not feed it to the chat interface. Idempotent: calling again with the same arguments prints the same URL.
- `proxy add-site` publishes a **web site** for browsers (the chat interface) on its own HTTPS port, with the proxy's certificate and **without the API key**, and prints its public URL; the API keeps requiring the key on every path (see [decision: LibreChat install](decision-librechat-install.md#3-serving-the-web-interface)). `chat-interface add-endpoint` takes the model the endpoint serves in `--model <model>`, which the CLI passes from `add`; without it the chat interface fetches the list of models of the endpoint, which would show every model of the engine under each endpoint.
- `provisioning` has no service: its `status` reports `running` when the command is present and `healthy` when `llmfit recommend --json` answers with valid JSON, and its state has no `service` or `endpoint`. `provisioning check <model>` prints `{ "fits": true|false, "reason": "…" }` and exits 0 in both cases; a failure to evaluate (llmfit error, unknown model name) is exit 1. It is a thin wrapper, see [Wrapping native tools](#wrapping-native-tools): the verdict is read from llmfit's own output with `jq`, the fit computation is never redone by the project.

An engine either serves all its models from **one process** (Ollama), or runs **one instance per model** (vLLM, which serves a single model per process). The `engine` actions are the same in both cases, see [Engines with one instance per model](#engines-with-one-instance-per-model).

These are the "component commands" mirrored by `easy-cs-ai <type> <name> <action> …` (e.g. `easy-cs-ai engine ollama list-models`). `easy-cs-ai add` orchestrates them: `provisioning check` → `engine add-model` → `proxy add-upstream` if needed → `chat-interface add-endpoint`.

## Parameters

- Options use `--kebab-case value`. Every option also has an environment variable `EASY_CS_AI_<COMPONENT>_<OPTION>` in upper snake case (`--port` for Ollama → `EASY_CS_AI_OLLAMA_PORT`).
- Precedence: command line > environment > built-in default.
- Parsing lives in one function of the script (`parse_args`), so options are handled in one place.
- Common options, accepted by every action unless it makes no sense: `--help`, `--version`, `--verbose`, `--dry-run`, `--json`.
- **`--version` has two meanings**: alone, it prints the script version (common flag); followed by a value (`--version 0.35.1`, or `--version=0.35.1`), it selects the component version to install. The component version can also come from `EASY_CS_AI_<COMPONENT>_VERSION`.
- `install` also accepts `--default`: make this component the default of its type (see [state format](spec-state-format.md#defaults)). The CLI forwards it as it is, so a generated standalone script behaves the same.
- `--dry-run` prints what would be done (packages, files, units) on stderr, changes nothing, and exits 0 if the real run would pass preflight.
- Unknown options are a usage error (exit 2), never ignored.

### Wrapping native tools

**What a tool already does, the tool does.** A script never reimplements a feature of the component it installs (pulling a model, listing models, validating a configuration, hardware detection…): it calls the tool's own command and adds only what the conventions of this contract require.

| Action | Native command it wraps | What the wrapper adds |
| --- | --- | --- |
| `engine list-models` (Ollama) | the engine's own API (`GET /api/tags`; `ollama list` is a table for humans) | JSON on stdout, reduced to `name`, `size`, `modified_at` with `jq` |
| `engine add-model` (Ollama) | `ollama pull` | size-aware wait, state, journal |
| `engine remove-model` (Ollama) | `ollama rm` | state, journal |
| `provisioning recommend` | `llmfit recommend --json` | exit codes, no state |
| `provisioning size <model>` | llmfit's own output: `llmfit info <name> --json` for a very large machine and for a tiny one, with and without GPU memory, the name found as for `check` | `name`, `moe`, `context` and, for the `best` and the `default` quantisation, `quant`, `disk_gb`, `cpu_gb`, `gpu_gb`, read with `jq`; for the [VM recommendation of the generator](spec-vm-generator.md#recommended-vm) |
| `provisioning check <model>` | llmfit's own output: `llmfit info <model> --json`, else `llmfit fit --json` filtered on the Ollama tag (see the [findings](../search/llmfit.md#observed-behaviour-llmfit-1116-run-on-a-cpu-only-machine)) | `fits` (false only for the level `Too Tight`) and `reason` (name, level, mode, memory) read with `jq` |
| `proxy` configuration check | `nginx -t` before every reload | exit code 6 on failure |

- When the tool's output is already in the required form, it is passed through untouched. Parsing is limited to `jq` over the tool's JSON.
- The component's own commands are reachable as they are through `easy-cs-ai exec <type> <name> <command>`, see [spec: CLI](spec-cli.md#native-tool-commands). `describe` declares the program (`native.command`) and the variables to export (`native.env`).

### Secrets

- Never on the command line (see conventions). Accepted channels: `--<name>-file <path>` (file mode must be `0600` or stricter, else exit 2), the environment variable, or `-` to read stdin.
- If a secret is needed and none is given, the script **generates** one (`/dev/urandom`, at least 32 random bytes, base64url) and stores it in `/etc/easy-cs-ai/secrets/<component>.<name>` with mode `0600`, owner root. `install` **never prints a secret**, on a TTY or not: the scripts mostly run unattended (cloud-init in a CloudStack VM, where nobody sees a TTY and the output ends up in `/var/log/cloud-init-output.log`).
- Retrieval channels for a generated secret:
  - the dedicated action, over SSH (`proxy show-key`);
  - to be decided with the CloudStack integration, not designed yet: `--credentials-file <path>`, writing the generated secrets to a file (mode `0600`, owner root) at a location chosen by the caller, so an external tool can fetch them without going through the logs.
- When the secret is known in advance (fleet provisioning), the caller passes it through the channels above. Note that on CloudStack the user-data is stored in the CloudStack database, returned by its API and readable from the VM through the metadata service: a secret placed there is not confidential, which the VM post-install layer must document.
- Secrets never appear in logs, `--dry-run` output, `describe`, `status` or the state files.

## Output

- **stderr**: logs, one line each, `[LEVEL] message` with LEVEL in `INFO`, `WARN`, `ERROR`, plus `DEBUG` with `--verbose`.
- **stdout**: reserved for machine-readable output (JSON of `status`, `describe`, `list-models`, `recommend`, `check`, the `url` of `add-upstream`, `add-site` and `add-endpoint`, or a secret printed on explicit request). Nothing else may write to stdout, including the commands the script runs (redirect them to stderr).
- Dates are ISO 8601 UTC.
- **System journal**: besides stderr, every action that changes the system (`install`, `uninstall`, `add-model`, `remove-model`) writes an event to the journal through `logger -t easy-cs-ai`, see [Action journal](#action-journal).

### Action journal

For support and debugging, each changing action logs two lines, one when it starts and one when it ends, e.g.:

```text
easy-cs-ai: ollama install start version=0.5.7 params=port=11434,bind=127.0.0.1
easy-cs-ai: ollama install end exit=0 duration=48s
```

- Content: component, action, version, **non-secret** parameters (same set as `params` in the state), exit code, duration. Never a secret (same rule as for logs).
- Read with `journalctl -t easy-cs-ai`. Retention and rotation are journald's business; nothing is stored in the [state directory](spec-state-format.md), which stays "declared, not observed".
- Written by one function of `lib/common.sh`, `log_event`, called by the common code around each action so scripts do not repeat it. It is skipped in `EASY_CS_AI_ROOT` mode (replaced by stderr logging like service control).
- Read-only actions (`status`, `describe`, `list-models`, `recommend`, `check`, `show-key`) are not journaled.

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
  "health_timeout": 60,
  "native": { "command": "ollama", "env": { "OLLAMA_HOST": "{bind}:{port}" } },
  "options": [
    { "name": "port", "env": "EASY_CS_AI_OLLAMA_PORT", "default": "11434", "secret": false, "description": "…" }
  ],
  "actions": ["install", "uninstall", "status", "describe", "add-model", "remove-model", "list-models"]
}
```

`describe` is the single source for `--help` text, CLI completion, and the parameter list that `apply` and the generator validate against.

- `requires` is a list of component **names or types**. A type (e.g. `"proxy"`) means "any installed component of that type"; for the check it is satisfied by any one, and the CLI uses the rank 1 component of the type when it installs the missing requirement with `--defaults` (see [spec: CLI](spec-cli.md#dependencies)).
- An option may carry an optional `warn` entry, `{ "when": "true", "message": "…" }`: the message to show when the option's effective value equals `when` (the default included). The VM script generator shows it in its summary, and the script logs it as a `WARN` at `install`, so a risk that comes with a default (LibreChat's open registration) is read before the VM exists and again when it is installed. Adding the entry is not a bump of `schema_version`.
- An option may also carry a `type` (`string`, the default when absent, `integer`, `boolean` or `enum`), `values` (the allowed values of an `enum`) and `min` / `max` (the bounds of an `integer`), so that a program can check a value before running the script: `catalog`, `config schema` and `config validate` use them (see [spec: machine interface](spec-ai-interface.md#contract-addition-typed-options-in-describe)). The default stays a string. Adding them is not a bump of `schema_version`.
- `action_options` is optional: the options of an action other than `install`, keyed by action, in the same form as `options` (`provisioning llmfit` declares there the `--target-*` options of `recommend` and `check`). They are not options of the configuration.
- `native` is optional: `command` is the component's own program, run as is by `easy-cs-ai exec <type> <name> <command>` (see [spec: CLI](spec-cli.md#native-tool-commands)); `env` maps variables to export to templates over the recorded `params` (`{bind}`, `{port}`…), so the program reaches the instance the project installed. For a Docker Compose component, `command` is `docker compose -f {compose_file}` (from the state `service`). Omitted when the component has nothing to run natively.

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

Phases, in order. A failure in any phase stops the script with the matching exit code; the state is written only at the end of a fully verified install. What the script creates along the way is recorded in the [pending manifest](spec-state-format.md#pending-manifest) **before** each creation, so a failed install can always be cleaned by `uninstall`, which does not rely on the state alone.

1. **Preflight**: root, supported platform, `systemd` running as init (see [Platform](#platform)), `requires` satisfied (the script **checks** other components, it never installs them), free disk/RAM when it matters (Ollama: 6 GB on `/usr/local` and 2 GB on `/var/tmp`, the archive weighs about 1.4 GB with its GPU libraries), port not taken by another process (unless the component's own unit is the one listening, on a re-run). No side effect.
2. **Acquire**: take the component lock (see [Locking](#locking); busy → exit 4). Download with checksum verification; versions are **pinned** in the script, `--version` overrides.
3. **Install**: system packages through `apt-get` (non-interactive, `DEBIAN_FRONTEND=noninteractive`), binaries to `/opt` or `/usr/local`, Docker installed by the script when the component needs it and absent.
4. **Configure**: generate whole files from templates or drop-ins (see conventions). Written atomically (temp file in the same directory, then `mv`), with explicit owner and mode.
5. **Start**: enable and start the service (a `systemd` unit, which for a Docker-based component runs `docker compose`).
6. **Verify**: poll the component's health endpoint every 2 s, up to the health timeout. Failure → exit 6. See [Health check](#health-check).
7. **Record**: write the component state, including its `default` flag: true for the first component of its type, or when `--default` is given (see [state format](spec-state-format.md#defaults)). This is done through the `state_*` helpers, which take the state lock for the few seconds of the write; under that same lock, `requires` is checked again, so a dependency uninstalled meanwhile is detected (exit 4, state not written).

### Health check

- Each script has a **default health timeout**, declared in `describe` as `health_timeout` (seconds), and overridable with `--health-timeout <seconds>` (env `EASY_CS_AI_<COMPONENT>_HEALTH_TIMEOUT`). `lib/common.sh` provides one `wait_for_http` used by all scripts, so this is the only mechanism.
- **Fail fast**: if the service unit enters `failed` (or the container exits) while polling, stop at once with exit 6, without waiting for the timeout.
- On failure, log the last probe result and the last lines of the service log (`journalctl` / `docker compose logs`) on stderr, never secrets.
- The check proves the component answers; it does **not** include model pulls or loads, which are the business of `add-model` (size-dependent, with its own wait).
- Starting values, estimated from the component findings and **to be confirmed by the integration tests** (measured on a minimal VM, then set with margin, roughly 3× the observed time). Measured so far on an Ubuntu 24.04 VM with 4 vCPU (see [tests](../tests/README.md#integration-tests-on-a-vm)): LibreChat answers 25 to 30 s after the start with the images present, nginx and Ollama within a few seconds; vLLM and the other platforms are not measured:

| Component | Probe | Default timeout |
| --- | --- | --- |
| nginx | request through the proxy: 401 without key, success with key | 30 s |
| llmfit | `llmfit recommend --json` outputs valid JSON (a command, not a service) | 60 s |
| Ollama | `GET /api/version` | 60 s |
| AnythingLLM | `GET /api/ping` | 120 s |
| LibreChat | `GET /health` (`/readyz` to check) | 300 s |
| vLLM | `GET /health`, depends on the model | 600 s |

### Engines with one instance per model

vLLM cannot start without a model, so for such an engine the phases differ:

- `install` runs Preflight, Acquire, Install and Configure only (software, GPU check, a systemd template unit such as `vllm@.service`; what "software" is for vLLM is proposed in [decision: vLLM install](decision-vllm-install.md)). **Start and Verify are skipped**, since nothing can run yet. The state is recorded with an empty `models` list: "installed, no model" is a valid state.
- `add-model <name>` creates one **instance** for the model (its own unit, port and options), starts it, runs the Verify phase with the engine's health timeout (600 s for vLLM, `--health-timeout` overrides), then records the model with its `unit` and `port` in the state. On failure the instance is removed and the state left untouched (exit 6).
- `remove-model` stops and removes the instance. `list-models` reads the instances from the state.
- The port of an instance is allocated by the script from a base port (`--base-port`, vLLM default 8001), first free one upward, and recorded in the state. The allocation runs under the engine's component lock, which already serializes all its `add-model` actions, so the state lock is not held while the instance starts and is verified (up to 600 s). A port taken by another component is caught by the port probe before the start.
- `status` probes every declared instance. The engine is `healthy` when **all** its instances answer, and an engine with no instance is healthy ("ready to receive a model"). The JSON gains a `models` array of `{ "name", "running", "healthy" }`.
- `uninstall` stops and removes every instance; model data is kept unless `--purge`.
- GPU memory is shared between instances. How the share is set (explicit `--gpu-memory-utilization` per model, or computed from the VRAM and the model size given by llmfit) is an open question; until settled, a script may refuse a second model with a clear message (exit 4).

Engines with a single process (Ollama) keep the standard phases and have no `unit` or `port` per model.

### Platform

- **`systemd` is mandatory.** The target is new Debian/Ubuntu VMs built from controlled templates, where it is the default init; the contract relies on it (unit state probes, drop-ins, template units such as `vllm@.service`, fail-fast on a `failed` unit, `journalctl` diagnostics), as do the third-party installers (Ollama, Docker).
- The preflight checks that systemd is the running init (`/run/systemd/system` exists). If not, exit 3 with a message naming the missing prerequisite.
- No `sysvinit` fallback and no "run in a container" mode: the scripts install onto the host (see [packaging](decision-packaging.md)), and a second init path would double the test matrix for no target.
- Service operations stay isolated in a few functions of `lib/common.sh` (`systemd_enable_now` and the like), so a fallback could be added there later without touching the scripts. Revisit only if a distribution without systemd is actually requested.
- Consequence for tests: a plain Docker container has no systemd, so integration tests run on **VMs**, or on system containers that embed systemd (Incus/LXD, or a privileged Docker container with a systemd image). The `bats` unit tests are unaffected, since `EASY_CS_AI_ROOT` mode replaces service control by logging.

### Idempotence

Running `install` again must converge, never break:

| Situation | Behaviour |
| --- | --- |
| Same version, same parameters | No change, exit 0, log `already installed` |
| Same version, different parameters | Re-render configuration, restart only if the rendered files changed, update state |
| Different `--version` | Upgrade in place; user data (models, databases) kept |
| Previous run failed halfway | Resume: every step checks before acting; the pending manifest is kept and completed, not restarted |

A configuration file is rewritten only if its rendered content differs from what is on disk, so a restart is never triggered needlessly.

### `uninstall`

Stops and disables the service, removes the files recorded in the state (`files` list) **and in the pending manifest**, removes the component state and the manifest, and removes it from the defaults. A component with a manifest but no state (failed install) is cleaned the same way and exits 0; "not installed" (exit 4) means neither a state nor a manifest exists. Paths already absent are ignored. Data directories (models, databases) are kept unless `--purge`, which also removes the system user the component created (e.g. `ollama`); without it the user stays, since it owns the kept data. Uninstalling a component another one depends on (`requires` in the state) fails with exit 4 unless `--force`.

## Locking

Two kinds of lock (`flock`), for two different jobs. Mixing them in one lock would hold it for minutes (a vLLM model start, a LibreChat image pull) and make every other script time out.

| Lock | File | Protects | Held for | If busy |
| --- | --- | --- | --- | --- |
| **State lock** | `/var/lib/easy-cs-ai/.lock` | Read-modify-write of state files, `defaults_set` (see [state format](spec-state-format.md#writing-rules)) | A few seconds at most | Waits up to 60 s, then exit 1 |
| **Component lock** | `/var/lib/easy-cs-ai/locks/<type>-<name>.lock` | Every action that changes that component: `install`, `uninstall`, `add-model`, `remove-model`, `add-upstream`, `remove-upstream`, `add-site`, `remove-site`, `add-endpoint`, `remove-endpoint` | The whole action, including downloads and health waits | **Fails at once**, exit 4: `another action is running on <name> (<action>, pid <n>)`. `--lock-timeout <seconds>` (env `EASY_CS_AI_<COMPONENT>_LOCK_TIMEOUT`) waits instead |

Rules:

1. **Order**: component lock first, then state lock, never the reverse. A script holds at most one component lock, so no deadlock is possible.
2. **Never held over slow work**: the state lock is taken only inside the `state_*` / `defaults_*` helpers of `lib/common.sh`, for the duration of one read-modify-write. Scripts never call `with_state_lock` around code that itself calls those helpers.
3. **Not reentrant**: `flock` is not. `with_state_lock` and `with_component_lock` export `EASY_CS_AI_LOCK_HELD` (list of held locks); taking a lock already in the list is a bug and ends with `die 1` and a clear message, instead of a silent hang.
4. **Descriptors**: a child process inherits the open lock descriptor and would keep the lock after the script ends. `with_state_lock` (descriptor 9) and `with_component_lock` (descriptor 8) therefore run their command with both descriptors closed (`8>&- 9>&-`), the lock staying held by the calling shell until the command returns. Scripts must not use descriptors 8 and 9 for anything else.
5. **Readers take no lock**: `status`, `describe` and the read-only actions rely on atomic writes (`mv`). A reader that finds several defaults for one type re-reads once before failing (see [state format](spec-state-format.md#defaults)).
6. **Crash safety**: `flock` is released when the process dies. Lock files are never removed, an unlocked leftover file is harmless; the `pid` shown when busy is informative only (written in the file after the lock is taken).
7. **Orchestration** (CLI `add`, `remove`, `uninstall --all`) holds no lock itself: each script takes its own component lock, and the CLI's own state writes go through the `state_*` helpers (see [spec: CLI](spec-cli.md#steps)).

## Paths and testability

| Variable | Default | Role |
| --- | --- | --- |
| `EASY_CS_AI_ROOT` | `/` | Prefix applied to every absolute path the script writes (`/etc`, `/var/lib`, `/opt`), so `bats` tests run against a temporary directory without root |
| `EASY_CS_AI_STATE_DIR` | `/var/lib/easy-cs-ai` | State |
| `EASY_CS_AI_CONFIG_DIR` | `/etc/easy-cs-ai` | Generated configuration and secrets |
| `EASY_CS_AI_LIB` | directory of the script `/../lib` | Location of `common.sh` |

With `EASY_CS_AI_ROOT` set, the script skips package installation, service control, user creation, downloads and the health check (they are replaced by logging; the platform and root checks are skipped too), so unit tests exercise argument parsing, templating, state writing and idempotence. Real installs are covered by the integration tests in fresh VMs or systemd-enabled system containers (see [tests](../tests/README.md)).

## `lib/common.sh`

Provides at least:

- logging: `log_info`, `log_warn`, `log_error`, `log_debug` (on with `--verbose`, which exports `EASY_CS_AI_VERBOSE` so child scripts inherit it), `log_event <message…>` (journal, see [Action journal](#action-journal); in `EASY_CS_AI_ROOT` mode it writes an `[INFO] (journal, test mode) …` line on stderr instead), and `die <exit-code> <message>`;
- exit code constants `EXIT_OK`, `EXIT_ERROR`, `EXIT_USAGE`, `EXIT_UNSUPPORTED`, `EXIT_PRECONDITION`, `EXIT_NETWORK`, `EXIT_VERIFY` (see [Exit codes](#exit-codes));
- paths: `is_test_root`, `root_path <absolute-path>` (applies `EASY_CS_AI_ROOT`), `state_dir`, `config_dir` (see [Paths and testability](#paths-and-testability)). `EASY_CS_AI_STATE_DIR` and `EASY_CS_AI_CONFIG_DIR` are logical paths, the prefix is applied to them;
- `require_root` (skipped in `EASY_CS_AI_ROOT` mode), `require_platform`, `require_component <name>`;
- options: `parse_common_options <args…>` consumes `--help`, `--version`, `--verbose`, `--dry-run` and `--json`, read back with `wants_help`, `wants_version`, `is_dry_run` and `wants_json` (private variables, not environment settings), and leaves the other arguments in the array `COMMON_REST`; `set_option <component> <option> <value>` (value from the command line), `set_option_default <component> <option> <default>`, `get_option <component> <option>` (precedence: command line, then environment, then default); `reject_unknown_options <args…>` (exit 2);
- secrets: `read_secret <file|->` (file of mode `0600` or stricter, else exit 2, or stdin), `generate_secret` (32 random bytes, base64url);
- `with_state_lock <command…>` (waits 60 s), `with_state_lock_timeout <seconds> <command…>`, `with_component_lock <type> <name> <action> <command…>`; the lock descriptors 8 and 9 are reserved (see [Locking](#locking));
- `render_template <template> <destination> <mode> <owner>` (envsubst over the environment, atomic, returns 0 when changed and 10 when identical; the template is a real path, the destination a logical absolute path to which `EASY_CS_AI_ROOT` is applied, and the owner is not changed in test mode);
- `apt_install` (skips installed packages), `ensure_docker` (Docker and the Compose v2 plugin from Docker's own apt repository, same package names on Debian and Ubuntu, unless they are already there; shared, so never removed by `uninstall`, see [decision: LibreChat install](decision-librechat-install.md#1-docker-installation-ensure_docker)), `docker_ready`, `systemd_enable_now`, `systemd_restart`, `systemd_disable_now`;
- `pending_begin <type> <name>` (selects the component the `track_*` functions record for, creates the manifest or reuses it), `pending_read <name>`, `pending_remove <name>`;
- `wait_for_http <url> <timeout> [<unit> [<interval>]]`: polls every `interval` seconds (default 2), returns 0, or 6 on timeout or as soon as `unit` is failed (`""` to skip that check), and never dies itself (see [Health check](#health-check));
- `track_file <path>`, `track_unit <unit>`, `track_data_dir <path>`: record in the pending manifest **before** creating the file, enabling the unit or creating the data directory (see [state format](spec-state-format.md#pending-manifest)); `render_template` and `systemd_enable_now` call them themselves, so scripts rarely do;
- `state_read <component>`, `state_write <component> <json>`, `state_remove <component>`, `state_list [<type>]`, `defaults_get <type>`, `defaults_set <type> <name>` (see [state format](spec-state-format.md#helpers)). They need `jq` (exit 4 without it).

Every function is covered by `bats` tests; `shellcheck` runs on the library and on every script.

## Definition of done for a script

- Implements the four mandatory actions and the type-specific ones.
- `describe` output is valid against the schema above.
- `shellcheck` clean; `bats` tests for options, secrets handling, idempotence and state in `EASY_CS_AI_ROOT` mode.
- Integration test: `install` twice on a fresh Debian and Ubuntu LTS VM (or system container with systemd, see [Platform](#platform)), `status` healthy, `uninstall` leaves the system as found (except shared packages). Also: an `install` killed after Configure (simulated failure at each phase), then `uninstall`, leaves the system as found.
- Documented in its component finding under [search](../search/README.md) when it differs from the general behaviour.

## Open questions

- Whether a `--credentials-file` option is wanted to hand generated secrets to an external tool (see [Secrets](#secrets)), to be settled with the CloudStack integration.
- Confirm or adjust the health timeouts (see [Health check](#health-check)) with measurements from the integration tests.
- Persistence of the journal (see [Action journal](#action-journal)): on some images it does not survive a reboot unless `/var/log/journal` exists. To check on the CloudStack templates; if needed, the first install creates that directory, or events also go to a file rotated by `logrotate`.
- GPU memory sharing between vLLM instances (see [Engines with one instance per model](#engines-with-one-instance-per-model)), and the actual behaviour with several instances on one GPU, to be tested.
