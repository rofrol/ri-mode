# Ri Tabs Owner Context and Persistent Error Message Fix Plan

## Goal

Fix three related `ri-tabs` behaviors:

1. A failed mark operation must leave its explanatory message visible long enough to read instead of disappearing on the following Kitty key-release event.
2. Git repositories configured through `GIT_DIR` / `GIT_WORK_TREE` must be recognized as repository contexts even when there is no physical `.git` entry under the visited file's directory.
3. A marked-tab set must also work outside Git. When no Git repository can be resolved, the set is owned by the current directory instead of rejecting the operation.

The resulting ownership model is therefore no longer "repository-only". It becomes a general **owner context**:

```text
Git-backed file    -> Git work-tree root owns the marked set
non-Git file       -> current/default directory owns the marked set
```

Once a marked set has an owner, opening or marking files elsewhere must continue to add them to that same active set until the user explicitly switches owner context. This preserves the existing cross-repository marked-set behavior.

---

## 1. Preserve Marking Errors Across Kitty Key Release

### Current problem

`ri-tabs--owner-for-mark` currently raises a `user-error` when no repository can be found:

```elisp
(user-error "Cannot start a marked set outside a Git repository")
```

The error reaches the echo area, but RI/KKP processes the following key-release event. That event can overwrite or clear the message almost immediately.

`ri.el` already contains the mechanism needed to solve this:

```elisp
ri--call-preserving-user-error
ri--restore-message-after-release
ri--restore-message-until-command-end
```

It is already used by commands such as `ri-set-node-mode` and `ri-parent-line`.

### Planned change

Do not add a second message-preservation implementation inside `ri-tabs`.

Instead, route interactive tab-mark commands invoked from RI through the existing RI wrapper.

Add thin RI commands, conceptually:

```elisp
(defun ri-toggle-buffer-mark ()
  (interactive)
  (ri--call-preserving-user-error #'ri-tabs-toggle-buffer-mark))
```

If other tab commands can produce user-facing errors from the same momentary/chord layer, wrap those commands consistently as well.

Change the RI keymap/menu binding for `Mark File` from:

```elisp
ri-tabs-toggle-buffer-mark
```

to the RI wrapper.

### Required behavior

After a failed marking operation:

```text
press mark key
-> error message appears
release key
-> the same message is restored and remains readable
```

The wrapper must preserve the original `user-error` semantics so callers and tests still see a `user-error`; it must not convert errors into ordinary `message` calls.

### Important adjustment caused by problem 3

After non-Git directory ownership is implemented, "not inside a Git repository" will no longer be a valid mark failure for ordinary file buffers.

The persistent-message test should therefore use a remaining genuine mark error, for example:

```text
Buffer is not visiting a visible file
```

or another explicitly unsupported buffer case.

This verifies the UI bug independently of the new owner-context behavior.

---

## 2. Replace `.git` Directory Scanning with Git-Aware Context Resolution

### Current problem

`ri-tabs--buffer-repo` currently uses:

```elisp
(locate-dominating-file file-id ".git")
```

This only detects repositories represented by a `.git` file/directory in the filesystem hierarchy.

It does not model Git's actual repository discovery rules and therefore misses setups such as:

```sh
export GIT_DIR="$DOTFILES_HOME"
export GIT_WORK_TREE="$HOME"
```

where the work tree is `$HOME`, but the Git directory is stored elsewhere.

### Planned resolver

Introduce one authoritative Git-context resolver based on Git itself rather than filesystem heuristics.

Conceptually:

```elisp
(ri-tabs--git-work-tree-root directory)
```

It should run Git with `default-directory` set to the buffer's directory and ask Git for the effective work-tree root, for example using:

```text
git rev-parse --show-toplevel
```

The subprocess must inherit Emacs' current `process-environment`, which means Git will naturally respect:

```text
GIT_DIR
GIT_WORK_TREE
GIT_CEILING_DIRECTORIES
GIT_DISCOVERY_ACROSS_FILESYSTEM
```

and Git worktree metadata.

Normalize a successful result through the existing canonical-directory helper.

### Why Git itself should be authoritative

This correctly handles more cases than `locate-dominating-file`:

- ordinary `.git/` repositories,
- `.git` indirection files used by Git worktrees,
- external `GIT_DIR`,
- explicit `GIT_WORK_TREE`,
- symlink/canonical-path normalization after Git resolves the context.

It also avoids duplicating Git repository-discovery semantics in Elisp.

### Performance

Do not run Git repeatedly during every tab-bar redraw.

Repository/context discovery should happen only at ownership/context decision points, such as:

- establishing an owner for the first mark,
- explicit owner switching,
- startup activation for the current buffer/context,
- possibly file/context hooks where owner resolution is genuinely needed.

Rendering and marked-status checks must continue to operate from the already established frame owner and persistent state.

If profiling later shows repeated resolution for the same directory, add a small canonical-directory -> Git-root cache with explicit invalidation or session-local semantics. Do not introduce caching before correctness tests exist.

### Environment visibility caveat

`GIT_DIR` and `GIT_WORK_TREE` can only influence Git subprocesses if those variables exist in **Emacs' own environment**.

A shell function executed after an already-running Emacs process starts cannot mutate that Emacs process environment.

Therefore the implementation should:

- correctly honor `GIT_DIR` / `GIT_WORK_TREE` when Emacs inherited them or they were set inside Emacs,
- document/test this fact rather than trying to read the state of an unrelated interactive shell process.

For the supplied `don()` workflow, a test should explicitly bind `process-environment` to equivalents of:

```text
GIT_DIR=<external dotfiles git dir>
GIT_WORK_TREE=<home/work-tree directory>
```

and verify that a file under the work tree resolves to the work-tree root.

---

## 3. Generalize Repository Ownership into Owner Context Ownership

### New rule

When the first file is marked and the frame has no active owner:

```text
try to resolve effective Git work-tree root

if Git root exists:
    owner = Git work-tree root
else:
    owner = current directory
```

There must no longer be a `Cannot start a marked set outside a Git repository` failure for a normal visible file buffer.

### Meaning of "current directory"

For a visited file, use the buffer's effective `default-directory`, canonicalized with `file-truename` / `expand-file-name` and normalized as a directory.

Do **not** use the file's parent path by string manipulation if `default-directory` already represents the buffer's working context. This preserves Emacs semantics for buffers whose working directory has been intentionally changed.

Provide a helper such as:

```elisp
(ri-tabs--buffer-directory buffer)
```

which returns a canonical directory or signals an appropriate error if no usable directory exists.

### Unified helper

Replace repository-only resolution with a general helper, conceptually:

```elisp
(ri-tabs--buffer-owner-context buffer)
```

with logic:

```text
buffer directory
    |
    +-> Git says it belongs to a work tree -> canonical Git work-tree root
    |
    `-> otherwise                         -> canonical buffer directory
```

`ri-tabs--owner-for-mark` should depend on this helper rather than directly on `ri-tabs--buffer-repo`.

---

## 4. Preserve Existing "First Context Owns the Set" Semantics

The new directory fallback must not accidentally make ownership follow every opened file.

Required invariant:

```text
owner is established only when there is no active owner
```

Example:

```text
~/plain-dir/a.txt
mark
```

establishes:

```text
owner = ~/plain-dir/
marked = [~/plain-dir/a.txt]
```

Then:

```text
open ~/other-dir/b.txt
mark
```

must produce:

```text
owner = ~/plain-dir/
marked = [~/plain-dir/a.txt, ~/other-dir/b.txt]
```

It must **not** switch the owner to `~/other-dir/`.

Likewise:

```text
open ~/plain-dir/a.txt
mark
open /repo-B/b.el
mark
```

must keep the directory owner established by the first mark.

And the inverse must also remain valid:

```text
open /repo-A/a.el
mark
open ~/plain-dir/b.txt
mark
```

must keep `/repo-A/` as owner.

---

## 5. Rename Repository-Specific Internal Concepts Where Necessary

The current persistent model uses repository-specific names such as:

```elisp
ri-tabs--frame-owner-repo
ri-tabs--set-frame-owner-repo
ri-tabs--state-owner-files
:repos
ri-tabs--restored-owner-repos
```

After directory ownership is legal, names that imply every owner is a Git repository become misleading.

### Preferred cleanup

Rename internal concepts toward `owner` / `context`, for example:

```elisp
ri-tabs--frame-owner
ri-tabs--set-frame-owner
ri-tabs--owner-for-buffer
ri-tabs--restored-owners
```

The frame parameter should similarly become something like:

```text
ri-tabs-owner
```

rather than `ri-tabs-owner-repo`.

### Persistent schema

The persistent state currently uses version 2 and stores owner-path -> file-list entries under `:repos`.

Because directory owners are also canonical absolute directory strings, the storage shape can remain fundamentally the same, but the schema should no longer call them repositories.

Prefer a version-3 schema:

```elisp
(:version 3
 :owners (("/canonical/context/" . ("/file/a" "/file/b")) ...)
 :unresolved (...))
```

This makes the persisted meaning explicit and prevents future code from assuming that each key must pass a Git-repository check.

Migration from v2 is lossless:

```text
v2 :repos entries
-> same canonical owner paths under v3 :owners
```

No regrouping is required.

Legacy v1 migration should use the new owner resolver where practical. If an old set's first valid file resolves to Git, use its Git root; otherwise use that file buffer/path's directory context rather than leaving the state permanently unresolved solely because it is outside Git.

If implementing a schema bump would make the patch disproportionately large, it is acceptable to keep the v2 physical representation temporarily, but all runtime semantics must treat keys as generic owner contexts and a follow-up schema cleanup must be documented. The preferred implementation is the clean v3 migration.

---

## 6. Explicit Context Switching Must Also Work Outside Git

`ri-tabs-switch-repository` currently rejects a buffer outside Git.

After generalizing ownership, provide an explicit context-switch command with context semantics, preferably renamed to:

```elisp
ri-tabs-switch-context
```

Behavior:

```text
inside Git -> switch to effective Git work-tree owner
outside Git -> switch to canonical current-directory owner
```

For compatibility, `ri-tabs-switch-repository` may remain as an alias if it is already user-facing, but its old name should not define the internal model.

Opening a file must still never switch owner implicitly.

---

## 7. Startup and Lazy Restoration

`ri-tabs--activate-existing-owner-for-frame` currently activates a persisted set only when the selected buffer resolves to a repository.

Update activation to resolve a generic owner context:

```text
selected buffer
-> effective Git work-tree root, if any
-> otherwise current directory
-> if persistent state contains that owner, activate it
```

This enables persistent non-Git directory sets to restore when Emacs starts in or opens that context.

Lazy restoration semantics must remain unchanged:

- activate only the current owner context,
- do not restore every saved owner at startup,
- track restored contexts independently,
- files inside an owner set may still live anywhere.

---

## 8. Tests

Add focused ERT coverage before or together with implementation.

### A. `GIT_DIR` / `GIT_WORK_TREE`

Create a temporary external Git directory and separate work tree, or initialize a suitable temporary repository and arrange the test environment so that:

```text
GIT_DIR=<external git dir>
GIT_WORK_TREE=<work tree>
```

Bind `process-environment` for the test.

Visit a file in the work tree.

Expected:

```text
ri-tabs owner == canonical GIT_WORK_TREE
```

The test must not rely on a `.git` file/directory being present under the work tree.

### B. Normal Git repository regression

Visit a file in an ordinary repository.

Expected:

```text
owner == canonical repository top-level
```

This protects normal `.git` discovery after replacing `locate-dominating-file`.

### C. Git worktree regression

Where feasible, test a linked Git worktree whose `.git` is an indirection file.

Expected:

```text
owner == linked worktree top-level
```

### D. Non-Git first mark

Visit:

```text
/tmp/plain/a.txt
```

with no Git repository.

Mark it.

Expected:

```text
owner == canonical buffer default-directory
file is marked
no user-error
```

### E. Non-Git owner remains stable across directories

```text
open /plain-A/a.txt
mark
open /plain-B/b.txt
mark
```

Expected:

```text
owner == /plain-A/
owner's set contains both files
```

### F. Directory owner remains stable when later file is in Git

```text
open /plain/a.txt
mark
open /repo/b.el
mark
```

Expected:

```text
owner == /plain/
```

### G. Git owner remains stable when later file is outside Git

```text
open /repo/a.el
mark
open /plain/b.txt
mark
```

Expected:

```text
owner == /repo/
```

### H. Explicit context switch outside Git

With a saved set owned by `/plain-B/`, invoke the explicit context-switch command while visiting a file whose directory is `/plain-B/`.

Expected:

```text
active owner becomes /plain-B/
its marked files are lazily restored
```

### I. Persistent non-Git owner restore

Persist a directory-owned set, disable/re-enable or simulate startup activation in that directory.

Expected:

```text
directory-owned set becomes active and restores correctly
```

### J. Message survives key release

Exercise the RI wrapper around a tab command that raises `user-error`.

Verify:

```text
ri--restore-message-after-release
```

contains the error text and that running the KKP release-restoration hook re-emits the same message.

Use a remaining legitimate failure such as attempting to mark a non-file buffer, not the removed "outside Git" error.

### K. Persistence migration

If state version 3 is introduced:

- v2 `:repos` entries migrate unchanged into v3 `:owners`,
- owner paths remain canonical,
- marked files remain associated with the same owner,
- directory-owned v3 entries round-trip through `multisession`.

---

## 9. Suggested Implementation Order

1. Add tests for the current failures: external `GIT_DIR`/`GIT_WORK_TREE`, non-Git first mark, and disappearing RI user errors.
2. Add canonical buffer-directory resolution.
3. Add Git-based work-tree resolution using a Git subprocess.
4. Add the unified `buffer -> owner context` resolver.
5. Change first-mark behavior to fall back to the current directory rather than reject non-Git files.
6. Generalize frame owner and startup activation from repository-only to owner-context semantics.
7. Generalize explicit switching so non-Git directory contexts are selectable.
8. Migrate persistent naming/schema from repositories to generic owners, preferably v2 -> v3.
9. Add the RI wrapper for tab mark/toggle errors and update its key binding.
10. Run the complete `ri-tabs` test suite plus RI/KKP interaction tests to catch regressions.

---

## 10. Acceptance Criteria

The patch is complete when all of the following are true:

```text
1. RI errors raised while marking remain visible after the triggering key is released.

2. A file under a work tree configured through GIT_DIR/GIT_WORK_TREE is recognized
   as belonging to that Git work tree even without a local .git entry.

3. Marking the first normal file outside Git succeeds.

4. That non-Git marked set is owned by the buffer's canonical current/default directory.

5. The first established owner context remains the owner while additional files from
   other directories or repositories are marked.

6. Explicit context switching works for both Git roots and ordinary directories.

7. Persistent/lazy restoration works for both kinds of owner.

8. Existing ordinary Git repository, cross-repository marking, navigation, rename,
   multiple-frame, and persistence behavior continues to pass its regression tests.
```

## Final Model

The user-visible mental model should become:

```text
A marked-tab list belongs to the context where it was started.

If that context is inside Git, the owner is Git's effective work-tree root.
If it is not inside Git, the owner is the current directory.

Files added later may come from anywhere.
Opening another file never changes the active owner by itself.
```
