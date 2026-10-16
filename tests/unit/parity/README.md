# Parity scenarios

One scenario is two files, played by [`../parity.bats`](../parity.bats):

- `<name>.answers`: what a person types in the session (`easy-cs-ai generate`), one answer per line.
  A line that starts with `#` is a comment and is dropped. A trailing ` # comment` is cut. An empty
  line is an answer (the default), so write it as `  # default` to keep a note on it.
- `<name>.json`: the same decisions written by hand, the way a program would write them from
  `catalog --json` and `config schema`. It is the oracle, so it is **not** produced by the session.

`fake/` runs on a small catalog built in `parity.bats`, `real/` on the shipped scripts
(`install_scripts/`). A scenario may name another scenario's `.json` when it reaches the same
decisions by a detour. See [docs/spec-journey](../../../docs/spec-journey.md#parity).
