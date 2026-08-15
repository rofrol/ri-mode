# Emacsclient Marked Tabs Restoration Plan

## Problem

`TODO.md` reports that marked tabs are not restored when Emacs is started through `emacsclient`.

`ri-tabs-mode` restores a persisted owner set only during its one-time activation in `ri-tabs--activate`.  Later client frames enter through `ri-tabs--configure-new-frame`, which synchronizes live-buffer caches and renders the tab surface, but never derives or activates the new frame's owner.  If the daemon had no eligible file-backed frame during initial activation, the client frame is never offered the persisted marked files for its repository.

## Required behavior

When `ri-tabs-mode` is active and an ordinary `emacsclient` frame is created:

1. Determine the frame's selected ordinary window and its owner context using the existing file-buffer or `default-directory` path.
2. If that owner has persisted marks, restore its missing marked files exactly once for the current `ri-tabs-mode` enablement.
3. Assign that owner to the new frame and render its tabs.
4. If the client frame starts on a non-file buffer in a marked owner's directory, select the last successfully restored marked buffer, matching the existing empty-startup behavior.
5. Leave frames with no matching persisted owner unchanged.  Do not restore every owner set or change the owner of existing frames.

## Implementation

### `ri-tabs/ri-tabs.el`

1. Reuse `ri-tabs--activate-existing-owner-for-frame` from `ri-tabs--configure-new-frame` after reading the hook-safe state with `ri-tabs--state-for-hook`.
   - That helper already derives the owner from the selected file buffer or its `default-directory`.
   - It already requires persisted membership before assigning the frame owner.
   - It delegates one-time restoration to `ri-tabs--activate-owner`, preserving the `ri-tabs--restored-owners` guard and existing error handling.
2. Keep the current cache synchronization and surface update.  The ordering should be:
   - read state;
   - if readable, activate the new frame's existing owner and synchronize live buffers;
   - render the frame surface.
3. Do not add emacsclient-specific detection, new lifecycle state, timers, or a second restoration implementation.  `after-make-frame-functions` is the shared frame-creation boundary for graphical and terminal clients.
4. Do not change startup activation.  Its job remains initial daemon/startup restoration; the added call only covers frames created after that activation has completed.

## Regression coverage

### `ri-tabs/ri-tabs-test.el`

Add a focused frame-creation test without launching an external `emacsclient` process:

1. Create a real temporary Git repository with two files and persist both under its canonical owner context.
2. Enable `ri-tabs-mode` with `after-init-time` non-nil while the selected frame is unrelated, so normal activation cannot restore that repository.
3. Create a new ordinary frame or invoke `ri-tabs--configure-new-frame` against a fixture frame whose selected ordinary window displays a non-file buffer with `default-directory` set to the repository.  Use the repository's existing frame-state cleanup conventions.
4. Assert that both marked identities now have exactly one live buffer, every restored buffer is marked, and the client frame owner is the repository owner.
5. Assert that the client window displays the last restored marked buffer when it began on the non-file directory buffer.
6. Invoke frame configuration again and assert that no duplicate buffers are opened.  This protects the existing once-per-owner restoration contract.
7. Retain the existing empty-startup and post-startup tests; they cover the same owner-selection rules at activation time, while this test covers the later frame hook.

## Verification

Run the focused tab suite:

```sh
emacs --batch -Q -L ri-tabs -l ri-tabs/ri-tabs-test.el \
  -f ert-run-tests-batch-and-exit
```

Then smoke-test the daemon path manually:

1. Start a clean daemon with Ri enabled and no client frame in the marked repository.
2. Create a client frame rooted in that repository, for example with `emacsclient -c --eval '(progn (setq default-directory "/path/to/repo/") nil)'` or by opening a file there.
3. Confirm that the persisted marked files appear once in the new frame's Ri tab surface and that reopening/configuring the frame does not duplicate buffers.
4. Create a client frame in an unrelated directory and confirm that it does not reopen the repository's marked set.
