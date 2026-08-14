# Last Selection Mode Persistence Plan

## Problem

After Emacs restarts, Ri falls back to `LINE` instead of using the last persistent selection mode chosen by the user.

The current desktop integration is working, but it solves a narrower problem: when `desktop-save-mode` is enabled and a buffer is included in the desktop snapshot, `desktop.el` restores that buffer's local `sr-submode`. The focused desktop round-trip tests pass. Without desktop restoration, a new Emacs process reads the default value of the buffer-local `sr-submode`, which is always `line`.

The missing behavior is therefore an Ri-wide last-mode default that is restored independently of desktop sessions.

## Required behavior

- A persistent switch to `LINE`, `LINE*`, `PARAGRAPH`, `CHAR`, `WORD`, `WORD+`, `WORD*`, `SUBWORD`, or `NODE` becomes the default for buffers opened by the next Emacs process.
- The value is written when the switch commits; normal Emacs exit is not required.
- A tap of the `a`, `s`, or `w` navigation layer counts as a persistent switch.
- Held momentary navigation does not replace the saved mode with its temporary `LINE`, `WORD+`, or `CHAR` target.
- Restoring a momentary layer's origin does not perform another persistent write.
- Existing per-buffer desktop restoration remains supported and takes precedence for buffers carrying a saved local `sr-submode`.
- Active Extend state, selection bounds, active edge, momentary-layer state, overlays, and NODE objects remain transient.
- A missing, invalid, or unreadable persisted value must not prevent Ri from loading; use `line` and issue a warning for a read/write failure.

## Decision

Use Emacs's built-in `multisession.el`, already used by `ri-tabs`, for one Ri-owned symbol containing the last committed selection mode. Do not add a custom session file, enable `desktop-save-mode` or `savehist-mode`, or persist complete buffer/selection state.

Keep the state in `ri-extend.el`, where Ri distinguishes persistent selection commands from momentary navigation. `semantic-regions.el` should continue to own the buffer-local `sr-submode` and its desktop integration.

At `ri-extend.el` load time:

1. Read the stored symbol.
2. Accept it only when it is one of the submodes already present in `sr--submode-properties`.
3. Set the default value of `sr-submode` before `ri-enable` activates semantic regions in buffers.
4. Fall back to `line` if no valid value is available.

A desktop-restored buffer already has a local value, so changing the default does not overwrite it. Buffers without a desktop-local value inherit the restored Ri-wide default.

## Implementation

### 1. Add the small persistent store in `ri-extend.el`

- Require the built-in `multisession` library explicitly.
- Define one synchronized multisession variable under an Ri package key, with `line` as its initial value.
- Add one read helper that validates the stored symbol and initializes `(default-value 'sr-submode)`.
- Add one commit helper that updates both the default value and the multisession value after a successful persistent switch.
- Keep persistence errors outside the editing path: the local submode switch succeeds, while the helper reports that cross-restart persistence failed.

No `ri.el` dependency or `ri-enable` change is needed. In the normal Ri load path, `ri-tabs` already loads `multisession` before `ri-extend`.

### 2. Make the persistent/momentary boundary explicit

The existing momentary commands call the same `ri-extend-set-*` commands used by persistent key bindings. Persisting inside those commands without separating the callers would save temporary held-layer modes.

Update the flow as follows:

- `ri-extend-set-*-mode` commands keep using `ri--set-submode-with-extend`, then call the commit helper.
- `ri--run-momentary-navigation` switches through `ri--set-submode-with-extend` using the underlying `sr-set-*` setter directly, then performs movement.
- `ri--restore-submode` remains non-persistent.
- Layer `:tap` actions continue to target `ri-extend-set-*-mode`, so a tap commits even though the chord dispatcher invokes the function non-interactively.
- `ri-set-node-mode` continues to route through `ri-extend-set-node-mode`, so NODE commits through the same path.

This preserves the repository invariants: switching submodes during Extend keeps exact bounds, and navigation leaves point on the active edge.

### 3. Keep desktop integration and document precedence

Update `README.md`:

- state that Ri automatically restores the last committed selection mode as the default for new buffers;
- state that no desktop configuration is required for this Ri-wide default;
- retain the existing `desktop-save-mode` instructions for per-buffer session restoration;
- explain that a desktop-restored buffer's saved local mode overrides the Ri-wide default;
- retain the statement that active Extend selections are never restored.

Do not remove the desktop/save-place highlight refresh hooks: desktop and save-place restore point after the ordinary file-open highlight pass.

## Regression coverage

Add focused tests in `ri-extend-test.el` using a temporary multisession store/backend so the user's real state is untouched:

1. A valid stored mode initializes the default `sr-submode`, and a fresh buffer inherits it.
2. Every persistent `ri-extend-set-*-mode` command updates the current buffer, the default, and the stored value.
3. A layer tap invoked through its stored `:tap` function commits the target mode.
4. Held momentary navigation changes the active mode temporarily but does not change the stored value; release restores the origin and still does not write.
5. Persistent switching while Extend is active keeps the exact selection bounds and active edge while saving the new mode.
6. An invalid stored symbol falls back to `line`; a storage error warns without aborting the mode switch.

Keep the existing `semantic-region-test-desktop-*` tests. They prove the more specific per-buffer desktop behavior and guard its precedence over the global default.

## Verification

1. Run the focused `ri-extend-test.el`, `ri-chord-test.el`, and desktop persistence ERT tests.
2. Byte-compile changed Emacs Lisp files with warnings treated as errors.
3. Run a two-process smoke test with a temporary `user-emacs-directory`:
   - process A loads Ri, commits a non-default mode through the real Ri command, and exits;
   - process B loads Ri without desktop, opens a fresh buffer, and confirms the same `sr-submode` and mode-line label;
   - repeat with a momentary held-layer navigation before exit and confirm it does not replace the committed mode.
4. Run a desktop smoke test with two buffers using different saved local modes and a different Ri-wide default; confirm each desktop buffer keeps its local mode while a newly opened buffer inherits the global default.

## Acceptance criteria

- Restarting Emacs without desktop restores the last committed Ri selection mode for fresh buffers.
- Persistent taps and direct mode commands update the saved mode immediately.
- Held navigation and release never overwrite the saved mode.
- Desktop-restored per-buffer modes continue to work and override the global default only in those buffers.
- Extend bounds and active-edge placement are unchanged.
- Invalid or unavailable persistence falls back safely without breaking Ri startup or mode switching.
