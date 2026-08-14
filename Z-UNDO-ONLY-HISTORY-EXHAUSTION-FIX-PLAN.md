# Z Undo-Only History Exhaustion Fix Plan

## Problem

A quick `z` tap correctly undoes buffer changes until it reaches the oldest undoable change. Further `z` taps can then alternate between undoing and redoing that change instead of remaining undo-only.

The current working tree already separates the quick-tap command as `ri-undo-only` and binds the `?z` tap action to it. This fix must build on those changes; it must not restore the old `ri-smart-undo` tap binding or disturb Extend selection preservation.

A batch reproduction of the failing undo state with two changes produced:

```text
1: "base one"
2: "base"
3: "base one"
4: "base"
```

The required sequence is:

```text
1: "base one"
2: "base"
3: user-error "No further undo information", buffer remains "base"
4: user-error "No further undo information", buffer remains "base"
```

## Root Cause

`undo-only` is implemented through Emacs' ordinary `undo` machinery with `undo-no-redo` enabled. Every undo records a redo entry in `buffer-undo-list` and associates that entry with the remaining original history in `undo-equiv-table`.

At the oldest change, the redo entry maps to `t`, and `pending-undo-list` is also `t`, meaning the current undo run has exhausted its history. If command continuity is lost before the next KKP-dispatched tap, `undo-only` starts a new run from `buffer-undo-list`. Emacs skips list-valued redo equivalents in undo-only mode, but the terminal `t` mapping is not list-valued, so that new run consumes the redo entry and restores the oldest change.

`ri--undo-at-exhausted-redo-p` is intended to prevent this, but its current predicate requires both:

- `last-command` to be `undo`; and
- `pending-undo-list` to be a cons whose equivalence maps to `t`.

The failing state has `pending-undo-list` equal to `t`, and KKP/UI dispatch can leave `last-command` identifying an intervening layer command. The predicate therefore returns nil exactly when the terminal redo entry must be blocked.

The trailing `undo-boundary` in `ri-undo-only` is still required because KKP invokes tap actions while Emacs is reading the next command. Removing that boundary would change consecutive undo/redo recording rather than fix the exhausted-history decision.

## Decision

Repair the existing exhausted-redo guard in `ri-extend.el`; do not add another undo implementation or persistent tap state.

The guard should derive exhaustion from Emacs' undo structures rather than require one exact `last-command` value:

1. reject region undo, as the existing guard already does;
2. accept the direct exhausted state where `pending-undo-list` is `t`;
3. retain support for the existing state where a cons-valued `pending-undo-list` maps to `t`;
4. skip leading boundaries in `buffer-undo-list` and require its first real undo cell to have an `undo-equiv-table` mapping, proving that the head is a redo record rather than a new user edit.

When that predicate is true, normalize the immediate built-in call to the exhausted consecutive-undo state (`last-command` is `undo` and `pending-undo-list` is `t`) and then call `undo-only` once. Emacs will issue its standard `No further undo information` user error without replaying the redo entry.

This keeps the important distinction:

- a non-editing command after history exhaustion must not make the oldest change redoable through `z`;
- a real buffer edit places an unmapped edit at the undo-list head, so the next `z` tap may start a new undo run and undo that edit.

Do not catch or suppress the standard user error. The command should behave like `undo-only` at the end of history, not silently invent a no-op contract.

## Implementation

### 1. Correct exhausted-redo detection

Update `ri-extend.el`:

- revise `ri--undo-at-exhausted-redo-p` to recognize both `pending-undo-list == t` and the existing cons-to-`t` equivalence state;
- remove its dependence on `last-command` as proof of exhaustion;
- continue excluding `undo-in-region`;
- reuse `ri--first-undo-cell` rather than maintaining a second loop that skips undo boundaries;
- require an equivalence mapping on the current undo-list head so a new user edit is never mistaken for an exhausted redo;
- update the docstring to describe the actual undo-state invariant.

Keep `ri-undo-only` as the single buffer-only entry point:

- if the guard matches, normalize only the state needed by the immediate built-in undo call;
- call `undo-only` exactly once;
- retain the trailing `undo-boundary` on successful undo;
- retain the existing temporary marker and `unwind-protect` used to keep point on the active Extend edge;
- do not change `ri-smart-undo`, fine undo/redo, or held-layer bindings.

No change is required in `kkp-chord--dispatch-command`: the bug is RI's interpretation of a valid Emacs exhausted-history state, not tap decoding.

### 2. Add one focused regression

Update `ri-extend-test.el` with one deterministic test for the buffer-only command:

1. create an undo-enabled temporary buffer with one baseline string and one undoable edit;
2. invoke `ri-undo-only` through the same small command-dispatch pattern already used by the fine undo/redo test;
3. assert that the edit is removed;
4. model the non-editing layer command that can interrupt command identity without changing `buffer-undo-list`;
5. invoke `ri-undo-only` again and assert the standard `user-error`;
6. assert that the buffer still contains the baseline string;
7. repeat the exhausted invocation once and assert that the text still does not alternate back;
8. add a fresh buffer edit and assert that `ri-undo-only` can undo it, proving the guard does not freeze future history.

The test must fail against the current implementation by observing the oldest change reappear. Avoid assertions over complete undo-list shapes; those are Emacs internals. Assert the observable text, the standard end-of-history error, and recovery after a real edit.

The existing working-tree chord tests already assert that quick `z` dispatches `ri-undo-only` and that Extend state survives a tap. Do not duplicate those assertions in another broad chord fixture. If their setup changes during implementation, add only the minimum repeated-tap assertion needed to preserve the end-to-end binding.

## Documentation

No README change is required. The documented user contract remains `z` = Undo and held `z` = Undo/Redo layer. The fix makes the existing `undo-only` contract true at the oldest history boundary.

Keep `Z-TAP-UNDO-ONLY-FIX-PLAN.md` unchanged. It documents the separate active-Extend tap problem and the uncommitted work on which this fix depends.

## Verification

Run the focused undo regression first:

```sh
emacs -Q --batch \
  -L . -L semantic-regions \
  -l ri-extend-test.el \
  --eval '(ert-run-tests-batch-and-exit "ri-extend-test-z-undo-only-history-exhaustion")'
```

Then run the complete affected Extend suite and the existing `z` chord regressions with the external `kkp.el` directory available:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs -Q --batch \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L ri-tabs \
  -L ri-pick -L ri-mouse -L ri-pairs -L ri-surround -L kkp-chord \
  -l ri-extend-test.el -l ri-chord-test.el \
  --eval '(ert-run-tests-batch-and-exit "ri-\\(extend-test-\\|chord-test-z-\\)")'
```

Finally verify the real TTY path:

1. make two separate edits in NORM;
2. tap `z` twice and confirm both edits disappear in newest-to-oldest order;
3. tap `z` at least twice more and confirm the oldest edit never reappears;
4. make one new edit and tap `z`, confirming the new edit is undone;
5. hold `z` and press `l`, confirming explicit redo still works;
6. repeat the exhausted taps while Extend is active and confirm the exact selection bounds, active edge, and point remain unchanged.

## Non-Goals

- Do not replace Emacs' undo engine or copy `undo`/`undo-only` implementation code.
- Do not add buffer-local tap counters, custom history stacks, advice, timers, or a new dependency.
- Do not make end-of-history undo silently succeed.
- Do not change explicit redo through held `z l` or `Z`.
- Do not change fine undo/redo grouping.
- Do not change KKP parsing, transient-map lifetime, layer legends, or key bindings.
- Do not weaken the Extend invariants: exact selection bounds and the active-edge point position must survive the exhausted tap.

## Completion Criteria

1. Repeated quick `z` taps never replay an undone change after the oldest undo record is exhausted.
2. End-of-history taps report Emacs' standard `No further undo information` error and leave the buffer unchanged.
3. A real edit after exhaustion remains undoable by the next `z` tap.
4. Explicit redo and fine undo/redo retain their current behavior.
5. Active Extend selection bounds, active edge, point, and navigation history remain unchanged by an exhausted quick tap.
6. The focused regression, affected ERT suites, and real TTY sequence pass.
