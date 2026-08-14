# Z Tap Undo-Only Fix Plan

## Problem

A quick tap of `z` is registered as `ri-smart-undo`. That command is context-sensitive: while Extend is active, it calls `ri--extend-undo` and contracts the selection instead of undoing a buffer edit.

A batch reproduction of the current path reported:

```text
tap=ri-smart-undo before=(1 . 3) after=(1 . 2) text="base change" active=t
```

The required contract is narrower: tapping `z` must always perform buffer `undo-only`, including while Extend is active. The held `z` layer keeps its current context-sensitive coarse and fine undo/redo actions.

## Root Cause

`ri-smart-undo` currently combines two distinct operations:

1. restore one Extend navigation record when `ri--selection-active-p` is non-nil;
2. otherwise run `undo-only`, including RI's exhausted-redo protection and the explicit `undo-boundary` required by KKP release-time dispatch.

`ri--layer-specs` reuses that context-sensitive command for the `z` tap. The tap therefore inherits Extend contraction even though its primary action should be buffer undo only.

Binding the tap directly to Emacs' `undo-only` is not sufficient. KKP executes tap actions while reading the next event, outside the ordinary command-loop boundary. RI's existing exhausted-redo guard and trailing `undo-boundary` must remain on this path.

## Decision

Extract the existing buffer-only branch into one named interactive RI command, `ri-undo-only`, and register that command as the `z` tap action.

Keep `ri-smart-undo` as the context-sensitive command used by held `z j`:

- active Extend selection: call `ri--extend-undo`;
- otherwise: delegate to `ri-undo-only`.

When the tap runs during Extend, preserve point with a temporary marker around the buffer undo. That keeps point on the active selection edge and leaves the independent Extend navigation history intact when the undone edit is outside the selection. Outside Extend, retain normal `undo-only` point movement. This preserves one implementation of RI's buffer-undo safeguards without changing KKP or adding persistent tap state.

## Implementation

### 1. Separate buffer undo from Extend undo

Update `ri-extend.el`:

- add interactive `ri-undo-only` containing the current non-Extend body of `ri-smart-undo`;
- keep the `ri--undo-at-exhausted-redo-p` check and `pending-undo-list` adjustment unchanged;
- when Extend is active, save point in a temporary marker, restore it with `unwind-protect`, and release the marker even if undo signals an error;
- do not preserve point outside Extend: ordinary buffer undo must keep its current point-placement behavior;
- call Emacs' `undo-only` exactly once;
- retain the trailing `undo-boundary` needed for consecutive KKP actions;
- reduce `ri-smart-undo` to selection dispatch: `ri--extend-undo` when Extend is active, otherwise `ri-undo-only`;
- update both docstrings to state the two contracts explicitly.

Do not duplicate the exhausted-redo or boundary logic in both commands. Do not exit Extend for a tap-only buffer undo: discarding the selection would make the new tap behavior destructive to independent selection state.

### 2. Register the correct tap command

Update `ri.el`:

- change only the `?z` layer spec's `:tap` from `ri-smart-undo` to `ri-undo-only`;
- keep `ri--undo-redo-layer-map` key `j` bound to `ri-smart-undo`;
- keep `l`, `u`, and `o` bound to the current redo and fine-grained commands;
- point the `z` entry in `ri--normal-help-map` at `ri-undo-only` so the documented command matches the effective quick-tap action;
- retain the existing labels `≡ Undo/Redo`, `Undo`, `Coarse Undo`, and `Fine Undo`.

No KKP chord implementation change is required: `kkp-chord--on-release` already dispatches the command stored in the tap table correctly.

## Regression Coverage

### `ri-chord-test.el`

Update `ri-chord-test-z-layer-dispatches-undo-and-redo` to assert:

- the `?z` tap table entry is `ri-undo-only`;
- held `z j` remains `ri-smart-undo`;
- all other held-layer bindings remain unchanged;
- the existing no-Extend quick-tap path still undoes one buffer change and held redo restores it.

Add one focused active-Extend tap case through the real chord press/release dispatch:

1. create a temporary undo-enabled buffer;
2. record a buffer edit outside the selection to keep marker movement out of the assertion;
3. enter Extend and navigate once so the Extend undo stack is non-empty;
4. capture the exact selection bounds, active edge, point, and Extend undo stack;
5. tap `z` through the registered KKP action;
6. assert that the buffer edit was undone;
7. assert that Extend remains active and the captured bounds, active edge, point, and Extend undo stack are unchanged.

This test must exercise the registered tap action. Calling `ri-undo-only` directly would not prove that `z` uses it.

### `ri-extend-test.el`

Keep `ri-extend-test-line-to-word-after-swap-preserves-extend` unchanged. Its direct `ri-smart-undo` call proves the held coarse-undo command can still restore one Extend navigation record.

Do not add a second test for the same dispatch split unless implementation changes behavior beyond the chord regression above.

## Documentation

`README.md` already states that `z` performs Undo and that holding `z` opens the Undo/Redo layer. Those user-facing keys remain unchanged, so no README edit is required.

The help-map command target must change because it is executable documentation of the effective tap action.

## Verification

Run the focused `z` and Extend regression tests:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs -Q --batch \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L ri-tabs \
  -L ri-pick -L ri-mouse -L ri-pairs -L ri-surround -L kkp-chord \
  -l ri-chord-test.el -l ri-extend-test.el \
  --eval '(ert-run-tests-batch-and-exit "ri-\\(chord-test-z-\\|extend-test-line-to-word-after-swap-preserves-extend\\)")'
```

Then run both complete affected suites:

```sh
emacs -Q --batch \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L ri-tabs \
  -L ri-pick -L ri-mouse -L ri-pairs -L ri-surround -L kkp-chord \
  -l ri-chord-test.el -l ri-extend-test.el \
  -f ert-run-tests-batch-and-exit
```

Finally verify the real TTY interaction:

1. In NORM without Extend, make two edits and tap `z` twice; each tap must undo one buffer change.
2. Redo once with held `z l`; the existing redo behavior must remain intact.
3. Enter Extend, expand the selection, and make sure an earlier undoable edit exists outside it.
4. Tap `z`; the buffer edit must undo while the exact selection bounds, active edge, and point remain unchanged.
5. Hold `z` and press `j`; the selection must contract by one recorded Extend navigation step, with point remaining on the active selection edge.
6. Hold `z` and press `u`; the existing fine-undo behavior must remain unchanged.

## Non-Goals

- Do not change `kkp-chord`, event decoding, transient-map lifetime, or legend rendering.
- Do not change held `z j`, `z l`, `z u`, or `z o` semantics.
- Do not change Extend history representation or selection-bound calculations.
- Do not bind the tap directly to built-in `undo-only` and lose RI's KKP boundary handling.
- Do not add an alias, compatibility shim, configuration option, or generic undo dispatcher.

## Completion Criteria

1. A quick `z` tap always invokes RI's buffer-only undo path.
2. Active Extend bounds, active edge, point, and navigation history survive that tap unchanged when the undone edit is outside the selection.
3. Held `z j` still restores Extend navigation history.
4. Consecutive undo/redo actions retain the current exhausted-redo and KKP boundary behavior.
5. The focused and complete affected ERT suites pass, followed by the real TTY interaction check.
