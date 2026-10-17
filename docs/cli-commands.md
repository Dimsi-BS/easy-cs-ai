# CLI commands

[← Back to docs](README.md)

Overview of the commands exposed by the `easy-cs-ai` CLI (see [packaging](decision-packaging.md)).
- `status`: lists what is currently installed and running
- `install <component-type> <component-name>`:
  - component-type:
    - engine
    - chat-interface
- `exec <component-type> <component-name> <command> …`: runs the component's own program with the context of the installation, so that it talks to the instance easy-cs-ai installed (e.g. `exec engine ollama ps` runs `OLLAMA_HOST=<address:port of the install> ollama ps`; `exec chat-interface librechat logs -f` runs `docker compose -f <the compose file of the install> logs -f`). The tool's command and arguments are passed untouched; it is the only way to reach the program, see the [CLI spec](spec-cli.md#native-tool-commands)
- `component <component-type> <component-name> <action> …`: mirrors the component's commands (e.g. `component engine ollama list-models`). `component <component-type>` lists the components of a type and `component` alone lists every type. A component type is never a command of the root, which holds only the general commands (`status`, `install`, `add`…), see [the decision](decision-component-command.md)
- `add <model-name> [--engine <engine-name>] [--chat-interface <interface-name>]`: uses llmfit to check if the model can be installed, adds the model to the inference engine, wraps it with HTTPS and API Key if not included in the inference engine and links it to the chat interface. Defaults to the currently installed inference engine and the currently installed chat web interface.
- `generate [--config-only] [parameters…]`: calls the [generator](../vm_script/README.md), interactive, or taking a configuration with `--config <file>` instead of a session. It produces the layer 3 VM post-install script (one per VM when the configuration names several, see [spec: two VMs](spec-two-vm.md)), which downloads the package from a pinned source, embeds a configuration and runs `apply`. With `--config-only`, it writes only the [configuration file](spec-config.md) at the end of the session
- `apply <file|-> [--vm <name>] [--prune]`: interprets a [configuration file](spec-config.md) (components, options, models) and makes the machine match it: installs what is listed in dependency order, then adds the models. Converges and is safe to re-run. Nothing is removed unless `--prune` is given

- `uninstall <component-type> <component-name>`: uninstalls a component. `uninstall --all` or `uninstall <component-type> --all` uninstalls everything that is installed (of a type, or all), which wipes a test environment in one command
- `remove <model-name> [--engine <engine-name>]`: the reverse of `add`, unlinks the model from the chat interface and the proxy, then removes it from the inference engine. `remove --all` removes every model (of the given engine, or of all)
- `install --defaults` or `install <component-type> --defaults`: installs the default choices (rank 1 of each type, see [integration order](decision-integration-order.md)). With the whole stack, it also adds the default model of each engine it installs (see [default model](spec-cli.md#default-model)). The CLI never takes a default choice without this explicit option

- `catalog`, `host`, `config schema`, `config validate <file|->`, `guide`: read-only commands that make the CLI self-describing for programs and AI agents (see [spec: capabilities](spec-capabilities.md) and [renderings](spec-rendering.md)). **`--json` is accepted everywhere data is output** (a command that only returns data prints JSON by default, and takes the flag as a no-op; one with a human rendering prints it without the flag): with it, stdout is exactly one JSON document

The detailed behaviour (dispatch, dependencies, `add` steps and rollback, exit codes) is in [spec: CLI](spec-cli.md).

See also: [package](../package/README.md), the layer these commands belong to.
