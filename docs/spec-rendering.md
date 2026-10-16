# Spec: renderings, for a person and for a program

[← Back to docs](README.md)

**Status:** accepted, implemented (`install_scripts/lib/cli-ai.sh`, `vm_script/lib/questions.sh`; tests in `tests/unit/cli_ai.bats` and `tests/unit/generate.bats`)

## Purpose

A [capability](spec-capabilities.md) returns **one document**. The [journey](spec-journey.md) says which capabilities to call and in what order. This spec says how the result reaches the reader: as text and questions for a person, as JSON and arguments for a program.

The two renderings are two views of the same thing, not two products. The rule that governs both:

> **A rendering decides how something is shown or asked, never what is true.** Data, rules, checks and warnings are the capability's; the questions and their order are the journey's.

The decision behind `--json` is in [decision: JSON output](decision-json-output-rule.md).

## One document, two renderings

```text
capability → document ─┬─ person:  text, tables, questions   (default)
                       └─ program: one JSON document, --json
```

- The human text is a **function of the document**, produced by the same code that produces the JSON (`suggest` and `plan` render their text from their document, so the two cannot differ). It is never computed on its own.
- The interactive session is a **caller of the capabilities**: it asks, calls, and shows the text of what the capability returns. It reads from that text only what it needs to let the person pick (the number and name at the start of each line of `suggest`).
- Adding a field to a document adds it to the JSON at once. Showing it to a person is a change of the rendering alone, and a field not shown there is not lost to the program.

## For a program: `--json`

- **`--json` is accepted by every command that outputs data**, and then stdout carries one JSON document and nothing else. A command that only returns a data structure (`config schema`, the component actions `status`, `list-models`, `check`…) prints JSON by default and takes `--json` as a no-op. A command with a human rendering prints it without `--json`, and that rendering is not a stable interface. `guide` is the one text exception, see [below](#guide).
- **stdout**: exactly one JSON document, terminated by a newline. **stderr**: unchanged, the human logs (`[LEVEL] message`), also with `--json`. A program reads stdout, and shows stderr to the user when it wants the story.
- **Every document carries `schema_version`** (a number, `1` for all the documents of [spec: capabilities](spec-capabilities.md)), like `describe` and `status`. A reader refuses a higher version rather than guessing.
- **Exit codes are unchanged** ([spec: CLI](spec-cli.md#exit-codes)) and remain the primary success signal. `--json` never turns a failure into exit 0.
- **A result is printed even when it is negative.** For the commands that validate or plan, the document is printed with exit 2 when the input is invalid (the list of problems *is* the result). For anything else that fails (usage error, missing root, network…), stdout stays empty and stderr says why; the changing commands print a [result document](spec-capabilities.md#result-of-the-changing-commands).
- **Secrets are never in a document.** A secret option appears as its source (`{"env": "NAME"}`…), `"generate"` or `"masked"`, never as a value ([contract](spec-script-contract.md#secrets)).
- **Read-only commands need no root and no installed state**: they run on the administrator's machine as well as on the target.
- **Where `--json` goes.** Before the command (`easy-cs-ai --json status`) for every command; after it for `status`, `add`, `remove`, `apply`, `catalog`, `host`, `config` and `guide` (the CLI takes it, as it takes `--dry-run` and `--verbose` there), for `install` and `uninstall` (the CLI takes `--json`; `--dry-run` stays with the components) and for `generate` (the generator takes it, with `--config`: a session is interactive, so `--json` without `--config` is exit 2). A component command (`engine ollama list-models`) is forwarded as it is, and prints the JSON of the script. `exec` refuses `--json`: its output is the tool's.
- **`--dry-run`** prints the plan as the document, see [spec: capabilities](spec-capabilities.md#result-of-the-changing-commands).

## For a person: the interactive session

- The session is the **only interactive program** of the project. Prompts and the summary go to stderr, answers are read from stdin; the result goes to a file, never to stdout.
- Every question shows its **default** (the script's own, from `describe`), what it **means** (the `description`), and is **validated** before moving on. Invalid input asks again, it never aborts.
- Nothing is chosen silently ([journey rule 3](spec-journey.md#rules)).
- End of input on stdin cancels the session: exit 0, nothing written.
- The summary lets the person confirm, go back to a step, or cancel.

### A question is a field

The link between the two renderings is the configuration. **Each question fills one field; each field has a question.** The session builds the configuration answer by answer, a program writes it in one go, and both go through the same validation ([`config validate`](spec-capabilities.md#config-validate)). So that a person can always replay a session, `generate --config-only` writes the file a session would have produced, and `generate --config <file>` turns a file into a script with no prompt.

An answer that has no place in the configuration (the specs of the target VM at the models step) is an **early opinion**: it feeds a capability (`suggest`, `plan`) and is not stored.

## `guide`

`easy-cs-ai guide` is the written form of the [journey](spec-journey.md) for a reader that is a model: the same steps, with the commands to call and the rules of [what a program never does on its own](spec-journey.md#what-a-program-never-does-on-its-own). It is plain text, short (a screen or two), versioned with the CLI, and the only reader-oriented output with no `--json` form.

An agent that has nothing but the binary finds it from `easy-cs-ai --help`, whose usage starts with a line telling an AI agent to run `guide` first, and whose command list groups `guide` with `catalog`, `host` and `config` under a heading of their own. That heading names who the commands are for in practice; it does not make them a separate interface, and a person may run any of them.

## Parity

What a person is shown and what a program reads must not drift. The checks:

- **Same document**: the text of an action and its `--json` come from one document (tested per action).
- **Same result**: a session replayed from scripted answers and the equivalent configuration file give the same configuration, plan and script ([parity test](spec-journey.md#parity)).
- **stdout hygiene**: with `--json`, stdout parses as exactly one document in every case, failures included; without it, no JSON.
