# Emacs + Ri Startup Performance Plan

## Goal

Reduce the startup cost added by loading and enabling Ri while preserving the current editing, tab restoration, picker, LSP, mouse, pair, and Extend behavior.

Land a permanent, repository-owned startup benchmark first. Use it before and after every startup-sensitive change so optimization decisions and regressions are based on repeatable measurements rather than one `emacs-init-time` sample.

## Current startup path

The documented setup uses `:demand t`, so `ri.el` is loaded during init and then calls `ri-enable`.

Loading `ri.el` currently requires every bundled feature eagerly. In particular:

```text
ri.el
  -> ri-lsp.el
     -> eglot.el
     -> xref.el
     -> ri-pick.el
        -> project.el
        -> ri-tabs.el
```

This loads Eglot even when the startup buffer has no Eglot server and the user does not invoke an Ri LSP or symbol-picker command. `ri-enable` then enables cursor, tab, modal, KKP chord, pair, mouse, and semantic-region behavior; installs hooks and bindings; and scans the existing buffers.

The tab package already defers persistent marked-file restoration through `emacs-startup-hook` when activation happens before startup completes. That behavior must remain intact. Do not replace synchronous work with arbitrary timers or idle delays merely to improve the reported startup number.

## Preliminary baseline

Measured on 2026-08-14 on an Apple M1 Pro with Emacs 32.0.50 development build `65ca6e153c66`, source files from this checkout, and installed `kkp` on an explicit `-L` path. Each main result is the median of seven interleaved fresh `emacs -Q --batch` processes:

| Scenario | Median wall time |
| --- | ---: |
| Emacs control | 217.5 ms |
| Load `ri.el` | 513.5 ms |
| Load and call `ri-enable` | 559.2 ms |
| Ri load increment over control | 296.0 ms |
| `ri-enable` increment over Ri load | 45.7 ms |

Five-process dependency probes showed these approximate totals:

| Probe | Median total | Increment over the control median |
| --- | ---: | ---: |
| `eglot` | 429.4 ms | 211.9 ms |
| `treesit` | 237.3 ms | 19.8 ms |
| `multisession` | 250.7 ms | 33.2 ms |
| `kkp` | 259.9 ms | 42.4 ms |
| `ri-lsp.el` dependency chain | 458.4 ms | 240.9 ms |

These are diagnostic measurements, not portable budgets. The strongest initial finding is that eager Eglot loading dominates Ri's package-load increment. Re-run the repository benchmark after it is added; do not use these numbers as a CI threshold because Emacs builds, filesystems, CPUs, and background load differ.

## Decision

Optimize in measured steps:

1. add one small Emacs Lisp benchmark that launches fresh child Emacs processes;
2. remove the proven eager Eglot/LSP cost while preserving first-use behavior;
3. measure again;
4. profile `ri-enable` and defer or remove more work only when the new results identify a material hotspot.

Do not build a generic benchmark framework, add a dependency such as Hyperfine, or create a custom startup scheduler. Emacs Lisp, `call-process`, and `float-time` are sufficient.

## Permanent benchmark

### File and command

Add `ri-startup-benchmark.el` at the repository root, beside the existing root-level tests.

Canonical command:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs -Q --batch -L "$KKP_DIR" -L . \
  -l ri-startup-benchmark.el \
  --eval '(ri-startup-benchmark-run)'
```

The benchmark must derive the repository root from `load-file-name`, use the current Emacs executable, and pass `KKP_DIR` to every child. It must fail clearly when the directory does not contain `kkp.el`.

### Scenarios

Each sample must use a fresh `emacs -Q --batch` child process and one isolated temporary `user-emacs-directory`:

1. **control** — start Emacs and exit without loading Ri;
2. **load** — add the same load paths and load `ri.el` without calling `ri-enable`;
3. **enable** — load `ri.el`, call `ri-enable`, and exit after all synchronous activation work completes.

Use the same empty persistent-tab state for all measured enable samples. This prevents the user's real multisession state, marked files, package setup, or init file from changing the result. Restoration of a populated marked set is a separate behavior and must not be mixed into the core startup benchmark.

Set `gc-cons-threshold` to `most-positive-fixnum` in every child and run one explicit `garbage-collect` before the completion sentinel. This keeps garbage-collection placement from moving unpredictably across the load/enable boundary while still charging each scenario for reclaiming what it allocated.

### Sampling and output

Use one discarded warm-up round followed by nine measured interleaved rounds. Report, in milliseconds:

- control median and median absolute deviation;
- load total median;
- enable total median;
- load increment: `load median - control median`;
- enable increment: `enable median - load median`;
- relative percentages against the control and previous phase.

Exit nonzero if a child fails or does not print its completion sentinel. Do not fail on an absolute millisecond budget initially. Timing gates tied to one machine become flaky and get ignored.

The output must include the Emacs version, system type/configuration, repetition count, and repository revision when available. Keep the final metrics on stable, machine-readable `key=value` lines so two runs can be diffed without parsing prose.

### Regression workflow

For a startup-sensitive change, run the canonical command immediately before editing and again after editing with:

- the same Emacs binary;
- the same checkout and `KKP_DIR` except for the intended change;
- the same repetition count;
- no concurrent compilation or test suite.

Compare medians, not individual samples. Treat a slowdown as actionable when it exceeds both 5 ms and 10% in either the load or enable increment. Rerun once to reject transient system noise. If the slowdown repeats, fix it or document the measured correctness tradeoff in the change.

Only add a hard CI budget after a dedicated runner has accumulated enough history to choose a threshold from its variance. Until then, the before/after protocol is the stable regression check.

## Phase 1 — Land the benchmark unchanged against current behavior

1. Add `ri-startup-benchmark.el` with the three scenarios and stable output contract.
2. Run it twice without code changes and confirm the medians are reasonably repeatable.
3. Record the environment and both outputs in the implementation change or pull request.
4. Keep the benchmark independent from ERT. ERT is suitable for behavior, not fresh-process wall-clock sampling.

Acceptance:

- the canonical command runs from the repository root;
- no user init, package activation, or real Ri tab state is read;
- every measured sample is a new Emacs process;
- two unchanged runs remain below the regression rule after one allowed rerun.

## Phase 2 — Remove eager Eglot loading

Remove the unconditional `(require 'ri-lsp)` from `ri.el`.

Load `ri-lsp` at the shared first-use boundaries instead:

- before dispatching the eight `ri-find-*` commands through `ri--run-space-lsp-command`;
- before opening the document-symbol or workspace-symbol picker.

Keep command bindings as symbols. Emacs keymaps do not require their target functions to be loaded when the map is built. One shared `require` per boundary is enough; do not add an autoload declaration for every private `ri-lsp--...` function or create a loader abstraction.

Update `ri-lsp-test.el` to require `ri-lsp` explicitly because that suite tests the module itself. Add a focused fresh-load assertion, in the smallest existing suitable startup test or in `ri-startup-benchmark.el`'s load child, proving:

- loading `ri` does not load the `eglot` or `ri-lsp` features;
- the first ordinary LSP command loads `ri-lsp` before resolving its private operation;
- the first document/workspace symbol picker loads `ri-lsp` before resolving its provider;
- all existing LSP errors, Space-menu cleanup, picker cleanup, and Extend invariants remain unchanged.

Run the benchmark before and after this phase. The load increment should fall materially; on the preliminary machine, removing the eager Eglot chain is expected to be the largest single improvement. Do not set an exact promised millisecond saving until the permanent harness measures it.

## Phase 3 — Re-profile the remaining load path

After Phase 2, profile one fresh `require 'ri` and inspect the loaded features. Rank remaining costs before changing more requires.

Candidates include:

- `ri-pick` / `project`;
- `ri-transform`, `ri-surround`, `ri-duplicate`, and `ri-edit` command modules;
- `keymap-legend` and `status-frame` menu UI;
- `ri-tabs` / `multisession`;
- `semantic-regions` / `treesit`;
- `kkp` and `kkp-chord`.

Keep startup-essential modules eager when `ri-enable` calls them immediately: modal state, KKP handling, cursor handling, semantic-region activation, pairs, mouse setup, and tabs unless profiling proves their work can move without changing visible startup behavior.

For each additional lazy-load candidate:

1. prove it is not needed by `ri-enable` or top-level map construction;
2. add the `require` at its existing public command boundary;
3. preserve the first invocation exactly;
4. run its focused tests;
5. benchmark before considering the next candidate.

Stop when the next candidate does not produce a repeatable improvement above the regression noise rule. Do not turn every module into an autoload project for marginal gains.

## Phase 4 — Profile `ri-enable`

Measure the enable increment separately after package-load optimization. Instrument only the existing top-level operations:

```text
modal-cursor-mode
ri-tabs-mode
mini-modal-setup
kkp-chord-mode / global-kkp-mode
ri-chord-setup
existing-buffer semantic-region/pair/mode-line setup
```

Optimize the measured winner, not all of them.

Specific checks:

- confirm tab surface installation and empty-state refresh are not duplicated before `emacs-startup-hook`;
- confirm the existing-buffer scan touches each eligible buffer once and does not enable pairs twice;
- preserve immediate Ri behavior in buffers that already exist when `ri-enable` runs;
- preserve deferred persistent marked-file restoration and its error handling;
- do not move required setup to an idle timer.

If no individual operation exceeds the repeatable 5 ms / 10% rule, stop. A larger refactor would not be justified by the measured startup cost.

## Deterministic tests

Timing results do not replace behavioral coverage. Add only tests for the lazy-load contract introduced by the implementation:

1. a fresh Ri load leaves `ri-lsp` and `eglot` unloaded;
2. first LSP command use loads the module and dispatches the requested operation;
3. first LSP-backed picker use loads the module and opens the requested provider;
4. existing LSP and picker suites continue to protect menu cleanup, unavailable-server behavior, and exact Extend selection state.

Do not assert exact elapsed time in ERT. Do not assert the absence of unrelated transitive features unless their absence is an intentional optimization contract.

## `AGENTS.md` update

When `ri-startup-benchmark.el` lands, add this repository rule to `AGENTS.md`:

```markdown
## Startup performance

- Changes to `ri.el` top-level dependencies, lazy-loading boundaries, or `ri-enable` MUST run the canonical `ri-startup-benchmark.el` command before and after the change with the same Emacs binary and `KKP_DIR`.
- Compare the median `load_increment_ms` and `enable_increment_ms`, not individual runs. A repeated regression greater than both 5 ms and 10% MUST be fixed or explicitly justified.
- Startup benchmarks MUST use `emacs -Q`, fresh child processes, and isolated Ri persistent state; user init time and real marked-tab restoration are not comparable baselines.
```

Do not add the rule before the canonical benchmark file exists; repository instructions must never point to a missing command.

## Verification order

1. Run the permanent startup benchmark twice on the unchanged implementation.
2. Apply one optimization phase.
3. Run the focused behavioral tests for the changed load boundary.
4. Run the permanent benchmark again and compare medians.
5. Run the complete affected ERT suites.
6. Start real terminal Emacs with the documented `:demand t` setup and verify:
   - Ri is active immediately;
   - tabs and persisted marks restore as before;
   - the first Space/LSP command works without a prior manual `require`;
   - document and workspace symbol pickers open on first use;
   - unavailable LSP capability errors preserve exact Extend bounds, active edge, point, and submode.

## Files

Add:

- `ri-startup-benchmark.el` — fresh-process startup measurement and stable output.

Modify:

- `ri.el` — measured lazy-load boundaries and only proven activation-path reductions;
- `ri-lsp-test.el` — explicit module loading and first-use coverage;
- `AGENTS.md` — mandatory before/after startup benchmark protocol.

Modify other module tests only when a later measured optimization changes that module's load boundary. No README change is required: startup benchmarking is a contributor workflow, while the user-facing `:demand t` setup remains unchanged.

## Completion criteria

The work is complete when:

1. the repository owns one reproducible fresh-process startup benchmark;
2. `AGENTS.md` requires its before/after use for startup-sensitive changes;
3. loading Ri no longer eagerly loads Eglot/LSP support;
4. first use of every deferred command remains behaviorally identical;
5. the load increment improves repeatably, with Phase 2 expected to deliver the primary gain;
6. the enable increment has no repeated regression above both 5 ms and 10%;
7. tab restoration, terminal startup, LSP/picker behavior, and all Extend invariants pass their focused checks.

## Implementation result

Completed on 2026-08-14 with Emacs 32.0.50:

- added `ri-startup-benchmark.el` and the mandatory `AGENTS.md` workflow;
- added `ri-startup-test.el` and made `ri-lsp-test.el` load the module it tests explicitly;
- deferred `ri-lsp` and Eglot until the first LSP command or LSP-backed picker;
- reduced `load_increment_ms` from 269.7–270.9 ms to 116.9 ms in the final benchmark, a 57% reduction;
- reduced `enable_increment_ms` from the unchanged 51.0–54.9 ms baseline range to 47.7 ms;
- retained eager `ri-pick` after a measured lazy-loading experiment produced no repeatable process-level improvement;
- retained synchronous `global-kkp-mode` activation: profiling attributed 52–59 ms to this required terminal setup, and moving it after startup would only hide rather than remove the cost.
