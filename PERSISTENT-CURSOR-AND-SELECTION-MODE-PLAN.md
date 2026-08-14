# Persistent Cursor and Selection Mode — Implementation Plan

## Problem

After Emacs restarts, Ri does not restore the last cursor position in a file.
The current semantic selection submode (`LINE`, `WORD`, `CHAR`, `NODE`, etc.)
is also not restored. The request is about restoring buffer-local editing state,
not reopening arbitrary files or preserving an in-progress Extend selection.

## Current implementation

Ri does **not** currently implement cursor or selection-state persistence.

- Emacs owns the cursor as the buffer-local `point` value.
- `mini-modal-mode` owns the normal/insert state. It is a bundled Ri helper,
  not an Emacs built-in mode.
- `semantic-regions` owns the current selection submode in the buffer-local
  variable `sr-submode` (`semantic-regions/semantic-regions.el:64-67`).
- Ri enables `sr-mode` per editing buffer from `ri--maybe-enable-semantic-regions`
  (`ri.el:1169-1178`).
- Ri's active Extend selection is transient state in `ri--selection`, containing
  markers, active-edge state, and an extension undo stack
  (`ri-extend.el:16-26`).
- `ri-enable` installs global setup and buffer hooks, but it does not enable
  `save-place-mode`, `desktop-save-mode`, or any custom point/session store
  (`ri.el:1180-1222`).

Ri does use an Emacs built-in persistence mechanism elsewhere: `ri-tabs` stores
persistent marked-file identities through `multisession.el`
(`ri-tabs/ri-tabs.el:24-38`). That storage is unrelated to point restoration or
semantic selection mode.

## Decision

Use Emacs's built-in mechanisms. Do not create a Ri-specific session file or
serialize `point` manually.

### Cursor position: `save-place-mode`

Use `save-place-mode` for normal file visits. It is the canonical Emacs
mechanism for saving and restoring the last point for each visited file.
It works independently of Ri and does not require desktop session restoration.

The user's init must opt in:

```elisp
(save-place-mode 1)
```

Ri should document this configuration rather than silently enabling a global
user mode from `ri-enable`.

### Whole-session restoration: `desktop-save-mode`

Use `desktop-save-mode` when the desired behavior is to restore the previous
set of buffers, their positions, and the window/frame session:

```elisp
(desktop-save-mode 1)
```

`desktop.el` already saves buffer positions and restores conventional minor
modes. No Ri-owned replacement is justified.

### Selection submode: `desktop-locals-to-save`

`sr-submode` is a buffer-local symbol, not a minor mode, so desktop will not
restore it automatically. Register that variable with desktop when desktop is
loaded:

```elisp
(with-eval-after-load 'desktop
  (add-to-list 'desktop-locals-to-save 'sr-submode))
```

This is the smallest canonical integration. It lets desktop serialize the
existing `sr-submode` value without adding a second source of truth or a Ri
session database.

If the package owns this integration, place it in `semantic-regions.el` behind
`with-eval-after-load 'desktop`; do not require `desktop` during normal Ri
startup. The integration must remain inert when desktop is not used.

## Behavioral contract

1. With `save-place-mode` enabled, reopening a visited file restores the last
   saved Emacs point.
2. With `desktop-save-mode` enabled, restarting Emacs restores the desktop's
   buffers and their saved point positions.
3. With desktop enabled, `sr-submode` is restored per buffer, including values
   such as `word`, `word-plus`, `char`, and `node`.
4. Ri's normal semantic highlight is recalculated after the restored point and
   restored submode are available.
5. Ri must not move the restored point through `mini-modal-normal`; restoration
   must preserve Emacs's saved position rather than apply an unrelated cursor
   normalization step.
6. If desktop is disabled, no cross-restart `sr-submode` restoration is
   promised. `save-place-mode` still restores point for ordinary file visits.
7. An active Extend selection is not restored. On restart, `ri--selection` is
   nil and Extend is inactive.
8. The current submode, point, and normal/insert behavior remain unchanged
   during the current session.
9. Missing files, special buffers, minibuffers, and buffers that Ri does not
   manage remain outside this persistence feature.

## Why Extend state is out of scope

`ri--selection` is not a simple mode flag. It contains live markers, exact
selection boundaries, the active edge, and an undo stack. Restoring it would
require validating that the same buffer contents, markers, submode semantics,
and active-edge invariants still hold after restart. Persisting that transient
editor state would be fragile and would add a custom serialization protocol.
Restore the durable pieces (`point` and `sr-submode`) and start with Extend
inactive.

## Implementation steps

### 1. Add desktop integration for `sr-submode`

Update `semantic-regions/semantic-regions.el`:

- add a `with-eval-after-load 'desktop` block;
- add `sr-submode` to `desktop-locals-to-save` exactly once;
- refresh all semantic-regions buffers through `desktop-after-read-hook`;
- add a `with-eval-after-load 'saveplace` block that refreshes the current
  semantic highlight through `save-place-after-find-file-hook`;
- do not require `desktop` or `saveplace` at normal Ri load time;
- do not add `ri--selection`, markers, overlays, or tree-sitter node objects
  to desktop persistence.

This keeps the state buffer-local and reuses desktop/save-place's existing
serializers. The refresh hooks are required because persistence can restore
point and local variables after Ri's ordinary file-open highlight pass.

### 2. Refresh Ri after restored point/submode

Desktop restoration was verified to leave a stale semantic overlay when Ri
enabled semantic-regions during `find-file-hook`: the restored point and
submode were correct, but the old overlay still covered the pre-restoration
unit. The implementation fixes this through the two lifecycle hooks above.

Do not add timers, advice, or a second point-restoration pass.

### 3. Document opt-in configuration

Update `README.md` setup documentation with the two independent options:

- `save-place-mode` for point restoration on file visits;
- `desktop-save-mode` plus `sr-submode` registration for full session and
  selection-submode restoration.

Make clear that enabling desktop is an Emacs user choice and that Ri does not
silently enable either global persistence mode.

### 4. Add focused project-owned verification

Add tests only for Ri's integration, not for Emacs's own `save-place` or
desktop implementation:

- after loading desktop integration, `sr-submode` is registered in
  `desktop-locals-to-save` without duplicates;
- a desktop round trip restores a buffer's `sr-submode` value;
- restored `sr-submode` causes Ri's mode-line/highlight path to use the same
  semantic unit;
- active `ri--selection` is not serialized or reactivated.

Use temporary desktop and file locations. Do not modify the user's real
`desktop` or `save-place` files during tests.

## Verification

1. Run the focused semantic-regions/RI tests.
2. Run a batch load smoke test with the desktop integration present and desktop
   not loaded; Ri must still load without requiring `desktop`.
3. Perform an interactive smoke test:
   - enable `(save-place-mode 1)`;
   - open a real file, move point, save/exit, and reopen it;
   - confirm point returns to the saved position;
   - select a non-default Ri submode, save the desktop, restart Emacs, and
     confirm the mode line and highlight show the same submode;
   - confirm Extend starts inactive after restart.
4. If `ri.el` or `ri-enable` is changed while implementing the plan, run the
   repository startup benchmark before and after the change using the required
   `ri-startup-performance` workflow. Prefer avoiding that startup-sensitive
   change entirely.

## Implementation status

Implemented:

- `semantic-regions/semantic-regions.el` lazily registers `sr-submode` with
  desktop and refreshes semantic highlights after desktop or save-place
  restoration.
- `semantic-regions/semantic-regions-test.el` covers registration, desktop
  round-trip restoration of point/submode, highlight retargeting, and the
  exclusion of transient `ri--selection`.
- `README.md` documents the opt-in `save-place-mode` and `desktop-save-mode`
  configuration.

Verification:

- 66 semantic-regions tests passed; 8 tree-sitter-dependent tests skipped.
- Batch load confirmed neither `desktop` nor `saveplace` is loaded by default.
- A two-process save-place smoke test restored point 7.

## Non-goals

- Do not add a custom persistence file.
- Do not use `savehist` for buffer state.
- Do not use bookmarks for a cursor position that Emacs already saves natively.
- Do not automatically enable desktop or save-place globally.
- Do not restore active Extend selections, selection undo history, overlays,
  momentary layer state, or tree-sitter node objects.
- Do not change Ri's modal keybindings or current-session selection semantics.

## Rollback boundary

The change is independently revertible: remove the desktop registration,
README configuration text, and focused integration tests. Ri then returns to
its current behavior while Emacs's unrelated `save-place-mode` and
`desktop-save-mode` features remain available to users.
