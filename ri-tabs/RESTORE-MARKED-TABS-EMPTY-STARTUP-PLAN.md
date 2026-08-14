# Restore Marked Tabs When Emacs Starts Empty

## Problem

Starting `emacs -nw` without a file leaves the selected buffer non-file (usually
`*scratch*`). `ri-tabs` currently discovers the active marked-set owner only
from a selected file buffer. Because no owner is selected, startup activation
never calls the existing marked-file restoration path. Opening a file later
establishes the owner and makes the persisted marked buffers appear.

## Goal

When Emacs starts in a directory, `ri-tabs-mode` must use that directory to
select the owner context, restore its persisted marked files, and select the
last successfully restored marked buffer. The selected buffer must not remain
the unrelated startup `*scratch*` buffer.

The fix must preserve the existing behavior:

- Git directories resolve to the canonical Git work-tree root.
- Non-Git directories use their canonical directory as owner.
- Only the selected frame's current directory selects its owner.
- When startup begins in a non-file buffer, the selected window switches to the
  last successfully restored marked buffer without changing the window layout.
- Opening a file later must not change an already selected owner implicitly.

## Implementation

1. Add one directory-to-owner helper that canonicalizes a usable directory and
   resolves its Git work-tree root when available.
2. Reuse that helper in file-buffer owner computation so file and empty-buffer
   startup use exactly the same owner rules.
3. During activation, derive each eligible frame's owner from its selected
   window buffer's `default-directory` when that buffer is not a file buffer.
   Keep the existing file-buffer path unchanged. After restoring that owner,
   select the last live marked buffer in the existing deterministic tab order
   only when the startup buffer was non-file.
4. Add an ERT regression test that stores marked files for a temporary Git
   directory, starts with a non-file buffer whose `default-directory` is that
   directory, and verifies both files are restored, marked, and the last
   restored tab is selected.
5. Run the focused `ri-tabs` test and a direct `emacs -nw` smoke scenario if the
   local terminal permits it.

## Acceptance criteria

- Persisted marked files restore during `ri-tabs-mode` activation with an empty
  selected buffer launched from their directory.
- The selected buffer is the last successfully restored marked tab, not
  `*scratch*`.
- The test passes for a Git owner and covers the original failure mode.
- No new persistence format, startup hook, dependency, or session manager is
  introduced.
