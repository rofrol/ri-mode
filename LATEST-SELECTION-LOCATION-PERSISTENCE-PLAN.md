# Latest Selection Location Persistence Plan

## Problem

Ri restores a persisted selection submode, but it can reopen a file at an old
semantic unit. Moving to another NODE changes point and the in-memory
`sr--node-current`, but it does not itself create a new durable cursor/session
snapshot. A later Emacs start can therefore restore the same old NODE location.

The current configuration enables both `save-place-mode` and
`desktop-save-mode`. The persisted records currently agree on the old point:
`places.eld` and `.emacs.desktop` both contain point 939 for `main.odin`, while
Ri's multisession value contains `node`.

## Root cause

Three independent mechanisms own different state:

- `ri--last-selection-submode` writes the last committed submode immediately.
  It intentionally stores only a symbol such as `node`, not a file position.
- `save-place-mode` records point when a buffer is killed or Emacs exits.
  Emacs 31 also supports periodic writes through
  `save-place-autosave-interval`, but its default is `nil`.
- `desktop-save-mode` saves point and buffer-local `sr-submode` on normal exit.
  Its idle autosave is scheduled by window-configuration changes, not by point
  or NODE navigation.

In the current configuration, Ri navigation itself schedules neither
persistence file for an update. Desktop restoration can therefore override the
Ri-wide submode default and save-place position with an older per-buffer
snapshot.

## Decision

Keep Emacs's built-in persistence formats. Do not add another Ri session file,
serialize tree-sitter nodes, or write the desktop synchronously after every key.

Use the existing Ri post-command location comparison to request Emacs's native
desktop autosave only after an actual Ri location change. Configure
`save-place-autosave-interval` for the independent save-place path. This closes
the missing checkpoint while retaining desktop/save-place ownership of their
files and batching disk I/O behind Emacs's idle timers.

Do not change `ri.el` top-level dependencies or `ri-enable`. The implementation
belongs in `ri-extend.el`, where the existing Move History snapshots already
identify changes to file, point, effective submode, Extend bounds, and active
edge.

## Required behavior

- After moving to another semantic unit, the latest stable point is included in
  the next native persistence write without requiring a window-layout change.
- With desktop enabled, a later restart restores the latest persisted point and
  the buffer-local selection submode.
- With desktop disabled, `save-place-mode` restores the latest point once its
  configured autosave interval has elapsed.
- NODE restoration rebuilds the node from the restored point through the
  existing semantic-regions path; live tree-sitter node objects are never
  persisted.
- Held momentary navigation may move point, but Ri must not deliberately save
  the temporary `LINE`, `WORD+`, or `CHAR` submode. The desktop request is made
  after the original submode is restored on release.
- Active Extend state, exact Extend bounds, undo history, overlays, and Move
  History remain transient.
- Persistence remains optional. Ri must behave unchanged when desktop and
  save-place are disabled or not loaded.
- Navigation must not perform synchronous disk I/O.

## Implementation

### 1. Request desktop autosave after a stable location change

Update `ri-extend.el`:

- Add a small deferred timer and callback in `ri-extend.el`. The callback calls
  `desktop-auto-save` only when Desktop is active and available.
- Do not require `desktop`; the existing lazy integration must remain lazy.
- In `ri--history-post-command`, use the snapshot comparison already performed
  for Move History. When the before/after location differs, request the
  deferred save after the history state is committed.
- Do not request a save for commands whose snapshot is unchanged.
- Do not add another post-command hook or repeat point comparison logic.

The previous implementation called `desktop-auto-save-set-timer`, but that
timer is reset by Desktop's window-configuration hook and did not reliably
checkpoint point/NODE navigation. The Ri-owned one-shot timer avoids that
dependency while still delegating serialization, ownership checks, and
`only-if-changed` handling to Emacs's native `desktop-auto-save`.

### 2. Keep momentary submodes transient

A held navigation layer temporarily changes `sr-submode`, while
`ri--history-effective-submode` correctly reports the persistent origin. Avoid
requesting the desktop checkpoint while `ri--momentary-origin-submode` is
non-nil. After `ri--restore-momentary-submode` restores the origin, request the
checkpoint once so the moved point is saved with the stable submode.

Direct mode switches, normal navigation, mouse retargeting, and Move History
restoration continue through the existing post-command snapshot flow and need
no command-specific persistence calls.

### 3. Document the native save-place interval

Update the README persistence example so users who need durability before
buffer kill or normal Emacs exit can opt into Emacs 31's native periodic save:

```elisp
(setq save-place-autosave-interval 30)
(save-place-mode 1)

(setq desktop-save t)
(desktop-save-mode 1)
```

Explain the distinct roles:
- `save-place-autosave-interval` periodically writes current file points;
- Ri defers a native desktop save after stable location changes;
- `desktop-auto-save-timeout` must be positive to enable that native save;
- normal Emacs exit still performs the final save for both mechanisms.

Do not enable either global mode or choose a shorter write interval from Ri.
Those remain user-owned Emacs policy.

## Regression coverage

Add focused tests in `ri-extend-test.el`:

1. A real point change in an eligible Ri file buffer requests desktop autosave.
2. An unchanged command does not request desktop autosave.
3. Repeated location changes reuse Emacs's timer path rather than writing a file
   directly.
4. Momentary navigation does not request a checkpoint while its temporary
   submode is active; release requests one after restoring the origin.
5. The feature is a no-op when desktop is disabled or its autosave function is
   unavailable.
6. Existing Extend bounds and active-edge tests continue to pass, proving that
   persistence scheduling does not alter navigation state.

Stub only `desktop-auto-save-set-timer` in focused unit tests. Do not test
Emacs's timer or desktop serializer implementation again; the existing
`semantic-region-test-desktop-restores-submode` round trip already covers Ri's
serialized buffer-local state and highlight restoration.

## Verification

1. Run the focused `ri-extend-test.el` persistence and Move History tests.
2. Run `semantic-regions/semantic-regions-test.el` desktop tests.
3. Byte-compile changed Emacs Lisp files with warnings treated as errors.
4. Perform a two-process smoke test using a temporary `user-emacs-directory`:
   - enable save-place autosave and desktop save mode;
   - open a file in NODE, move to a different node, release all momentary
     layers, and wait past the configured idle intervals;
   - terminate the first process without relying on its normal-exit persistence
     hooks;
   - start the second process and confirm the restored point, `sr-submode`,
     highlighted node, and mode-line label describe the new location;
   - confirm Extend starts inactive.
5. Repeat with desktop disabled and verify that save-place alone restores the
   new point after its autosave interval.

## Acceptance criteria

- Moving to another NODE no longer leaves desktop waiting for an unrelated
  window-layout change before scheduling a save.
- After the configured idle interval, restarting Emacs restores the new point
  rather than point 939 from the old snapshot.
- The persistent selection submode and restored semantic highlight agree.
- Temporary held-layer submodes are not intentionally checkpointed by Ri.
- No custom persistence file, serialized node object, synchronous
  per-navigation write, new top-level dependency, or `ri-enable` change is
  introduced.
