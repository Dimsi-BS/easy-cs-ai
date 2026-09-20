# Snap package commands

[← Back to docs](README.md)

Here is what the commands roughly look like. The architecture of the snap may define the prefix of these commands.

- `status`: lists what is currently installed and running
- `install <component-type> <component-name>`:
  - component-type:
    - engine
    - chat-interface
- `<component-name> …`: mirrors the component's commands
- `add <model-name> [--engine <engine-name>] [--chat-interface <interface-name>]`: uses llmfit to check if the model can be installed, adds the model to the inference engine, wraps it with HTTPS and API Key if not included in the inference engine and links it to the chat interface. Defaults to the currently installed inference engine and the currently installed chat web interface.

See also: [snap_package](../snap_package/README.md), the layer these commands belong to.
