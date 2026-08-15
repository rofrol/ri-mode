# Transform Menu Persistence Plan

## Problem

`Transform` is intended to be a normal menu opened with `Shift+F`, not a KKP tap-hold layer. Releasing `Shift+F` must not hide the menu.

The current source has the correct high-level binding:

- `ri.el` binds uppercase `F` directly to `ri-transform-menu`.
- `?F` is absent from `ri--layer-specs`, so Transform should not be registered as a momentary KKP layer.
- `ri-transform.el` provides `ri--transform-menu-map` as the menu keymap.

Two details still make the behavior fragile:

1. `ri-transform-menu` installs `ri--transform-menu-map` with `set-transient-map` and a nil keep predicate. That is a one-command transient map, so any release event that reaches Emacs as the next command can dismiss the menu.
2. `ri-chord-setup` only adds current layer registrations. In a live Emacs session that previously loaded the old `?F` momentary layer, the obsolete KKP registration can remain in the chord tables after the source is re-evaluated.

The existing regression test checks that KKP translates one release sequence to `[]`, but it does not prove the complete transient-map lifecycle or repeated setup after removing the old layer.

## Required behavior

- Pressing `Shift+F` opens the Transform menu.
- Releasing `Shift`, releasing `F`, or receiving both release events leaves the menu visible.
- The menu remains active while the user chooses a transform command.
- Choosing any transform command executes it once and closes the Transform menu, hides its legend, and restores the status frame.
- `Escape` closes the menu without transforming text.
- Transform is not present in `ri--layer-specs` and is not registered in any KKP chord table.
- Re-running `ri-enable` or `ri-chord-setup` in the same Emacs process does not resurrect or retain the old `?F` momentary registration.
- Other momentary layers and other menus keep their current behavior.

## Design

### 1. Keep Transform outside the momentary-layer registry

In `ri.el`:

- Keep the uppercase `F` bindings in `mini-modal-map` and `ri--normal-help-map` pointing to `ri-transform-menu`.
- Do not add `?F` back to `ri--layer-specs`.
- At the start of `ri-chord-setup`, explicitly undefine the obsolete uppercase-`F` chord with `kkp-chord-undefine`. This is a compatibility cleanup for sessions that loaded the former momentary implementation; it does not change current layer registration.
- Extend chord-registration tests to assert that `?F` has no KKP map, tap action, press action, or release action after setup.

Do not introduce a second Transform keymap or a second layer-registration path.

### 2. Make the menu survive the trigger release

In `ri.el`, change `ri-transform-menu` to use a function keep predicate for `set-transient-map`:

- Keep the transient map active while `ri--menu-state` is `transform`.
- Use the existing `ri--close-menu` callback for normal transient-map exit.
- Do not treat the trigger key's release as a menu command.

A persistent transient map requires an explicit close after a transform command. Reuse one small internal finish helper rather than duplicating legend/frame cleanup in every command. The helper must close only when the active menu is Transform, so direct calls to transform commands do not disturb unrelated menus.

`Escape` continues to use the existing `ri--exit-menu` path.

### 3. Close after a selected transform

In `ri-transform.el`:

- Route menu-selected transform commands through the shared finish path after their existing text operation completes.
- Preserve the current behavior of all transformations, including no-selection no-ops, point placement, selection highlighting, buffer edits, and undo grouping.
- Ensure a command error does not leave stale Transform UI active; use the smallest cleanup mechanism compatible with the existing command structure.

Do not alter the transformation algorithms. This change is only about menu lifetime and KKP registration.

## Tests

### `ri-transform-test.el`

Strengthen the current tests to cover observable behavior:

1. `ri-enable` binds uppercase `F` to `ri-transform-menu` in both normal keymaps and does not register `?F` as a chord.
2. A stale `?F` registration is removed by `ri-chord-setup`.
3. Opening Transform installs a persistent transient map whose keep predicate remains true while `ri--menu-state` is `transform`.
4. KKP release input for `Shift+F` is swallowed and leaves the legend and menu state visible.
5. A selected transform command closes the menu exactly once after running.
6. `Escape` closes the menu without invoking a transform.
7. Re-running setup does not alter registrations for existing momentary layers.

Use mocks for legend, frame, and transient-map UI where needed. Assert menu state and command dispatch, not private window layout details.

### Focused behavioral check

Run the Transform ERT suite with the external `kkp.el` directory available. The current checkout lacks `kkp.el`, so a local batch run cannot load `ri` until that dependency is supplied.

## Verification

Run the focused suite using the repository's normal load paths:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs -Q --batch \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L kkp-chord \
  -L ri-tabs -L ri-pick -L ri-pairs -L ri-surround -L ri-mouse \
  -l ri-transform-test.el \
  -f ert-run-tests-batch-and-exit
```

Then smoke-test the actual TTY path in `emacs -Q -nw` with KKP enabled:

1. Enter NORM mode with a visible selection.
2. Press `Shift+F` and release it completely.
3. Confirm the Transform legend remains visible and the mode is not reported as a momentary layer.
4. Select one transform and confirm the text changes once and the legend disappears.
5. Reopen Transform, press `Escape`, and confirm no text changes occur.
6. Reload or re-evaluate the Ri setup in the same Emacs process, repeat `Shift+F`, and confirm release still does not hide the menu.
7. Hold each existing momentary layer once to confirm its press/release behavior is unchanged.

No startup benchmark is required unless implementation changes `ri-enable`, top-level dependencies, or lazy-loading boundaries. If it does, follow `.agents/skills/ri-startup-performance/SKILL.md` before and after the change.

## Acceptance criteria

- `Shift+F` opens a persistent Transform menu.
- Trigger-key release never dismisses the menu.
- A transform selection and `Escape` remain the only normal dismissal paths.
- No uppercase-`F` KKP registration remains, including after setup is repeated in a live session.
- Existing transform semantics and all unrelated layers remain unchanged.
- Focused ERT tests and the real TTY smoke scenario pass.

## Non-goals

- No new transformation commands.
- No changes to semantic selection or Extend behavior.
- No changes to KKP protocol parsing.
- No redesign of other menus or momentary layers.
- No new dependency or persistent Transform configuration.
