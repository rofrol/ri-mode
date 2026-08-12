# Persistent Ki Tab Marks — Implementation Plan

## Goal

A file marked through Ri's Buffer layer (`e k`) must remain marked after its buffer is killed and the file is opened again. The mark must also survive an Emacs restart.

This feature remembers marks; it does not automatically reopen closed files.

## Current behavior

Ri already maps the relevant keys correctly:

- `e k` calls `ri-tabs-toggle-buffer-mark`.
- `e n` calls `kill-current-buffer`.
- `e i` calls `ri-tabs-unmark-other-buffers`.

The state is currently held only in the buffer-local variable `ri-tabs--marked-p`. Killing a buffer destroys that value. `find-file-hook` installs the tab-line UI but does not restore the mark, and there is no persistent file identity.

The underlying problem is that the state belongs to a transient buffer object even though the user-facing operation is "Mark File".

## Decision

Use Emacs's built-in `multisession.el` as the persistence layer.

Ri requires Emacs 31.1 or newer, while multisession variables have been available since Emacs 29.1. The API provides:

- package-owned persistent values without requiring a global user mode;
- immediate writes through `(setf (multisession-value ...))`;
- a file backend under `user-emacs-directory/multisession/` by default;
- an optional SQLite backend selected through `multisession-storage`;
- synchronized reads for changes made by another Emacs process;
- temporary-file-plus-rename writes in the default file backend.

Do not add a custom session file, depend on `savehist-mode`, or register `ri-tabs--marked-p` in `desktop-locals-to-save`.

## Behavioral contract

1. Marking file `F` with `e k` persists the mark immediately.
2. Killing its buffer—through `e n`, `kill-buffer`, or the tab close action—does not remove the persistent mark.
3. Opening `F` again in the same Emacs process restores its marked state.
4. Opening `F` after restarting Emacs restores its marked state.
5. Pressing `e k` on a marked file explicitly removes the persistent mark.
6. `ri-tabs-unmark-buffer` removes the persistent mark.
7. `e i` removes all other persistent marks, including marks for files that currently have no live buffer.
8. Renaming or using Save As on a marked, visited file moves the mark from the old identity to the new identity.
9. Closed marked files are not displayed and are not opened by marked-buffer navigation. Existing `e j`, `e l`, `e y`, and `e p` navigation continues to operate on live marked buffers only.
10. A missing or temporarily unavailable file remains in persistent storage. Do not automatically prune paths, because they may refer to TRAMP files, removable volumes, or temporarily unavailable mounts.
11. Non-file buffers remain unmarkable and continue to signal the existing user error.

This deliberately differs from upstream Ki's close behavior. Ki stores marked paths in a workspace session, but closing a Ki window explicitly unmarks its file. Ri's requested contract treats close and unmark as separate operations.

## Scope

Marks remain global within Emacs, matching the existing implementation, which gathers marked buffers from the global `buffer-list`. Do not introduce project-local scoping as part of this change.

A project-scoped option could be designed separately, but it would alter current navigation and tab-list semantics.

## Persistent data model

Add a multisession object in `ri-tabs/ri-tabs.el`:

```elisp
(require 'multisession)

(define-multisession-variable ri-tabs--marks-store nil
  "Persistent Ki tab marks."
  :package "ri-tabs"
  :synchronized t)
```

Persist a small, versioned, printable value:

```elisp
(:version 1
 :files ("/canonical/path/a.el"
         "/canonical/path/b.el"))
```

Storage invariants:

- every file identity is a string;
- identities are unique;
- identities are kept in deterministic lexical order;
- the initial multisession value `nil` means that Ki tabs have never initialized persistent state;
- `(:version 1 :files nil)` means that the user has explicitly left no files marked;
- callers use non-destructive list operations so that the cached multisession value is not mutated before a successful write;
- malformed or unsupported versions are not silently overwritten by automatic hooks.

The distinction between uninitialized `nil` and an initialized empty state preserves the current first-enable behavior without re-marking files after the user has explicitly unmarked everything.

## File identity

Use the expanded `buffer-file-truename` as the persistent identity. Fall back to an expanded `buffer-file-name` only when the truename is unavailable.

Do not use buffer names: they are not stable between sessions. Do not store buffer objects: they are not printable or reopenable identities.

Using `buffer-file-truename` means that opening a file through a symlink and opening its real path refer to the same mark. Emacs has already calculated this value for a normal file-visiting buffer, so tab rendering does not need additional filesystem access.

Marks therefore become file-level state. If multiple live buffers visit the same file identity, they must show the same marked state.

## In-memory state

Keep `ri-tabs--marked-p`, but redefine its role: it is a buffer-local render cache, not the source of truth.

Add a second buffer-local value, such as `ri-tabs--file-id`, to remember the identity last synchronized for that buffer. It is required to migrate a mark when `after-set-visited-file-name-hook` runs after a rename or Save As operation.

The tab-line rendering and cache-key paths must continue to read only `ri-tabs--marked-p`. They must not read multisession storage or perform filesystem work during redisplay.

## Read and write lifecycle

### Reading

Read persistent state only at semantic boundaries:

- when `ri-tabs-mode` is enabled;
- when a file is visited;
- when a visited filename changes;
- immediately before an explicit mark mutation.

With `:synchronized t`, these reads can observe a newer value written by another Emacs process.

### Writing

Every explicit mutation should follow this order:

1. Validate that the target is a visible file buffer.
2. Determine its stable file identity.
3. Read and validate the latest persistent state.
4. Compute a new immutable state value.
5. Persist it with `(setf (multisession-value ri-tabs--marks-store) new-state)`.
6. Only after a successful write, update `ri-tabs--marked-p` in every live buffer with the affected file identity.
7. Force one tab-line refresh.

A failed persistence write must not leave the UI claiming that the operation succeeded.

No write occurs from `kill-buffer-hook`.

## Mode initialization

Change `ri-tabs--enable` as follows:

- If the persistent value is uninitialized (`nil`), collect all currently open visible file buffers, mark them, and persist a version-1 state in one write. This preserves the documented current behavior for the first enable.
- If a valid state already exists, initialize every live file buffer from that state instead of marking all existing buffers unconditionally.
- A newly visited file starts unmarked unless its identity is already present in persistent state.
- Disabling the mode removes the Ki tab-line configuration and buffer-local caches but leaves the persistent store untouched.
- Re-enabling the mode restores the stored state and must not reseed an explicitly empty state.

## Hook responsibilities

The current `ri-tabs--sync-current-buffer` is used for multiple events with different semantics. Split or parameterize those responsibilities so that a major-mode change cannot be mistaken for a newly opened or renamed file.

### `find-file-hook`

- compute and remember the file identity;
- restore `ri-tabs--marked-p` from persistent state;
- install the Ki tab-line configuration.

### `after-set-visited-file-name-hook`

- compare the remembered identity with the new identity;
- if the old identity was persistently marked, replace it with the new identity in one write;
- if the old identity was unmarked but the new identity is already stored, mark the buffer;
- deduplicate the state if the destination was already marked;
- update every live buffer affected by the old or new identity;
- install or remove the tab-line UI according to the buffer's new role.

If a buffer stops visiting a file, retain the old file's persistent mark. The old file should still be marked if opened again.

### `after-change-major-mode-hook`

Only install or restore the tab-line configuration. Do not reinterpret or rewrite the persistent mark.

### `kill-buffer-hook`

Only invalidate tab lines. Do not remove a persistent identity.

## Command changes

### `ri-tabs-mark-buffer`

Add the current file identity to persistent state, write it, synchronize all live buffers for that identity, and refresh once.

### `ri-tabs-unmark-buffer`

Remove the identity from persistent state, write it, synchronize all live buffers for that identity, and refresh once.

### `ri-tabs-toggle-buffer-mark`

Read the latest persistent state and invert membership there. Do not invert a potentially stale buffer-local cache.

### `ri-tabs-unmark-other-buffers`

Do not iterate only over live buffers. Replace the persistent file list atomically with:

- the current identity only, if the current file is persistently marked;
- an empty list, if the current file is unmarked.

Then synchronize all live file buffers and refresh once.

## Error handling

Automatic hooks must not make `find-file` unusable because persistence data cannot be read. On a read or schema error:

- report a `ri-tabs` warning with the original error;
- leave the affected buffer unmarked for that synchronization attempt;
- do not automatically overwrite the unreadable state.

Interactive mark mutations should surface write failures and leave buffer-local state unchanged.

The version validator should reject unknown schemas explicitly. A future schema change can then migrate version 1 rather than guessing the shape of old data.

## Files to change

### `ri-tabs/ri-tabs.el`

- require `multisession`;
- define and validate the persistent state;
- add stable file-identity helpers;
- add state read, normalization, and commit helpers;
- retain `ri-tabs--marked-p` as a render cache;
- add the last-synchronized file identity;
- make mark, unmark, toggle, and unmark-others persistent;
- synchronize duplicate buffers visiting the same file;
- split hook responsibilities;
- migrate marks on visited-file renames;
- preserve marks across buffer kills and mode disable;
- update command and mode docstrings.

### `ri-tabs/ri-tabs-test.el`

Add isolated persistence fixtures and behavioral tests described below.

Existing rendering and navigation unit tests may continue to bind `ri-tabs--marked-p` directly when persistent behavior is not under test.

### `README.md`

Document that:

- file marks survive buffer closure and Emacs restarts;
- closing a file does not unmark it;
- only explicit mark commands change persistent membership;
- marked-buffer navigation still considers live buffers only.

### No change required in `ri.el`

The Buffer-layer keybindings already target the correct public Ki tabs commands.

## Test strategy

Tests involving persistence must isolate themselves from the user's real state:

- bind `multisession-directory` to a temporary directory;
- bind `user-init-file` to a non-nil synthetic value, because multisession intentionally avoids backend storage when `user-init-file` is nil;
- bind `ri-tabs--marks-store` to a fresh `make-multisession` object using the file backend;
- create real temporary files rather than assigning fake `buffer-file-name` values;
- disable `ri-tabs-mode`, kill temporary buffers, and remove temporary files during cleanup.

Add tests for these observable contracts:

1. **Kill and reopen in one process**  
   Mark a late-opened file, kill its buffer, reopen it, and assert that it is marked.

2. **Reload from disk**  
   Mark a file, replace the multisession object with a fresh object using the same directory and key, reopen the file, and assert that it is marked.

3. **Persistent unmark**  
   Mark, unmark, kill, and reopen; assert that the file remains unmarked.

4. **Unmark Others includes closed files**  
   Mark two files, kill one buffer, invoke `ri-tabs-unmark-other-buffers` from the other, reopen the closed file, and assert that it is unmarked.

5. **Rename migration**  
   Mark a file, rename or Save As through Emacs, kill the buffer, and verify that the new identity is marked while the old identity is not.

6. **Mode re-enable does not reseed**  
   Persist an initialized empty state, disable and re-enable `ri-tabs-mode`, and assert that already open files remain unmarked.

7. **First enable preserves current behavior**  
   With uninitialized storage, enable the mode and assert that existing file buffers are marked and persisted in a single initialized state.

8. **Symlink identity**  
   Mark a file through a symlink, reopen it through its real path, and assert that the mark is restored.

9. **Duplicate buffers share state**  
   Create two buffers visiting the same identity, toggle one, and assert that both caches agree.

10. **Non-file rejection**  
    Assert that mark commands retain the existing user error for non-file buffers.

11. **Malformed schema does not get overwritten automatically**  
    Store an unsupported value, open a file, assert that opening succeeds with a warning, and verify that storage is unchanged.

## End-to-end verification

After implementation:

1. Run the complete `ri-tabs-test.el` suite.
2. Run a smoke test using two separate batch Emacs processes and one temporary multisession directory:
   - process A opens and marks a file, then exits;
   - process B opens the same file and asserts `ri-tabs-buffer-marked-p` is non-nil.
3. Exercise the real Ri interaction:
   - open a file;
   - press `e k`;
   - press `e n`;
   - reopen the file;
   - confirm that the tab displays the marked marker.
4. Rename a marked file through Emacs, close it, reopen the new path, and confirm that the mark followed the rename.

The current baseline is seven passing `ri-tabs` tests with no failures.

## Alternatives considered

### `desktop-save-mode`

`desktop.el` can save selected buffer-local variables for live buffers through `desktop-locals-to-save`. It cannot remember a mark for a buffer killed before the desktop is saved, and it would couple this small feature to whole-session restoration. It may still reopen buffers independently; the Ki tabs find-file hook should then restore marks from multisession storage.

### `savehist-additional-variables`

`savehist` can serialize additional global variables, but it requires `savehist-mode`, normally writes on a timer and at Emacs exit, and therefore leaves a crash-loss window. Its implementation also warns that additional variables cannot be merged gracefully across concurrent Emacs sessions.

### `bookmark.el`

Bookmarks are suitable for reconstructing locations and specialized buffers. A Boolean file mark does not require a bookmark record and should not pollute the user's bookmark list.

### `persist.el`

`persist.el` provides variable persistence and is used by packages such as `activities.el`. It would add an external dependency that duplicates functionality already built into the minimum supported Emacs version.

### Custom persistence file

A custom file would duplicate serialization, directory management, atomic-write behavior, synchronization, error handling, and optional SQLite support already supplied by `multisession.el`.

## Risks and explicit decisions

### Concurrent Emacs writers

A synchronized multisession object reloads externally updated values before reads, but the complete mark set remains one last-writer-wins value. Two Emacs processes performing simultaneous read-modify-write operations could still lose one update.

Mitigation:

- use `:synchronized t`;
- read immediately before every mutation;
- keep mutations rare and explicit.

A conflict-free per-file database would require private multisession internals or a custom backend and is disproportionate to this feature.

### `emacs -Q`

When `user-init-file` is nil, `multisession.el` intentionally keeps values only in memory. Normal Ri installation loads from the user's init file and persists normally. Tests and smoke commands must bind a non-nil synthetic `user-init-file`.

### External rename while closed

A file renamed outside Emacs while it has no live buffer cannot be associated reliably with its old stored path. Its old entry remains inert. In-buffer rename and Save As operations are migrated through `after-set-visited-file-name-hook`.

### Storage growth

Only explicitly marked files enter storage. Missing paths are deliberately retained. `e i` clears all stored marks except the current marked file, so no separate pruning command is required for this change.

### Performance

Never read persistent storage from tab rendering or tab cache-key generation. Disk access occurs only on enable, file visit, visited-name change, and explicit mark operations.

## Acceptance criteria

- [ ] `e k` persists a file mark immediately.
- [ ] Killing and reopening a marked file restores the mark.
- [ ] Restarting Emacs and reopening a marked file restores the mark.
- [ ] Closing a buffer does not unmark its file.
- [ ] Explicit unmark persists.
- [ ] `e i` clears marks for closed files as well as live buffers.
- [ ] In-buffer rename or Save As migrates the mark.
- [ ] Multiple buffers for one file cannot disagree about its mark.
- [ ] First enable still marks existing file buffers.
- [ ] Later mode re-enables do not recreate explicitly removed marks.
- [ ] Navigation behavior for live marked buffers is unchanged.
- [ ] Tab rendering performs no persistence I/O.
- [ ] The complete Ki tabs test suite passes.
- [ ] A two-process Emacs smoke test proves disk persistence.

## References

- [GNU Emacs Lisp Reference Manual: Multisession Variables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Multisession-Variables.html)
- [Emacs `multisession.el`](https://github.com/emacs-mirror/emacs/blob/master/lisp/emacs-lisp/multisession.el)
- [Emacs `desktop.el`](https://github.com/emacs-mirror/emacs/blob/master/lisp/desktop.el)
- [Emacs `savehist.el`](https://github.com/emacs-mirror/emacs/blob/master/lisp/savehist.el)
- [Ki persistent marked-file context](https://github.com/ki-editor/ki-editor/blob/master/src/context.rs)
- [Ki versioned workspace persistence](https://github.com/ki-editor/ki-editor/blob/master/src/persistence/_00004.rs)
- [Ki close behavior](https://github.com/ki-editor/ki-editor/blob/master/src/app.rs)
- [`activities.el`](https://github.com/alphapapa/activities.el)
- [GNU ELPA `persist`](https://elpa.gnu.org/packages/persist.html)
