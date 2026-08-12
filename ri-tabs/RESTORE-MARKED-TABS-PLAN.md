# Restore Persistent Marked Tabs — Implementation Plan

## Problem

The persistent-mark implementation stores every marked file identity correctly, but the tab list is still derived exclusively from live file-visiting buffers. After Emacs restarts, only files reopened by another mechanism have live buffers, so only those files appear as tabs. The remaining marks stay in multisession storage and become visible only after their files are opened manually.

This behavior follows the earlier `PERSISTENT-MARKS-PLAN.md`, which explicitly chose not to reopen closed marked files. That decision does not satisfy the desired restart behavior: after marking files `A` and `B`, a new Emacs process should restore both as tabs without requiring explicit `find-file` calls.

## Goal

When `ri-tabs-mode` activates in a new Emacs session, reopen every available persistently marked file that does not already have a live buffer. Once restoration finishes, all recoverable marked files must be represented by live marked buffers and therefore appear in the Ki tab list.

The restore must preserve the selected buffer and window configuration, avoid duplicate buffers, isolate per-file failures, and never alter persistent membership merely because a file cannot currently be opened.

## Superseded decisions

This plan supersedes only the following decisions from `PERSISTENT-MARKS-PLAN.md`:

- the feature does not automatically reopen closed files;
- closed marked files are never displayed after restart unless another mechanism opens them;
- mode initialization only synchronizes buffers that are already live.

The persistent state model, canonical file identities, explicit mark/unmark semantics, global scope, rename migration, synchronized multisession reads, and render-cache design remain unchanged.

## Revised behavioral contract

1. Marking a file persists its canonical identity immediately.
2. Killing a marked buffer does not unmark its file and does not immediately reopen it during the same activation of `ri-tabs-mode`.
3. On the next Emacs startup with `ri-tabs-mode` enabled, every available persisted marked file is opened with `find-file-noselect` if no live buffer already represents its identity.
4. Enabling `ri-tabs-mode` after startup performs the same restoration immediately.
5. Disabling and later re-enabling `ri-tabs-mode` in the same process starts a new activation and restores any persistently marked files that were closed while the mode was disabled or during the previous activation.
6. Restoration never switches the selected window or current user buffer and never displays one restored file in preference to another.
7. Files already opened by Desktop, command-line arguments, or user startup code are reused; restoration must not create duplicate buffers for the same canonical identity.
8. Explicitly unmarked files are absent from persistent state and are not reopened by Ki tabs.
9. A missing, inaccessible, or temporarily unavailable file remains persistently marked but is skipped for that restoration attempt. Restoration must not create an empty new-file buffer for a missing path.
10. Failure to open one marked file does not prevent later marked files from being restored.
11. Restoring files is a read-only operation with respect to persistent membership. The only write allowed at activation is the existing first-use initialization when the multisession value is `nil`.
12. Marked-buffer navigation continues to operate on live buffers. After successful startup restoration, that live set includes every restored marked file.
13. Non-file buffers remain outside the persistent mark and restore model.

## Scope

Restoration remains global within Emacs because persistent marks and the existing tab list are global. It does not introduce workspaces, projects, per-frame tab sets, or persistence for arbitrary unmarked buffers.

This change is not a general session manager. It reopens only identities explicitly present in Ki tabs' persistent marked-file state. It does not save point, narrowing, window placement, unsaved edits, or buffer-local modes beyond what normal `find-file` and other installed session mechanisms already provide.

## Persistent data model

Keep the existing version-1 multisession value unchanged:

```elisp
(:version 1
 :files ("/canonical/path/a.el"
         "/canonical/path/b.el"))
```

No migration or additional storage key is required. The existing invariants remain:

- identities are canonical expanded strings;
- identities are unique and lexically sorted;
- `nil` means uninitialized storage;
- `(:version 1 :files nil)` means an explicitly empty marked set;
- automatic recovery never deletes unavailable identities;
- malformed or unsupported state is not overwritten by automatic code.

The stored identity is sufficient for `find-file-noselect`. A file originally opened through a symlink will be restored through its stored canonical path because the current schema intentionally does not retain the presentation path.

## Activation timing

### Enabling during Emacs initialization

`ri-enable` calls `ri-tabs-mode` directly and may run from the user's init file. At that point Desktop restoration and command-line file visits may not have completed. Opening stored files immediately would work, but it would duplicate work performed later by startup mechanisms and would initialize first-use state too early.

When `after-init-time` is `nil`, `ri-tabs--enable` should:

1. install the existing Ki tabs hooks immediately;
2. arrange one idempotent callback on `emacs-startup-hook`;
3. defer persistent-state activation and marked-file restoration to that callback.

`emacs-startup-hook` runs after init files and command-line processing. Desktop restoration normally runs from `after-init-hook`, so the restore callback can reuse buffers opened by both Desktop and command-line arguments.

### Enabling after initialization

When `after-init-time` is non-nil, activation and restoration should run immediately. This covers interactive enables, package loading after startup, daemon sessions after initialization, and the second enable in the same Emacs process.

### Cancellation

Disabling `ri-tabs-mode` before the deferred startup callback runs must remove or neutralize the pending callback. A stale callback must not open files after the user has disabled the mode.

The callback must also clear its pending flag with `unwind-protect`, so an error or quit cannot leave restoration permanently marked as scheduled.

## Activation lifecycle

Split the current `ri-tabs--enable` responsibilities into two stages.

### Stage 1: install mode infrastructure

This stage runs immediately whenever the mode is enabled:

- add `find-file-hook`, visited-file-name, major-mode, kill, save, revert, and refresh hooks;
- install Ki tab-line configuration on file buffers that are already live;
- schedule activation after startup or run it immediately, according to the timing rules above.

Hook installation must remain idempotent.

### Stage 2: activate persistent state

Add one internal activation function used by both the startup callback and immediate enables. It should:

1. confirm that `ri-tabs-mode` is still enabled;
2. read and validate the synchronized multisession state once;
3. if state is uninitialized, collect all live visible file buffers at this semantic boundary, persist one initialized version-1 state, and use that state for the rest of activation;
4. if state is valid and initialized, restore its missing marked-file buffers;
5. synchronize every live file buffer's `ri-tabs--file-id` and `ri-tabs--marked-p` cache from the validated state;
6. install Ki tab-line configuration in every live visible file buffer;
7. issue one final global tab-line refresh.

Deferring first-use initialization together with restoration preserves the original “mark files already open on first enable” behavior for files restored by Desktop or opened from the command line during startup.

If persistent state cannot be read or validated, activation must warn, skip all automatic opens and writes, leave affected caches unmarked for that attempt, and keep ordinary file visiting usable.

## Restore algorithm

Add a helper such as `ri-tabs--restore-marked-files` that accepts an already validated state. It must not read or write the multisession value itself.

Algorithm:

1. Build an index of canonical identities represented by live visible file buffers using `ri-tabs--buffer-file-id`.
2. Iterate over the normalized `:files` list in deterministic order.
3. Skip an identity already present in the live index.
4. Check that the path currently exists before visiting it. Catch errors from this check because TRAMP and unavailable mounts can signal.
5. If it does not exist, record a restore failure and continue without calling `find-file-noselect`.
6. Open an available missing identity with `find-file-noselect`. Never call `find-file`, `pop-to-buffer`, `switch-to-buffer`, or another displaying API.
7. Verify that the returned live file buffer resolves to the expected canonical identity, add it to the live index, and let the existing `find-file-hook` restore its render cache and tab-line configuration.
8. Catch an error for one identity, record the original path and error, and continue with the remaining identities.
9. After iteration, report one `ri-tabs` warning summarizing paths that could not be restored. Do not remove them from persistent state.

A user quit should stop restoration rather than being converted into an ordinary per-file warning. Persistent state must still remain untouched, and the activation cleanup must still clear pending and reentrancy flags.

## Focus and window invariants

Automatic restoration is background buffer creation, not navigation. Surround the operation with the appropriate current-buffer and selected-window preservation so that:

- `current-buffer` after activation is the same live buffer as before activation;
- `selected-window` and its displayed buffer are unchanged;
- point, window start, and the window configuration are unchanged;
- no restored file becomes the selected or most recently displayed tab merely because of restore order.

`find-file-noselect` is the required primitive because it creates or reuses a visiting buffer without selecting it. The implementation must not compensate with a later `switch-to-buffer`, which would still cause visible flicker and alter buffer history.

## Duplicate prevention

Duplicate detection must use the same canonical identity function as persistent membership, not buffer names or raw `buffer-file-name` equality. This preserves the existing symlink invariant and handles multiple path spellings consistently.

If more than one live buffer already represents an identity, restoration opens no additional buffer and the existing cache synchronization updates every duplicate. This plan does not otherwise change the current duplicate-buffer policy.

## Refresh batching

Opening several files runs `find-file-hook` several times. The current hook forces a global tab-line refresh for every visit, which would make startup restoration perform avoidable repeated redisplay work.

Add a dynamically scoped restore/batch flag understood by `ri-tabs--refresh`:

- while restoration is active, refresh requests only mark a pending refresh;
- activation performs one `tab-line-force-update` after all files and caches have been processed;
- outside restoration, existing immediate refresh behavior remains unchanged;
- cleanup uses `unwind-protect` so an error or quit cannot leave refreshes deferred globally.

Do not move persistent reads into tab rendering or cache-key generation.

## Reentrancy and idempotence

Use explicit internal pending and active guards so that:

- repeated `ri-tabs-mode 1` calls do not schedule multiple startup callbacks;
- a startup callback and an interactive enable cannot run restoration concurrently;
- recursive user hooks triggered by `find-file-noselect` cannot start a second restore pass;
- rerunning restoration after completion opens nothing when every identity already has a live buffer;
- disabling the mode clears pending work but does not alter persistent marks or kill restored buffers.

Restoration is intentionally performed once per mode activation. `kill-buffer-hook` must remain refresh-only and must not schedule a reopen. Otherwise closing a marked tab would immediately recreate it and make the close command unusable.

## Concurrency

Restoration reads the latest synchronized state at activation and performs no membership writes, so it cannot overwrite marks written by another Emacs process.

A concurrent process can change membership after the activation snapshot. The current process may then open a buffer based on the older snapshot, but final cache synchronization must use the validated activation state without committing it. A later semantic read or explicit mark mutation will observe the synchronized store as it does today. Do not add last-writer-wins writes merely to “confirm” restored files.

## Error handling

Automatic restore failures must not abort normal Emacs startup.

- A state read or schema error: emit the existing persistence warning, open nothing automatically, write nothing.
- A missing path: skip it, retain its mark, and include it in the restore warning.
- A file or TRAMP error: retain the mark, record the original error, and continue with other files.
- A buffer whose resolved identity differs from the stored identity: keep both storage and any user-created buffer untouched, warn, and continue.
- A multisession initialization write failure: retain the current UI/cache failure semantics and do not claim successful initialization.
- A user quit: stop the pass, preserve state, clear internal guards, and respect the quit.

Do not automatically prune missing paths. They may refer to removable media, temporarily unavailable mounts, or TRAMP hosts and should be retried on a later mode activation or Emacs restart.

## Command behavior

No public keybinding changes are required.

- `e k` still toggles persistent membership for the current live file.
- `e n` still kills the current buffer without unmarking it. The file stays closed for the rest of the current activation unless opened explicitly, but it will be restored on the next activation.
- `e i` still atomically removes every persistent mark except the current marked file.
- `e j`, `e l`, `e y`, and `e p` still navigate live marked buffers; startup restoration expands that live set.

No change is required in `ri.el`; `ri-enable` already enables `ri-tabs-mode`.

## Files to change during implementation

### `ri-tabs/ri-tabs.el`

- add pending, active, and refresh-batching state;
- split infrastructure installation from persistent-state activation;
- schedule activation on `emacs-startup-hook` when enabled during init;
- cancel pending activation on mode disable;
- add canonical live-buffer indexing and marked-file restoration helpers;
- open missing available marked files with `find-file-noselect`;
- aggregate per-file restore warnings;
- preserve current buffer and selected-window state;
- perform one final refresh;
- update package commentary and mode/function docstrings to describe startup reopening.

### `ri-tabs/ri-tabs-test.el`

- extend persistence fixtures to track and kill buffers created automatically by restore;
- add behavior tests listed below;
- retain isolated `multisession-directory` and synthetic non-nil `user-init-file` bindings;
- continue using real temporary files for file identity and existence checks.

### `README.md`

Replace the statement that closed marked files are never reopened automatically. Document that:

- marked files are reopened automatically when Ki tabs activates after restart;
- closing a marked buffer does not immediately reopen it;
- the still-marked file returns on the next mode activation or Emacs restart;
- explicitly unmarking a file prevents future automatic restoration;
- unavailable paths remain marked and are retried later.

### `ri-tabs/PERSISTENT-MARKS-PLAN.md`

Keep the original plan as historical design context. Do not silently rewrite it. This document explicitly records the changed reopening decision.

## Test strategy

Add tests for observable behavior rather than implementation text or private flag values.

1. **Restore two marks without explicit visits**  
   Persist two real file identities, enable the mode, and assert that both now have live marked buffers and both appear in `ri-tabs--marked-buffer-list`.

2. **Fresh multisession object restores all marks**  
   Write two marks, replace the multisession object with a fresh synchronized object using the same directory and key, kill both buffers, enable the mode, and assert that both are reopened from disk state.

3. **Startup-deferred restore**  
   Simulate enabling before initialization completes. Assert that restoration is deferred, invoke the startup callback, and assert that every marked file is opened exactly once.

4. **Immediate post-startup restore**  
   Enable after initialization and assert that missing marked buffers are restored before the enable call returns.

5. **Already-live buffers are reused**  
   Open one of two marked files before activation. Assert that its buffer object is unchanged and only the missing identity receives a new buffer.

6. **Idempotent activation**  
   Run the activation helper twice and assert that the second pass creates no buffers and leaves the marked-buffer set unchanged.

7. **Selected buffer and window are preserved**  
   Start from an unrelated live buffer and window configuration, restore multiple marks, and assert that selection, displayed buffer, point, and window configuration are unchanged.

8. **Close does not immediately reopen**  
   Restore a marked file, kill its buffer while the mode remains enabled, and assert that it stays closed until the mode is disabled and enabled again.

9. **Re-enable restores a closed mark**  
   After the previous close, re-enable the mode and assert that the file returns as a marked tab.

10. **Explicit unmark prevents restoration**  
    Unmark a file, kill its buffer, re-enable the mode, and assert that no buffer is created for it.

11. **Empty initialized state opens nothing**  
    Store `(:version 1 :files nil)`, enable the mode, and assert that existing files are not seeded or reopened.

12. **First enable initializes once at the activation boundary**  
    With uninitialized storage and files opened during startup setup, run deferred activation and assert that all current visible file buffers are stored in one write.

13. **Missing file is retained without a phantom buffer**  
    Store one existing and one missing identity. Assert that the existing file opens, no new-file buffer is created for the missing path, one warning is emitted, and both identities remain in storage.

14. **One open failure does not block later files**  
    Make visiting one stored identity signal and assert that identities after it are still restored and the state remains unchanged.

15. **Malformed state opens and writes nothing**  
    Store an unsupported schema, enable the mode, assert a warning, and verify that no marked path is visited and the malformed value is unchanged.

16. **Canonical duplicate is not reopened**  
    Visit a file through a symlink or duplicate visiting buffer, restore its canonical stored identity, and assert that no additional file buffer is created and every live duplicate has the same mark cache.

17. **Deferred restore is canceled by disable**  
    Enable before startup, disable before the callback, invoke the startup hook, and assert that no marked file is opened.

18. **Refreshes are batched**  
    Restore multiple real files and assert one observable final global refresh rather than one per restored file.

Existing persistence, navigation, rendering, rename, non-file rejection, and malformed-schema tests must continue to pass.

## End-to-end verification

### Two-process batch smoke test

Use one temporary multisession directory and two real files.

Process A:

1. bind a non-nil synthetic `user-init-file`;
2. enable `ri-tabs-mode` with an isolated synchronized file-backed store;
3. visit and mark both files;
4. assert that the persisted `:files` list contains both canonical identities;
5. exit.

Process B:

1. use a fresh multisession object with the same directory, package, and key;
2. enable `ri-tabs-mode` without explicitly visiting either marked file;
3. assert that both identities have live buffers;
4. assert that both buffers are marked;
5. assert that `ri-tabs--marked-buffer-list` contains both identities;
6. assert that the selected startup buffer did not change.

The smoke test fails if it merely proves that marks remain in storage; it must prove automatic buffer restoration and tab-list membership.

### Interactive smoke test

1. Start Emacs with Ri enabled.
2. Open two existing files and mark both with `e k`.
3. Confirm both appear as marked tabs.
4. Exit Emacs normally.
5. Start a new Emacs process without passing either file on the command line.
6. Enter any restored file buffer and confirm that both marked files are present in the tab line.
7. Close one with `e n` and confirm it stays closed for the current activation.
8. Restart Emacs and confirm that the still-marked file returns.
9. Explicitly unmark that file, restart again, and confirm that it no longer returns.

## Risks and decisions

### Startup cost

Opening marked files performs real file I/O and runs normal file hooks. This can lengthen startup, especially for many files or TRAMP identities. That cost follows directly from the requested behavior. Restoration runs after normal command-line processing, reuses already-live buffers, batches tab refreshes, and isolates failures; do not add asynchronous partial restoration unless synchronous startup becomes demonstrably unusable.

### Remote files

Persistently marked TRAMP identities are explicit user choices and should be attempted like local identities. They may prompt or block according to normal TRAMP behavior. Errors retain the mark for a later retry. Do not silently exclude remote identities, because that would recreate the same “stored but absent” behavior for part of the marked set.

### Missing files

Calling `find-file-noselect` on a missing local path would create a new empty visiting buffer. The restore must therefore check existence first. A missing mark stays stored but does not become a misleading empty tab.

### Desktop overlap

Desktop may already restore some or all marked files. Canonical live-buffer indexing makes Ki restoration complementary and idempotent: Desktop restores its session state, then Ki opens only marked identities still missing.

### Intentional close

Reopening from `kill-buffer-hook` would make marked tabs impossible to close. Restoration therefore occurs only at a mode activation boundary, not continuously. Closing and unmarking remain distinct operations, but a still-marked close is intentionally temporary across restarts.

## Acceptance criteria

- [ ] Persisting marks for two existing files and starting a fresh Emacs process opens both without explicit file visits.
- [ ] Both restored buffers are marked and appear in the Ki marked-tab list.
- [ ] Already-live canonical identities are reused without duplicate buffers.
- [ ] Restoration does not change the selected buffer or window configuration.
- [ ] Killing a marked buffer does not immediately reopen it.
- [ ] A still-marked closed file returns on the next mode activation or Emacs restart.
- [ ] Explicitly unmarked files are not restored.
- [ ] Missing or unavailable paths remain stored, create no phantom buffers, and do not block other restores.
- [ ] Malformed storage is neither opened nor overwritten automatically.
- [ ] Restoration performs no persistent membership write except first-use initialization.
- [ ] First-use initialization still captures files live at the activation boundary in one write.
- [ ] Startup restoration is deferred when the mode is enabled from the init file and canceled if the mode is disabled first.
- [ ] Multiple restored files trigger one final tab-line refresh.
- [ ] Existing mark, unmark, rename, duplicate-buffer, rendering, and navigation contracts remain valid.
- [ ] The complete `ri-tabs-test.el` suite passes.
- [ ] A two-process smoke test proves both disk persistence and automatic restoration of multiple marked tabs.
