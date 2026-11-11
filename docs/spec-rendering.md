# Spec: renderings, for a person and for a program

[← Back to docs](README.md)

**Status:** accepted, implemented except the [appearance](#appearance) (`install_scripts/lib/cli-ai.sh`, `vm_script/lib/questions.sh`; tests in `tests/unit/cli_ai.bats` and `tests/unit/generate.bats`)

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
- **Every document carries `schema_version`** (a number, one per document: `2` for the document of `config validate` and those that extend it, `1` for the others of [spec: capabilities](spec-capabilities.md)), like `describe` and `status`. A reader refuses a higher version rather than guessing.
- **Exit codes are unchanged** ([spec: CLI](spec-cli.md#exit-codes)) and remain the primary success signal. `--json` never turns a failure into exit 0.
- **A result is printed even when it is negative.** For the commands that validate or plan, the document is printed with exit 2 when the input is invalid (the list of problems *is* the result). For anything else that fails (usage error, missing root, network…), stdout stays empty and stderr says why; the changing commands print a [result document](spec-capabilities.md#result-of-the-changing-commands).
- **Secrets are never in a document.** A secret option appears as its source (`{"env": "NAME"}`…), `"generate"` or `"masked"`, never as a value ([contract](spec-script-contract.md#secrets)).
- **Read-only commands need no root and no installed state**: they run on the administrator's machine as well as on the target.
- **Where `--json` goes.** Before the command (`easy-cs-ai --json status`) for every command; after it for `status`, `add`, `remove`, `apply`, `catalog`, `host`, `config` and `guide` (the CLI takes it, as it takes `--dry-run` and `--verbose` there), for `install` and `uninstall` (the CLI takes `--json`; `--dry-run` stays with the components) and for `script` (which takes it itself; `config new` and `config edit` are the sessions, which are interactive, so `--json` there is exit 2). A component command (`component engine ollama list-models`) is forwarded as it is, and prints the JSON of the script, but the listings `component` and `component <type>` are a human rendering only and refuse `--json` (exit 2, pointing to `catalog` and `status`). `exec` refuses `--json`: its output is the tool's.
- **`--dry-run`** prints the plan as the document, see [spec: capabilities](spec-capabilities.md#result-of-the-changing-commands).

## For a person: the interactive session

- The session is the **only interactive program** of the project. Prompts and the summary go to stderr, answers are read from stdin; the result goes to a file, never to stdout.
- Every question shows its **default** (the script's own, from `describe`), what it **means** (the `description`), and is **validated** before moving on. Invalid input asks again, it never aborts.
- Nothing is chosen silently ([journey rule 3](spec-journey.md#rules)).
- End of input on stdin cancels the session: exit 0, nothing written.
- The summary lets the person confirm, go back to a step, or cancel. When the session **edits** a configuration (`config edit <file>`), its summary is the whole file and offers the commands of [the editor](spec-multi-vm.md#editing); saving writes the file only (no script), cancel and the end of input leave it untouched.

### A question is a field

The link between the two renderings is the configuration. **Each question fills one field; each field has a question.** The session builds the configuration answer by answer, a program writes it in one go, and both go through the same validation ([`config validate`](spec-capabilities.md#config-validate)). So that a person can always replay a session, `config edit` writes the file a session would have produced, `config edit <file>` opens it again, and `script <file>` turns a file into scripts with no prompt. The question of another VM adds an entry to `vms` and the question of where each model is shown fills `links`; the **role** of a VM is the one answer with no field, an early opinion that only restricts the types a pass asks.

An answer that has no place in the configuration (the specs of the target VM at the models step) is an **early opinion**: it feeds a capability (`suggest`, `plan`) and is not stored.

### Appearance

**Status: partly implemented.** Done: the style layer (`style`, `sym`, `rule`, `wrap`, `ui_unicode` in `install_scripts/lib/common.sh`), the summary of the editor, its commands line and the dimmed default of every question (tests `common_logging.bats` and `config_edit.bats`). **Not done**: the progress lines of the long commands, the alignment of numbered choices, the `hint:` line of the errors, and the tables of `status`, `config validate` and `script`. What a person reads on a terminal is made clearer with colour, a few symbols and aligned columns, **without a full-screen interface** (no TUI, no cursor addressing: the text scrolls and can be copied, piped and logged). The appearance is a layer over the text above: **the information, the codes, the commands and the order of the lines do not change**, and `--json` is untouched.

- **One style layer.** A single function of `lib/common.sh` gives every program the same few roles: `title`, `accent` (the names a person types or reads: types, commands, keys), `ok`, `warn`, `error` and `dim` (paths, codes, defaults, explanations). Nothing else prints an escape sequence, so a role is changed in one place.
- **Only for a person at a terminal.** Colour and symbols are written to **stderr** only when it is a terminal. They are off with `NO_COLOR` set (any value), `TERM=dumb`, a redirected stream, `--json`, and the two overrides that already exist, `EASY_CS_AI_COLOR=always|never` for the colour and `EASY_CS_AI_CHARSET=unicode|ascii` for the symbols (which otherwise follow a UTF-8 locale, like the tree of the help). stdout, which a program may read, never carries a style.
- **A plain fallback, the same text.** Without style the output is the text of today, with ASCII symbols (`tree_unicode` already does this for the tree of commands): `✓` is `ok`, `!` is `[WARN]`, `✗` is `[ERROR]`, a rule of `━` is `==`, a rule of `─` is `--`. The bats tests run in this mode, so they keep comparing plain text; one test per role checks the style in a pseudo-terminal, and that `NO_COLOR` and `--json` remove it.
- **No meaning in colour alone.** Every colour comes with a word or a symbol (`✓`, `!`, `✗`, `[WARN]`), so a colour-blind person, a log and a screen reader lose nothing.
- **Log levels.** `[INFO]`, `[WARN]` and `[ERROR]` keep their text and become the coloured badges of their role. The hint of an error goes on its own line, `hint:` in `dim`.
- **Width.** Columns are aligned to the widest cell and the text wraps at `$COLUMNS` (80 when it is unknown or not a terminal); a value that does not fit is cut at the end of the cell, never in the middle of a command a person has to copy.
- **The questions.** The default is shown in `dim` between square brackets after the question, `Add a proxy? [Y/n]`; numbered choices are aligned, each with its description in `dim`; a secret is still not echoed.
- **Progress.** A command that takes a while prints one line per step, `[3/7] ✓ nginx`, a step under way ending with `…`; on a terminal the line is rewritten in place, otherwise it is printed once per state, so a log shows every step.

**The summary of the editor** is the screen the appearance is designed around: a title rule per VM, the components in aligned columns (`type`, implementation, options), the models and where they are shown below, the warnings with what to do about them, errors numbered with their path and code, and then the commands, each letter in brackets:

```text
━━ VM 2 of 3 · web ───────────────────────────────────────

  1  proxy           nginx       --server-name=localhost
  2  chat-interface  librechat   defaults

  models  none   ·   platforms  debian, ubuntu

  ! librechat --allow-registration=true
    registration is open: the first account created becomes the administrator
    close it with: easy-cs-ai install chat-interface librechat --allow-registration false

  [a] add   [e] edit   [m] models   [l] links   [n] rename   [r] remove   [f] fix   [y] write   [q] quit   [?] help
```

Each command is named by its word after the letter, so the line reads without `?`. The commands that take a VM (`e`, `m`, `n`, `r`) are still typed with it (`e web`); `?` prints the longer help.

The plain fallback of the same screen, for a log or `NO_COLOR`:

```text
== VM 2 of 3: web ----------------------------------------
  1  proxy           nginx       --server-name=localhost
  2  chat-interface  librechat   defaults
  models: none   platforms: debian, ubuntu
  [WARN] librechat --allow-registration=true: registration is open ...
  [a] add   [e] edit   [m] models   [l] links   [n] rename   [r] remove   [f] fix   [y] write   [q] quit   [?] help
```

## `guide`

`easy-cs-ai guide` is the written form of the [journey](spec-journey.md), the file `install_scripts/guide.txt` printed as it is, for a reader that is a model: the same steps, with the commands to call and the rules of [what a program never does on its own](spec-journey.md#what-a-program-never-does-on-its-own). It is plain text, short (a screen or two), versioned with the CLI, and the only reader-oriented output with no `--json` form.

An agent that has nothing but the binary finds it from `easy-cs-ai --help`, whose usage starts with a line telling an AI agent to run `guide` first, and whose command list groups `guide` with `catalog`, `host` and `config` under a heading of their own. That heading names who the commands are for in practice; it does not make them a separate interface, and a person may run any of them.

## Parity

What a person is shown and what a program reads must not drift. The checks:

- **Same document**: the text of an action and its `--json` come from one document (tested per action).
- **Same result**: a session replayed from scripted answers and the equivalent configuration file give the same configuration, plan and script ([parity test](spec-journey.md#parity)).
- **stdout hygiene**: with `--json`, stdout parses as exactly one document in every case, failures included; without it, no JSON.
