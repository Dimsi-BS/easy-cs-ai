# Decision: should a command ever return JSON without `--json`?

[← Back to docs](README.md)

**Status:** accepted and implemented. The code already behaved this way; the [rendering spec](spec-rendering.md), [CLI commands](cli-commands.md) and the text of `easy-cs-ai guide` were rewritten to state it.

## Context

The [rendering spec](spec-rendering.md) states a strict rule: **`--json` is for programs, no `--json` is for humans**. Some commands, in particular those that forward the JSON of a component script (`status`, `list-models`…), already print JSON by default. The question is whether to accept that, or to keep the rule absolute and give each of those commands a human rendering.

## Reflection

What matters for an AI agent is **predictability**, not symmetry. A command that can only return a data structure does not need a flag to unlock it, and a human rendering written only to satisfy the rule would be code nobody maintains and a second output that drifts from the first. The opposite (JSON by default everywhere) is worse: it adds noise for people who run the CLI by hand, and the default can no longer change without breaking scripts.

## Decision

1. **`--json` is accepted by every command that outputs data.** The agent never has to guess whether it is supported. When the output is already JSON, the flag is accepted and has no effect.
2. **A command has one default format, stated in its `--help`.** A purely "data" command may return JSON by default, without a parallel human mode.
3. **stdout carries the data, stderr carries the messages** (progress, warnings, "this step is slow"). With `--json`, stdout is one valid JSON document and nothing else.
4. **Exit codes and the shape of errors are stable.** In JSON mode a failure is an object (`{ "error": … }`) with a non-zero exit code.

Points 3 and 4 are already the case (see [conventions of `--json`](spec-rendering.md#for-a-program---json)). The change is points 1 and 2: accept a JSON default for data-only commands, and make `--json` uniformly accepted.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| Strict rule everywhere (current), with a human rendering for every data command | Code to write and keep in step for output nobody reads. |
| JSON by default for all commands | Noise for humans, and the default becomes frozen. |
| Switch to JSON automatically when stdout is not a TTY | The behaviour differs by environment and is hard to debug. |

## Open questions

- None. The inventory found the code compliant: the component actions and `config schema` print JSON by default and accept `--json`, `guide` is the documented text exception, and `exec` refuses `--json` because its output is the tool's.
