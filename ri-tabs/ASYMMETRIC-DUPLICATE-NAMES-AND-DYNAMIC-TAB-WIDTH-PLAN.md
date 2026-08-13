# Asymmetric Duplicate Names and Dynamic Tab Width Plan

## Goal

Change `ri-tabs` in two related presentation areas:

1. When two displayed files have the same basename, keep the original/owner-side tab label short and add directory context only to the later foreign file.
2. Make every tab use only the width required by its rendered content instead of inheriting a fixed/equal tab width.

The change must preserve the existing repository-owned marked-set model, file-state markers, active-tab styling, mouse actions, persistence, ordering, and frame-wide Tab Bar behavior.

## Required Behavior

### 1. Duplicate basenames are disambiguated asymmetrically

Assume the active marked set is owned by `repo-A` because the first marked file came from that repository:

```text
/repo-A/src/main.odin
```

Its tab should initially be:

```text
[-] main.odin
```

Later the user opens and marks:

```text
/repo-B/src/main.odin
```

The result should be conceptually:

```text
[-] main.odin    [-] src/main.odin
```

or, if one parent component is still not sufficient to identify the foreign file uniquely, the foreign label may grow to the shortest necessary suffix:

```text
[-] main.odin    [-] repo-B/src/main.odin
```

The important invariant is that the first/owner-side `main.odin` remains `main.odin`; it must not be rewritten to `repo-A/src/main.odin` merely because another file with the same basename is added later.

This is intentionally different from the current `ri-tabs--tab-name` behavior, which computes the shortest unique suffix symmetrically for every conflicting buffer.

### 2. "Foreign" is relative to the marked-set owner

For a frame with owner context `repo-A`, a file is owner-local when it belongs to that owner context and foreign when it comes from another Git work tree or another outside-Git directory context.

The label preference for a duplicate basename is:

- owner-local file: keep the basename only;
- foreign file: add the shortest parent-path suffix required to distinguish it;
- if multiple foreign files share the basename, each foreign file must receive enough path context to distinguish it from the other foreign files;
- an unmarked current buffer temporarily appended to the visible tabs must use the same owner-relative naming rules, without changing the marked-set owner.

Do not use "the currently selected buffer wins" as the rule. Selection changes must not cause labels to swap between short and qualified forms.

### 3. Outside-Git owner contexts follow the same rule

The owner model already falls back to the effective directory outside Git. Preserve that behavior.

For example, if the owner context is:

```text
/home/user/project-a/
```

and the marked set later includes:

```text
/home/user/project-b/main.txt
```

then the owner-local `main.txt` remains short and the later/foreign file receives parent-directory context.

### 4. Tab width is content-sized

Each visible tab must occupy only the display width required by:

```text
<left padding> <state marker> <space> <computed file label> <right padding>
```

Examples:

```text
[-] a.el
[-] very-long-file-name.odin
[÷] main.odin
```

must render at different widths according to their actual content.

Do not pad shorter tabs to the width of the longest tab and do not impose a constant width per tab.

The current explicit single-space padding in `ri-tabs--tab-label` may remain if it is part of the desired visual spacing; "minimal to content" means no additional fixed/equal-width allocation beyond the label's own content and intentional edge spaces.

## Implementation Plan

### 1. Replace the symmetric shortest-unique-suffix naming rule

Refactor the naming logic around:

```elisp
ri-tabs--tab-name
ri-tabs--path-parts
ri-tabs--same-suffix-p
```

so that naming has access to the active owner context.

The current signature:

```elisp
(ri-tabs--tab-name buffer buffers)
```

is insufficient because it cannot decide which duplicate belongs to the active marked-set owner. Change it to accept the owner explicitly, or introduce a naming-context helper that receives `buffer`, `buffers`, and `owner`.

The function must remain pure with respect to selection: given the same visible buffers and owner, it should return the same names regardless of which tab is active.

### 2. Classify duplicate-name buffers by owner context

Add a small helper that determines whether a file belongs to the active owner context without mutating frame state.

Reuse the existing canonical path/Git helpers where possible, especially:

```elisp
ri-tabs--buffer-owner-context
ri-tabs--buffer-git-root
ri-tabs--canonical-directory
```

Do not call `ri-tabs--set-frame-owner` from label computation.

For a duplicate-basename group:

1. identify owner-local candidates;
2. keep the owner-local label as the basename;
3. compute qualified suffixes only for foreign candidates.

If there is more than one owner-local file with the same basename because they live in different subdirectories of the same owner repository, the basename alone cannot identify both. In that case, preserve deterministic disambiguation inside the owner group by qualifying only as much as necessary. The asymmetric rule should primarily prevent a single pre-existing owner-local tab from being needlessly expanded merely because a foreign duplicate appears.

### 3. Compute the foreign file's shortest sufficient suffix

Extract the suffix-growth logic from the current `ri-tabs--tab-name` into a reusable helper, for example conceptually:

```elisp
(ri-tabs--shortest-distinguishing-suffix buffer comparison-buffers)
```

For a foreign duplicate, compare against all other visible buffers with the same basename so that the resulting text actually distinguishes the file.

Start with one parent directory plus the basename rather than the basename alone, because the basename is already known to collide.

Grow toward the path root only while necessary.

If two live buffers somehow visit the exact same file identity/path, retain the existing safe fallback to `buffer-name` rather than producing identical clickable labels.

### 4. Thread owner context through label rendering

`ri-tabs--format-tabs` already obtains:

```elisp
owner
state
buffers
selected-buffer
```

Pass `owner` through `ri-tabs--tab-label` into the new naming logic.

Update the relevant function signatures and call sites without deriving owner again from the selected buffer.

This preserves the repository-owned marked-set invariant: opening or selecting a foreign file must not silently change which side gets the short label.

### 5. Make Ri items participate correctly in native Tab Bar auto-width

The renderer already uses native Tab Bar `menu-item` entries with keys such as:

```elisp
current-tab
tab-2
tab-3
```

Review Emacs 30.2's `tab-bar-auto-width` path and make Ri-generated file items explicitly compatible with it.

Prefer native Tab Bar width computation rather than introducing Ri-specific truncation, manual pixel/column measurement, or spacer strings.

If native auto-width recognizes only specific item shapes/predicates, register a narrowly scoped Ri predicate/function through the supported `tab-bar-auto-width-functions` mechanism while `ri-tabs-mode` is active. Save and restore any global/default value Ri changes, exactly as `ri-tabs` already does for Tab Bar format, visibility, key bindings, and frame state.

The Ri width integration should ensure:

- each item is sized from its own rendered label;
- no equal-width stretching across tabs;
- no fixed maximum/minimum width introduced by Ri;
- native handling remains responsible for a row that exceeds available frame width.

Do not solve this by truncating labels: duplicate-name qualification and tab width are separate concerns.

### 6. Preserve label contents and interaction metadata

Keep `ri-tabs--tab-label` responsible for the textual content and text properties:

```text
" <marker> <name> "
```

Preserve:

- `ri-tabs-current-tab` vs `ri-tabs-tab`;
- `ri-tabs-highlight` mouse face;
- full-path `help-echo`;
- state markers `[ ]`, `[-]`, `[:]`, `[÷]`;
- literal `%` filenames;
- mouse/touch item mapping and commands.

Width changes must not alter hit targets so that clicks still select the buffer represented by the visible item.

### 7. Restore native width configuration on disable

If implementation requires changing `tab-bar-auto-width` or `tab-bar-auto-width-functions`, extend `ri-tabs--capture-tab-bar-state` and `ri-tabs--restore-tab-bar-state` so the pre-existing user configuration is restored exactly when `ri-tabs-mode` is disabled.

Also cover temporary/new frames if the chosen native mechanism has frame-local state.

Do not leave Ri-specific width hooks installed after disabling the package.

## Tests

Update `ri-tabs/ri-tabs-test.el` with focused ERT coverage.

### Duplicate-name naming tests

Replace or adapt the current symmetric test:

```elisp
ri-tabs-test-names-use-shortest-unique-path-suffix
```

and add cases for:

1. **Owner-local + one foreign duplicate**

   ```text
   owner: /tmp/repo-a/
   /tmp/repo-a/src/main.el -> main.el
   /tmp/repo-b/src/main.el -> src/main.el or the shortest sufficient foreign suffix
   ```

   Assert specifically that the owner-local label stays exactly `main.el`.

2. **Selection does not affect naming**

   Render once with the owner-local file selected and once with the foreign file selected. The names must be identical in both renders.

3. **Two foreign duplicates**

   Verify that foreign duplicates grow enough path components to remain distinct while the single owner-local file stays short.

4. **Duplicate files within the owner repository**

   Two owner-local files named `main.el` must still be distinguishable deterministically; do not allow two identical clickable labels.

5. **Outside-Git owner + foreign directory**

   Verify the same asymmetric behavior for directory-owned sets outside Git.

6. **Identical file paths**

   Preserve the fallback to distinct buffer names.

7. **Unmarked current foreign duplicate**

   A temporary current-buffer tab with the same basename as a marked owner-local tab receives foreign qualification without changing the owner-local label.

### Dynamic-width tests

Add tests around the produced native menu-item labels and, where possible in batch ERT, the auto-width classification/configuration:

1. a short filename and a long filename produce labels with different `string-width` values matching their actual text;
2. Ri does not add right-side padding to equalize the labels;
3. any Ri auto-width predicate recognizes both `current-tab` and inactive Ri file-tab items;
4. enabling `ri-tabs-mode` installs the required native auto-width integration;
5. disabling `ri-tabs-mode` restores the exact prior auto-width configuration;
6. repeated enable/disable cycles do not duplicate hooks/functions.

Do not make tests depend on pixel widths or a particular GUI font. Use string/display-column assertions for Ri-owned content and structural assertions for the native auto-width integration.

## Documentation Updates

Update the commentary in `ri-tabs/ri-tabs.el` so it no longer states that all marked tabs use a symmetric "shortest unique path suffix" rule.

Document the new invariant instead:

- ordinary names stay as basenames;
- duplicate names preferentially keep the owner-local file short;
- foreign duplicates receive the minimum directory qualification required for disambiguation.

If `README.md` describes tab naming or width, update it consistently.

## Acceptance Criteria

The change is complete when all of the following are true:

1. With one marked `/repo-A/.../main.el`, its tab is `main.el`.
2. Marking `/repo-B/.../main.el` later does not change the repo-A tab to a qualified path.
3. The repo-B duplicate receives enough parent-directory context to distinguish it.
4. Switching selection between those files does not swap or recompute which one has the short name.
5. Multiple collisions remain unambiguous and deterministic.
6. The rule also works for outside-Git directory-owned marked sets.
7. Tabs with different content lengths render at different widths with no Ri-added equal-width padding.
8. Ri uses Emacs's native Tab Bar width machinery rather than a custom truncation/scrolling implementation.
9. Existing file-state markers, ordering, persistence, owner semantics, mouse behavior, and active/inactive faces remain unchanged.
10. Disabling `ri-tabs-mode` restores any native auto-width configuration that existed before Ri was enabled.
11. The full `ri-tabs` ERT suite passes after the change.
