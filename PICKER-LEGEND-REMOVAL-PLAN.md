# Picker Legend Removal Plan

## Problem

Opening `Pick > File` replaces the `Pick` menu with an insert-style picker, but a `File` keymap legend remains at the bottom of the frame. The picker accepts ordinary text directly, so a persistent physical-keyboard diagram is not useful and consumes editor space.

The visible text such as:

```text
Other bindings: backspace — Pick Delet…, ctrl+a — Pick Query…,
ctrl+d — Page Down, ctrl+e — Pick Query…, ctrl+g — Cancel,
ctrl+j — Next, ctrl+k — Previous, ...
```

is not a second help system. It is `keymap-legend` rendering the active picker keymap.

## Root Cause

The original call sequence deliberately kept a legend alive:

1. `ri-pick-menu` in `ri.el` calls `keymap-legend-show` for the `Pick` submenu.
2. At the time of this plan, `ri--open-picker` changed `ri--menu-state` to `picker` and attempted to clear the Pick map with `(set-transient-map nil)`, but did not hide the menu legend on the successful path. The corrected handoff makes the Pick map one-shot because installing a nil transient map does not deactivate a retained map.
3. `ri-pick-start` in `ri-pick/ri-pick.el` calls `keymap-legend-show` again with the picker title and `ri-pick-mode-map`, replacing the `Pick` legend with a `File`, `Buffer`, or symbol-picker legend.
4. Picker cleanup calls `keymap-legend-hide`, so the picker currently owns that replacement legend for its entire lifetime.

`keymap-legend` places only unmodified, Shift, and Alt bindings that correspond to keys in its configured physical layout into the keyboard grid. The picker bindings are mostly Control keys and named function keys such as `backspace`, arrows, `return`, and `escape`; `keymap-legend--normalize-entry` therefore classifies them as overflow. `keymap-legend--render-overflow` prints those entries under `Other bindings`.

The mixed descriptions have two sources:

- explicit `menu-item` labels produce names such as `Page Down`, `Next`, `Previous`, and `Cancel`;
- plain command bindings are described from their symbol names, producing labels such as `Pick Delete Backward`, `Pick Query Beginning`, and `Pick Query End`, which are then truncated to the configured display width.

Printable query input does not populate the grid because `ri-pick-mode-map` remaps `self-insert-command` rather than defining a separate displayed command for every printable key.

## Decision

The `Pick` menu legend ends when a picker command is selected. An active picker owns only its child-frame UI and must not create, retain, resize around, or clean up a keymap legend.

Apply this behavior to Buffer, File, Document Symbol, and Workspace Symbol pickers. They all use `ri--open-picker`, `ri-pick-start`, and `ri-pick-mode-map`.

Do not change `keymap-legend` placement or overflow semantics to hide this symptom. Those semantics are valid for command keymaps; the defect is showing a command-keymap legend for an insert-style picker.

## Implementation

### 1. End the menu legend before opening the picker

Update `ri-pick-menu` and `ri--open-picker` in `ri.el`:

1. install `ri--pick-layer-map` with a nil `KEEP-PRED`, making the submenu one-shot;
2. let the transient map's exit callback close the Pick menu before the selected picker command runs;
3. set `ri--menu-state` to `picker` in `ri--open-picker`;
4. call `keymap-legend-hide` and hide the status frame;
5. invoke the picker opener.

Do not call `(set-transient-map nil)` during the handoff. It installs an empty transient layer and can fall through to a retained Pick map; it is not the exit operation returned by `set-transient-map`.

On opener failure, reset `ri--menu-state` and re-signal the original error. Legend cleanup must already have happened before the opener runs, so success and failure have the same menu-to-picker ownership boundary.

### 2. Remove legend ownership from the picker

Update `ri-pick/ri-pick.el`:

- remove `(require 'keymap-legend)`;
- remove `keymap-legend-show` from `ri-pick-start`;
- remove `keymap-legend-hide` from `ri-pick--cleanup`;
- update the file commentary and `ri-pick-mode-map` documentation so they describe only the picker keymap and child-frame surface.

Keep the picker key bindings unchanged. `C-a`, `C-e`, `C-j`, `C-k`, `C-d`, `C-u`, `C-g`, arrows, deletion, acceptance, cancellation, yanking, and printable query input remain active even though they are no longer rendered in a bottom legend.

### 3. Remove legend-aware picker geometry

Change `ri-pick--bottom-usable-edge` to compute the bottom usable row from the parent frame height minus the live minibuffer height.

Continue reserving top side windows and continue centering and clamping the child frame within the resulting rectangle. Do not reserve rows for any bottom legend or unrelated bottom side window: no picker-owned legend exists after this change.

### 4. Remove the obsolete legend-window API

After removing picker geometry's dependency, confirm that no runtime caller remains for `keymap-legend-window`. Then remove:

- `keymap-legend-window` from `keymap-legend/keymap-legend.el`;
- `keymap-legend-test-public-window-accessor` from `keymap-legend/keymap-legend-test.el`.

This accessor was introduced only to let picker geometry reserve legend rows. Retaining an unused public integration point would preserve obsolete coupling.

### 5. Correct the original picker design document

Update `PICK-LAYER-IMPLEMENTATION-PLAN.md` so it no longer says that:

- the picker keeps `keymap-legend` visible;
- the picker passes `ri-pick-mode-map` to `keymap-legend-show`;
- picker geometry uses `keymap-legend-window`;
- `keymap-legend-window` is part of the required public API.

Record the final boundary instead: menu code closes the menu legend, and the picker displays only its centered child frame.

## Regression Coverage

### `ri-lsp-test.el`

Add integration coverage around the Pick menu handoff:

- the Pick map is one-shot and retains its exit callback;
- the `Pick` legend is hidden before the picker opener is called;
- `ri--open-picker` does not install a nil transient map;
- successful opening leaves picker state active until the close callback clears it;
- opener failure leaves no legend, resets menu state, and preserves the original error.

Keep the existing test proving that `ri-pick-menu` itself still shows the `Pick` submenu legend. The change concerns the handoff from the menu to a picker, not menu rendering.

### `ri-pick/ri-pick-test.el`

Update the UI test helper and focused tests to verify:

1. `ri-pick-start` uses `display-buffer-in-child-frame` without calling `keymap-legend-show`.
2. Cancellation and cleanup close the child-frame window and session without calling `keymap-legend-hide`.
3. Geometry uses the parent area above the minibuffer rather than the top edge of a bottom legend.
4. Printable query input and all existing picker navigation/editing bindings remain unchanged.
5. Cancelling a picker preserves exact Extend bounds, point, submode, and active edge.

The fifth check is mandatory under the repository's Extend invariants: opening and cancelling a picker must not reinterpret the selection or move point away from its active edge.

### `keymap-legend/keymap-legend-test.el`

Remove only the obsolete public-accessor test. Keep the rendering, label-width, overflow, and generic command-description tests unchanged; the renderer is not being repaired.

## Verification

Run the focused ERT suites:

```sh
emacs --batch -Q -L keymap-legend \
  -l keymap-legend/keymap-legend-test.el \
  -f ert-run-tests-batch-and-exit

emacs --batch -Q -L . -L ri-pick -L ri-tabs -L keymap-legend \
  -L mini-modal -L modal-cursor -L semantic-regions \
  -l ri-pick/ri-pick-test.el \
  -f ert-run-tests-batch-and-exit

: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs --batch -Q -L "$KKP_DIR" -L . \
  -l ri-lsp-test.el \
  -f ert-run-tests-batch-and-exit
```

Then exercise the real terminal UI:

1. Enter Normal mode and choose `Pick > File`.
2. Confirm that the `Pick` legend disappears before the `File` picker appears.
3. Confirm that no `File` legend, empty keyboard grid, `Other bindings` list, or reserved blank bottom band remains.
4. Type and edit a query; use next, previous, page, accept, and cancel bindings.
5. Cancel and reopen the picker; confirm that no stale legend remains.
6. Repeat with Buffer, Document Symbol, and Workspace Symbol.
7. Repeat cancellation from an active Extend selection and confirm exact bounds, submode, active edge, and point are preserved.
