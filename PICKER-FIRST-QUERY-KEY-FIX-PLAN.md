# Picker First-Query-Key Fix Plan

## Problem

After opening `Pick > File` (`SPC k d`), the first query character is not inserted when it is also a Pick submenu key. In particular, `s`, `d`, `f`, and `S` still dispatch the submenu actions for Document Symbol, File, Buffer, and Workspace Symbol instead of reaching `ri-pick-mode-map`.

Typing an unrelated character such as `r` first makes the affected characters work normally afterward. This makes the picker appear to reject only a few initial letters and can also invoke another picker command unexpectedly.

The defect is in the menu-to-picker transient-keymap handoff in `ri.el`, not in fuzzy filtering or `ri-pick-self-insert`.

## Root Cause

The current command sequence is:

1. `ri-space-menu` installs `ri--space-layer-map` with `set-transient-map` and a non-nil `KEEP-PRED`.
2. `ri-pick-menu` installs `ri--pick-layer-map` the same way.
3. Pressing `d` resolves to `ri-pick-file` through `ri--pick-layer-map`.
4. Because the Pick map uses `KEEP-PRED` equal to `t`, Emacs retains that map after a command bound in the map is selected.
5. `ri--open-picker` calls `(set-transient-map nil)` before opening the picker.

Step 5 does not deactivate the existing Pick transient map. `set-transient-map` returns an exit function for that purpose; calling it again with a nil map installs an empty transient layer whose lookup can fall through to the retained Pick map. The retained map has higher precedence than the newly selected picker's local map, so its `s`, `d`, `f`, and `S` bindings win over the picker's remapped `self-insert-command`.

An unbound character such as `r` is not handled by `ri--pick-layer-map`. That command-loop transition deactivates the stale map, allows `r` to reach the picker, and leaves subsequent `s`, `d`, `f`, and `S` events free to reach `ri-pick-mode-map`. This exactly accounts for the reported ordering-dependent behavior.

## Decision

Treat the Pick submenu as a one-shot transient map.

Pass nil as `KEEP-PRED` when `ri-pick-menu` calls `set-transient-map`. Emacs will still use `ri--pick-layer-map` to resolve the selected picker key, but it will deactivate the map before running the selected command. The existing on-exit callback can then close the `Pick` legend, and the picker command can establish `ri--menu-state` as `picker` without leaving a higher-precedence menu map behind.

Remove `(set-transient-map nil)` from `ri--open-picker`. It is neither necessary after the one-shot transition nor a valid way to deactivate the preceding map. Keep explicit legend and status-frame cleanup in `ri--open-picker`; it is idempotent after the normal command-loop handoff and keeps direct/error paths safe.

This is preferable to adding a picker-specific exit-function registry:

- the submenu accepts exactly one picker selection, so one-shot behavior matches its UI contract;
- `ri-transform-menu` already uses a nil `KEEP-PRED` for a one-command menu, so this reuses an existing repository pattern;
- no new mutable lifecycle state or nested-map cleanup abstraction is required;
- the fix removes the stale map before the picker starts instead of special-casing printable characters in the picker map.

## Implementation

### 1. Make the Pick submenu one-shot

Update `ri-pick-menu` in `ri.el`:

- change the second argument to `set-transient-map` from `t` to `nil`;
- retain the existing `ri--pick-layer-map` and its `f`, `d`, `s`, `S`, and `Esc` bindings;
- retain the on-exit callback that calls `ri--close-menu` only while `ri--menu-state` is `pick`.

The expected command-loop ordering becomes:

1. the selection key resolves through `ri--pick-layer-map`;
2. Emacs deactivates the one-shot map and runs its on-exit callback;
3. the callback closes the Pick menu UI;
4. `ri-pick-file`, `ri-pick-buffer`, or the selected symbol command opens the picker;
5. the first query event resolves through `ri-pick-mode-map`.

Do not alter the Pick key labels or user-facing key sequences.

### 2. Remove the false transient-map clear

Update `ri--open-picker` in `ri.el`:

- remove `(set-transient-map nil)`;
- set `ri--menu-state` to `picker` before invoking the picker opener;
- keep `keymap-legend-hide` and `ri--hide-frame` before the opener;
- keep the current `condition-case` behavior that resets `ri--menu-state` and re-signals the original opener error;
- keep `ri--picker-closed` as the successful picker cleanup callback.

Do not replace the removed call with direct mutation of `overriding-terminal-local-map`. The command-loop-owned one-shot lifecycle is the supported mechanism and avoids bypassing Emacs' transient-map hooks.

### 3. Keep picker input logic unchanged

No runtime change is required in `ri-pick/ri-pick.el`.

`ri-pick-mode-map` already remaps `self-insert-command` to `ri-pick-self-insert`, has no printable `s`, `d`, `f`, or `S` bindings of its own, and removes the inherited `special-mode-map` parent. Once the stale transient map is gone, those characters follow the normal query insertion path and trigger `ri-pick--query-changed`.

Do not add explicit per-letter bindings, unread-event replay, command-name checks, or input special cases. Those would hide the stale-map symptom and leave other submenu keys able to shadow picker input.

### 4. Correct stale design documentation

Update the transient-handoff descriptions in:

- `PICK-LAYER-IMPLEMENTATION-PLAN.md`;
- `PICKER-LEGEND-REMOVAL-PLAN.md`.

Replace claims that `(set-transient-map nil)` clears the active map. Record that the Pick submenu is one-shot, its map exits before the selected picker command runs, and `ri--open-picker` owns only the remaining menu-surface cleanup and picker-state transition.

`README.md` already promises ordinary fuzzy query input and needs no behavioral wording change.

## Regression Coverage

### `ri-lsp-test.el`

Update `ri-lsp-test-pick-menu-opens-legend-and-transient-map` to require:

- `ri--pick-layer-map` is installed;
- `KEEP-PRED` is nil;
- the on-exit callback remains present.

Update the existing `ri--open-picker` handoff tests:

- remove the expectation that `ri--open-picker` calls `set-transient-map` with nil;
- continue asserting that legend and status-frame cleanup happen before the opener;
- continue asserting that successful opening leaves `ri--menu-state` equal to `picker` until the close callback runs;
- continue asserting that opener failure resets menu state and preserves the original error.

Add a command-loop regression test that uses the real `set-transient-map` implementation rather than mocking it. Stub only picker display/provider work, enter the Pick submenu, select File with `d`, then send printable query input through an `ri-pick-mode` buffer. Assert that:

- the File opener runs exactly once;
- the first query characters `s`, `d`, `f`, and `S` are inserted in order;
- none of those characters invokes another Pick submenu command;
- a character that overlaps the parent Space map, such as `x`, is also inserted, proving that no parent menu map remains above the picker;
- the transient map and test buffer are cleaned up even if the assertion fails.

This behavioral test is essential. The existing mocked handoff test accepted `(set-transient-map nil)` and therefore encoded the incorrect assumption without exercising Emacs key precedence.

### `ri-pick/ri-pick-test.el`

Expand `ri-pick-test-printable-keys-remain-query-input` to include `s`, `d`, `f`, and `S`. This is supporting coverage for the picker-local contract; it does not replace the `ri.el` command-loop regression test because the defect exists above the local keymap.

Keep the existing picker cancellation tests unchanged. The fix must not alter source point, Extend bounds, selection submode, or active edge.

## Verification

Run the focused picker tests:

```sh
emacs --batch -Q -L . -L ri-pick -L ri-tabs -L keymap-legend \
  -L mini-modal -L modal-cursor -L semantic-regions \
  -l ri-pick/ri-pick-test.el \
  -f ert-run-tests-batch-and-exit
```

Run the Ri menu integration tests with the external `kkp.el` directory available:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs --batch -Q -L "$KKP_DIR" -L . \
  -l ri-lsp-test.el \
  -f ert-run-tests-batch-and-exit
```

Then exercise the real UI:

1. Open `Pick > File` with `SPC k d`.
2. As the first query event, type each of `s`, `d`, `f`, and `S` in separate runs; confirm that every character appears immediately and no other picker opens.
3. Type `sdfS` continuously from an empty query; confirm that the full string appears without a sacrificial prefix character.
4. Repeat the first-character check for Buffer, Document Symbol, and Workspace Symbol pickers where their providers are available.
5. Type a key shared with the Space menu, such as `x`, as the first query character and confirm that it is inserted rather than dispatched as the Space menu's Definition command.
6. Verify `C-j`, `C-k`, arrows, `RET`, `Esc`, and `C-g` still navigate, accept, and cancel normally.
7. Cancel from an active Extend selection and confirm exact bounds, submode, active edge, and point remain unchanged.

## Non-Goals

- Do not change fuzzy matching, provider behavior, candidate ordering, or picker geometry.
- Do not add a general transient-menu framework as part of this focused fix.
- Do not change the Pick or Space key assignments.
- Do not suppress submenu commands based on the current buffer or replay rejected input events.
