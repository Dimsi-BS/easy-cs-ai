# Plan: implementing the configuration format version 2

[← Back to docs](README.md)

**Status:** proposed, to be validated. A working plan, not a specification: the behaviour is in [spec: config](spec-config.md), [spec: several VMs](spec-multi-vm.md), [spec: machine interface](spec-capabilities.md), [spec: journey](spec-journey.md) and [spec: script contract](spec-script-contract.md). This file says in what order the code and the tests follow them, and is removed (or kept as a record) when the work is merged.

## What changes, and what is already there

The code implements the **format 1** (flat `components` with a `vm` field, root `models`, root `links` as pairs of VMs). The specs now describe the **format 2** (a list of `vms` holding their components, the `models` held by their engine, a root `links` of `model → chat interface` with complete references). There is **no compatibility** with the format 1: a file of version 1 is refused with a message.

| Layer | Files | Lines | Role today |
| --- | --- | --- | --- |
| Validation and `apply` | `install_scripts/lib/cli-apply.sh` | 582 | The `jq` validation of a file, the order, `apply`, the slices |
| Machine interface | `install_scripts/lib/cli-ai.sh` | 592 | `catalog`, `host`, `config schema`, `config validate`, the JSON documents |
| Generator | `vm_script/lib/generator.sh`, `script.sh`, `templates/vm-script.sh.tpl` | 471 + 95 + 67 | `script`: one script per VM, the header, the next steps |
| Session and editor | `vm_script/lib/questions.sh`, `config.sh` | 1391 + 63 | `config edit`: creation and editor |
| Component declarations | `install_scripts/*/*.sh` (`describe`) | | Options, `requires`, `resources` |
| Tests | `tests/unit/*.bats`, `tests/unit/parity/`, `tests/integration/*.sh` | ~5 000 | Unit, parity of session and file, integration on a VM |
| Agent guide | `install_scripts/guide.txt` | 78 | What `easy-cs-ai guide` prints |

## Principles of the work

- **The specs are the reference.** A difference found while coding is first a question to the specs, not a decision in the code.
- **One internal representation.** The validation resolves the file once into a flat, resolved form (components with their VM, models with their engine, links with their references resolved), and the rest (order, `apply`, slices, plan, summaries) reads that form. Only the reader of the file and the writer of the session know the format 2 itself.
- **Tests move with the code.** Each step carries the tests of what it changes: the bats files of the format 1 are rewritten, not deleted, so that the coverage stays.
- **Checked in WSL**, as for the other work: `bats --recursive tests/unit` and `shellcheck`, in `EASY_CS_AI_ROOT` mode. The integration tests on a VM (KVM) are not run here: they are written and left for a run by hand.

## The steps

Each step is a commit (or a few) of the same branch, with its own tests.

**Step 1: component declarations (`describe`).** Additive, nothing reads them yet. `relevant_when`, `required_when` and `sources` in the contract; nginx declares `tls-cert`, `tls-key` (`sources` `file` and `env`), `tls-email`, `tls-accept-terms` and `server-name`; `catalog` carries them. Tests: the `describe` of each component (`nginx.bats`, `librechat.bats` where the options are), `cli_ai.bats` for `catalog`. Size: small. Independent of the others.

**Step 2: the reader and the validation of the format 2.** The core of the work, in `cli-apply.sh`.
- The structure (`vms`, `components` with `component` and `name`, `models` in the engines, `links`), the references, the codes of the [closed list](spec-capabilities.md#config-validate), `schema_version` 2 and the refusal of version 1.
- The resolved form, the slices (a file of one VM, the links of both ends on the VM kept), the order from `requires`, what a model needs, the options (`required_when`, `sources`, `secret_source`).
- Tests: `config_vm.bats` and `config_links.bats` are rewritten for the format 2, `cli_apply.bats` for the validation part.
- Size: large (the jq program). Everything after depends on it.

**Step 3: the documents of the machine interface.** In `cli-ai.sh`: `config validate` (`--json`, `--vm`, `--target`) with the document of version 2 (`plan.vms`, `plan.links`, `vm_ref`, `next_steps`), `config schema` (the format 2, the `enum` of `component`, `if` / `then` / `required` for `required_when`, `sources`), the warnings (`engine_address_unknown`, `models_not_checked`). Tests: `cli_ai.bats`. Size: medium. After step 2.

**Step 4: `apply` and the slices.** Run a file of one VM (or `--vm` with several), components in order, models through `add` with the implementation of the component (not the free `name`), a link of both ends on the VM wired by `add`, the journal, `--prune`. Tests: `cli_apply.bats`, `cli_models.bats` where the file is read. Size: medium. After step 2.

**Step 5: the generator `script`.** One script per VM embedding its slice (format 2), `<output>-<vm>.<ext>` when the VM is named, the header (`VM:` line, same version string as the package), the next steps (step 1 always, the steps of a link, the endpoint named `<vm>-<engine>-<model>`), `script --json`, the stale scripts. Tests: `generator.bats`, `generator_vm.bats`. Size: medium. After steps 2 and 4.

**Step 6: the session (`config edit`, creation).** In `questions.sh` and `config.sh`:
- the role and the name first for every VM (default `vm-<n>`), the `custom` pass with everything pre-selected, `a` / `an`;
- the options asked from `relevant_when` and `required_when`, a required option with no empty answer;
- the models written in their engine, with `name` filled by the model;
- at the end, one question per model for its link (the confirmation with one VM), the `name` written on the components that a link designates;
- the file written in the format 2.
Tests: `config_edit.bats` (creation), `parity.bats` and the answers files of `tests/unit/parity/` (the session and the file written by hand give the same configuration). Size: large. After step 2 (the session validates what it writes); independent of steps 4 and 5 in the files it touches.

**Step 7: the editor.** The summary of the whole configuration, `a` `e` `m` `l` `n` `r` `f` `y` `q` `?`, the cascade of the deletions and of the renames on the links, the fixes of the errors by re-asking (`f`), a file of version 1 refused at opening, the lone VM named when a second one is added. Tests: `config_edit.bats` (editor). Size: large. After step 6.

**Step 8: integration, packaging, documentation.** `tests/integration/multi-vm.sh` and `lifecycle.sh` on the format 2 (written, run by hand), `tests/packaging/packages.sh`, `install_scripts/guide.txt` and the READMEs, and the status of the specs (« decided, not implemented » becomes « implemented »). The vestiges of the format 1 in code and tests are removed, `shellcheck` is clean. Size: medium.

## Order and parallelism

```text
1 ─┐
   ├─► 2 ─┬─► 3
       │   ├─► 4 ─► 5
       │   └─► 6 ─► 7
                         └─► 8
```

After step 2, three lines of work touch **different files** and can be done in parallel by separate agents in separate worktrees: steps 3, 4 then 5 (`cli-ai.sh`, `cli-apply.sh`, `generator.sh`), and steps 6 then 7 (`questions.sh`, `config.sh`). Step 8 closes the work.

## The state of the tests between the steps

The format cannot be read in two versions cheaply, so some tests of the layers above step 2 stay red between the steps that rewrite them (the generator tests call the validation, the session writes what the validation reads). Two ways to keep a branch that can be merged:

- **One branch, one pull request, red in the middle.** Each step runs the tests of **its own layer** (and the layers below); the whole suite is green only at the end of step 8. The history keeps one commit per step. Simple, nothing to throw away.
- **A reader of the format 1 kept until the end.** The validation reads both versions until step 8, so every step is green. It costs a second reader to write and then to delete, which is the largest part of step 2 again.

## Risks

- **The `jq` program of the validation** (`cli-apply.sh`) is the densest code; the references, the cascades and the resolved form all go through it. Step 2 is the one to read twice.
- **The parity tests** (`parity.bats`) compare the session and the file for the same decisions; every question of the session that changes, changes its answers files.
- **No KVM here**: the integration tests on a VM are written, not run, so the risk of a regression there is carried to the run by hand.
- **The specs may still move** on a point found in the code (a rule that cannot be written as it is): the question goes back to the specs first.

## Definition of done

- `bats --recursive tests/unit` and `shellcheck` are clean in WSL, in `EASY_CS_AI_ROOT` mode.
- `config validate`, `config schema`, `script`, `apply` and `config edit` read and write the format 2 only, and refuse the version 1 with its message.
- The parity scenarios (session against file) hold for the format 2.
- `guide.txt`, the READMEs and the status lines of the specs say « implemented ».
- The integration tests are written and the run by hand on a VM is reported.
