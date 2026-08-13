# Repository-Owned Marked Tabs Plan

## Goal

Make marked-tab sets repository-specific without requiring every marked file to belong to that repository.

The repository of the **first marked file** owns the marked-tab set. After that, files from other repositories—or files outside Git entirely—may be added to the same set.

Example:

```text
open repo-A/a.odin
mark

open repo-B/b.odin
mark
```

Result:

```text
owner: repo-A

marked:
  repo-A/a.odin
  repo-B/b.odin
```

`b.odin` belongs to the marked set owned by `repo-A`; it does not automatically become part of a `repo-B` marked set.

## Core Invariants

1. The first marked file establishes the owner repository.
2. A marked-tab set belongs to its owner repository, not to the repositories of its individual files.
3. Once established, the owner remains stable while working with that marked set.
4. Marked files may come from any Git repository or from outside Git.
5. Opening a file from another repository does not by itself change the owner.
6. Navigating through marked tabs never changes the owner.
7. Mark and unmark operations always operate on the currently active owner's marked set.
8. Different owner repositories may have independent marked sets.
9. The same physical file may belong to more than one owner's marked set.
10. Switching to another marked-set context must be explicit/project-context-driven; it must not be inferred merely from the Git root of the current buffer.

## 1. Persistent Storage

Replace the current global list:

```elisp
(:version 1
 :files (...))
```

with repository-owned sets:

```elisp
(:version 2
 :repos
 (("/repo-A/"
   :files
   ("/repo-A/a.odin"
    "/repo-B/b.odin"
    "/home/user/notes.txt"))

  ("/repo-B/"
   :files
   ("/repo-B/x.odin"
    "/somewhere/y.odin"))))
```

The key `/repo-A/` means:

> the marked-tab set owned by repo-A

It does **not** mean:

> all marked files physically located inside repo-A.

Use names that make this distinction explicit, such as:

```elisp
ri-tabs--owner-files
ri-tabs--marked-set-files
```

rather than ambiguous names such as `ri-tabs--repo-files`.

## 2. Owner Repository

Introduce an explicit owner-repository concept.

Do not derive the owner from the current buffer after the marked set has been established.

The owner should not be a single global variable for the whole Emacs process because different frames may work with different marked sets.

Prefer a frame parameter, exposed through helpers such as:

```elisp
(ri-tabs--frame-owner-repo frame)
(ri-tabs--set-frame-owner-repo frame repo)
```

Conceptually:

```text
Frame 1 -> owner repo-A
Frame 2 -> owner repo-B
```

## 3. Establishing the Owner

If no owner is active and the user marks the current file:

```text
current buffer
    |
    v
Git root
    |
    v
owner repository
```

For example:

```text
current file: /work/compiler/src/main.odin
Git root:     /work/compiler/
```

After the first mark:

```text
owner = /work/compiler/
```

Repository paths should be canonicalized, for example using expanded/truename paths.

Git-root detection should support normal repositories and worktrees; do not assume that `.git` is always a directory.

## 4. Subsequent Marks Preserve the Owner

If:

```text
owner = repo-A
```

and the current file is:

```text
repo-B/foo.el
```

then `ri-tabs-mark-buffer` adds that file to the set owned by repo-A:

```text
repo-A marked set:
  ...
  repo-B/foo.el
```

It must not change the owner to repo-B.

## 5. Opening Another Repository Does Not Change the Owner

This is a central requirement.

Given:

```text
owner repo-A

marked:
  repo-A/a.odin
```

the user may run `find-file` and open:

```text
repo-B/b.odin
```

The owner remains:

```text
repo-A
```

If the user now marks `b.odin`, the result is:

```text
owner repo-A

marked:
  repo-A/a.odin
  repo-B/b.odin
```

Therefore, do not implement logic equivalent to:

```elisp
(setq owner (git-root (current-buffer)))
```

on buffer changes.

## 6. Marked-Tab Navigation Preserves the Owner

Suppose the active set is:

```text
owner repo-A

[A:a.odin] [B:b.odin] [C:c.odin]
```

where the files physically belong to three different repositories.

Moving from `a.odin` to `b.odin` through:

```text
ri-tabs-next
ri-tabs-previous
ri-tabs-first
ri-tabs-last
clicking a marked tab
```

must leave:

```text
owner = repo-A
```

unchanged.

The tab bar must continue to display the repo-A marked set.

## 7. Explicit Context Switching

Do not infer a new marked-set owner merely because the current buffer belongs to another repository.

Switching from the repo-A marked-set context to the repo-B marked-set context should be an explicit operation or be tied to a clear project/workspace transition.

Possible mechanisms include:

```text
ri-tabs-switch-repo
project-switch-project integration
workspace/project activation
new frame initialized from a repository
```

The exact UI can be chosen during implementation, but the invariant is:

```text
opening a file != switching marked-set owner
```

This avoids breaking the required workflow:

```text
open A/a.el
mark
open B/b.el
mark
```

which must produce one set owned by A.

## 8. Marked Status Is a Relation, Not a Buffer Property

A buffer cannot have one globally meaningful `marked-p` value.

The same file may be:

```text
marked in owner A
unmarked in owner B
```

or even:

```text
marked in owner A
marked in owner B
```

Therefore, a buffer-local variable such as:

```elisp
ri-tabs--marked-p
```

must not be the source of truth.

Instead, marked status is the relation:

```text
(owner-repo, file-id)
```

The API should look conceptually like:

```elisp
(ri-tabs--marked-p owner-repo buffer)
```

The persistent owner set is the source of truth. A cache may be added for performance, but it must be owner-aware.

## 9. Mark Operation

`ri-tabs-mark-buffer` should behave as follows:

```text
if owner exists:
    add current file to owner's set

else:
    find Git root of current file
    if root exists:
        establish root as owner
        add current file
    else:
        reject starting a set
```

The first marked file therefore must be inside a Git repository.

## 10. Files Outside Git

Once an owner exists, files outside Git may be added normally:

```text
owner repo-A

marked:
  repo-A/main.odin
  ~/notes/todo.org
  /tmp/debug.log
```

However, if no owner exists and the first file is outside any Git repository, marking should fail with a clear message such as:

```text
Cannot start a marked set outside a Git repository
```

This keeps every persistent set associated with a well-defined repository.

## 11. Unmark Operation

Unmark always operates on the active owner's set.

Example:

```text
owner A:
  A/a.el
  B/b.el

owner B:
  B/b.el
  B/x.el
```

While owner A is active, unmarking `B/b.el` produces:

```text
owner A:
  A/a.el

owner B:
  B/b.el
  B/x.el
```

The repo-B set is untouched.

## 12. Unmark Other Buffers

`ri-tabs-unmark-other-buffers` should modify only the active owner's set.

Before:

```text
owner A:
  a
  b
  c

owner B:
  x
  y
```

Run the command on `b`.

After:

```text
owner A:
  b

owner B:
  x
  y
```

It must never replace or erase the complete persistent state.

## 13. Removing the Last Mark

If:

```text
owner A:
  a.odin
```

and `a.odin` is unmarked, keep the active context:

```text
owner = repo-A
marked = ()
```

Do not immediately clear the owner.

This allows the user to continue working in the same marked-set context and mark another file—even one from another repository—without accidentally creating a new owner.

## 14. Tab-Bar Rendering

Render marked tabs from the active owner, not from the Git root of the currently selected buffer.

Correct data flow:

```text
frame
  |
  v
active owner repository
  |
  v
marked set for owner
  |
  v
resolve file IDs to buffers
  |
  v
render tabs
```

Incorrect data flow:

```text
current buffer
  |
  v
current buffer Git root
  |
  v
marked files
```

The latter would incorrectly switch sets whenever a marked file came from another repository.

## 15. Navigation Lists

Functions such as:

```elisp
ri-tabs--marked-buffer-list
ri-tabs--navigation-buffer-list
```

should operate in terms of the active owner.

Conceptually:

```elisp
(ri-tabs--marked-buffer-list owner-repo)
```

The returned buffers may physically belong to any repository.

All marked navigation commands should consume this owner-specific list.

## 16. Lazy Restoration

Do not restore marked files for every repository at startup.

When an owner context becomes active for the first time in a session:

```text
activate owner repo-A
    |
    v
load repo-A marked set
    |
    v
open/restore its marked files
```

Those files may belong to other repositories or be outside Git.

Other owner sets remain untouched until activated.

Track restored owners, for example:

```elisp
ri-tabs--restored-owner-repos
```

with semantics such as:

```text
repo-A -> restored
repo-B -> not yet restored
```

This prevents repeated restoration and recursion through file-opening hooks.

## 17. Restart Behavior

Suppose persistent state contains:

```text
repo-A:
  /repo-A/foo.odin
  /repo-B/helper.odin
  /home/user/notes.txt

repo-B:
  /repo-B/main.odin
```

If the initial project context is repo-A, restore only the repo-A set:

```text
/repo-A/foo.odin
/repo-B/helper.odin
/home/user/notes.txt
```

Do not restore the repo-B set until repo-B becomes the active owner context.

## 18. Rename and Save As

Owner membership is independent of the physical repository of a file.

Suppose:

```text
owner A:
  /repo-B/foo.el
```

and the file is renamed or saved as:

```text
/repo-C/foo.el
```

The result must be:

```text
owner A:
  /repo-C/foo.el
```

The owner remains A.

Only the file identity changes.

## 19. Rename Across Multiple Sets

Because one physical file may belong to multiple marked sets:

```text
owner A:
  /shared/foo.el

owner B:
  /shared/foo.el
```

renaming:

```text
/shared/foo.el
->
/shared/bar.el
```

must update every marked set containing the old file ID:

```text
owner A:
  /shared/bar.el

owner B:
  /shared/bar.el
```

The persistent update should be atomic so that a rename cannot leave only some owner sets updated.

## 20. Suggested Internal API

Aim for an internal API along these lines:

```elisp
(ri-tabs--buffer-repo buffer)

(ri-tabs--frame-owner-repo frame)
(ri-tabs--set-frame-owner-repo frame repo)

(ri-tabs--owner-files repo)
(ri-tabs--set-owner-files repo files)

(ri-tabs--marked-p owner-repo buffer)
(ri-tabs--mark owner-repo buffer)
(ri-tabs--unmark owner-repo buffer)

(ri-tabs--activate-owner repo)
(ri-tabs--restore-owner repo)

(ri-tabs--switch-owner repo)
```

Navigation helpers should explicitly operate against the active owner instead of deriving repository state from individual buffers.

## 21. Migration from Version 1

The current version-1 format has one global list and therefore does not contain explicit owner information.

Migration must avoid silently assigning an incorrect owner.

A reasonable migration policy is:

1. Read the existing v1 file list.
2. Determine the Git root of the first valid marked file.
3. Use that repository as the owner of the entire existing list.
4. Preserve every other marked file in that same set, regardless of which repository it belongs to.
5. Write the result as version 2.

This matches the new semantic model better than grouping old files by their individual Git roots.

If no valid owner repository can be derived from the old state, preserve the old data and report a warning rather than silently discarding it.

## 22. Tests

Add ERT tests for at least the following cases.

### Primary cross-repository workflow

```text
open repo-A/a.el
mark
open repo-B/b.el
mark
```

Expected:

```text
owner = repo-A

repo-A set:
  repo-A/a.el
  repo-B/b.el
```

### Opening another repository does not switch owner

```text
owner = repo-A
find-file repo-B/x.el
```

Expected:

```text
owner = repo-A
```

### Navigation across repositories

```text
owner A:
  A/a.el
  B/b.el
  C/c.el
```

Navigate between all three marked tabs.

Expected:

```text
owner remains A
```

throughout.

### Independent sets

Create:

```text
owner A:
  A/a.el
  B/shared.el

owner B:
  B/x.el
```

Switch explicitly between owner contexts.

Expected: each context displays only its own marked set.

### Same file in multiple sets

```text
owner A:
  /shared/foo.el

owner B:
  /shared/foo.el
```

Expected: marking/unmarking in one owner does not alter the other.

### Unmark others

Verify that `unmark-other-buffers` modifies only the active owner.

### Last mark removed

Remove the final marked file.

Expected:

```text
owner remains active
marked set becomes empty
```

### File outside Git

With an existing owner, mark a non-Git file.

Expected: it is added to that owner's set.

Without an owner, attempt to mark a non-Git file.

Expected: the operation is rejected.

### Rename within a repository

Verify file ID replacement without owner changes.

### Rename across repositories

Move a marked file from repo-B to repo-C.

Expected: its owner set remains unchanged.

### Rename when file belongs to multiple owner sets

Expected: every set containing the old file ID is updated.

### Multiple frames

Use:

```text
Frame 1 -> owner A
Frame 2 -> owner B
```

Expected: each frame renders and navigates its own marked set independently.

### Persistence and lazy restore

Restart/re-enable `ri-tabs`.

Expected: activating owner A restores only A's set; B's set remains dormant until B is explicitly activated.

### Git worktrees and canonical paths

Verify owner detection and identity normalization for worktrees, symlinks, and canonical repository paths.

## Final Model

The implementation should preserve this mental model:

```text
A marked-tab set belongs to the repository where the set was started.

The files inside that set may come from anywhere.

Opening or navigating to a file from another repository does not transfer
ownership of the set.

Repository context and file location are separate concepts.
```
