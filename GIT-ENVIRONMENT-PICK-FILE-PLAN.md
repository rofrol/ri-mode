# Git Environment Pick File Fix Plan

## Problem

`Pick > File` does not treat a repository selected through `GIT_DIR` and `GIT_WORK_TREE` as the current repository when the work tree has no physical `.git` file or directory.

From a buffer below that work tree, the picker searches only below the buffer's `default-directory`. Files elsewhere in the same effective Git work tree are therefore missing.

The expected contract is:

- explicit `GIT_DIR` / `GIT_WORK_TREE` values inherited by Emacs select Git's effective work tree;
- `Pick > File` lists files from that complete work tree, not only the current subdirectory;
- tracked files and non-ignored untracked files remain available, while Git-ignored files remain excluded;
- ordinary `project.el` projects and non-project directory fallback behavior remain unchanged when no explicit Git environment selects a work tree.

## Confirmed Root Cause

`ri-pick--project-context` in `ri-pick/ri-pick.el` currently calls:

```elisp
(project-current nil)
```

`project.el`'s VC finder discovers repositories by locating physical backend markers such as `.git`. It does not ask Git to resolve `GIT_DIR` and `GIT_WORK_TREE`. With external Git metadata and no `.git` entry below the work tree, `project-current` returns nil.

The current fallback then chooses `default-directory` as the root:

```elisp
(if project (project-root project) default-directory)
```

`ri-pick--file-items` receives a nil project and calls `ri-pick--fallback-files` on that root. This exactly explains the reported behavior: recursive traversal starts at the current buffer directory rather than the effective Git work-tree root.

A batch reproduction with Emacs 32.0.50 confirmed that `project-current` returns nil from a nested directory when `GIT_DIR` points to external metadata and `GIT_WORK_TREE` points to the containing work tree.

## Important `project.el` Constraint

Do not synthesize a `(vc Git ROOT)` project and pass it to `project-files` for this case.

The Git VC backend prepends an unset `GIT_DIR` entry to Git subprocess environments. Consequently, `vc-git-project-list-files` deliberately ignores the caller's `GIT_DIR`; a synthetic VC project fails when no physical `.git` marker exists under the work tree. This was also reproduced against the current Emacs implementation.

The external-environment path therefore needs a direct Git file-list command that inherits Emacs' unmodified `process-environment`. Ordinary projects should continue through `project-files`.

## Decision

Add an explicit Git-environment source alongside the two existing sources:

1. **Explicit Git environment**: when non-empty `GIT_DIR` or `GIT_WORK_TREE` is present and Git resolves a work-tree root, use Git directly. This source takes precedence over `project-current`, matching Git's own handling of explicit repository environment variables.
2. **Ordinary project**: otherwise use `project-current`, `project-root`, and `project-files` exactly as today.
3. **Directory fallback**: when neither source resolves, recursively enumerate `default-directory` exactly as today.

Reuse the existing Git-authoritative root resolver in `ri-tabs` instead of adding a second `rev-parse` implementation. Promote that helper to a public bundled-module function before using it from `ri-pick`.

For the explicit Git source, enumerate files with a direct equivalent of:

```sh
git ls-files -z --full-name --cached --others --exclude-standard -- :/
```

The command must run with the source buffer's effective directory and unchanged `process-environment`:

- `--cached` includes tracked index entries;
- `--others --exclude-standard` includes untracked files except those excluded by Git's standard ignore sources;
- `-z` preserves spaces, newlines, and other non-separator characters in file names;
- `--full-name` returns paths relative to the work-tree root;
- the top-level `:/` pathspec includes the whole work tree even when the source buffer is in a nested directory.

Using the source directory plus the top-level pathspec is preferable to rebinding the command to the resolved root: relative `GIT_DIR` or `GIT_WORK_TREE` values retain Git's original working-directory semantics.

## Implementation

### 1. Make the existing Git root resolver reusable

Update `ri-tabs/ri-tabs.el`:

- rename `ri-tabs--git-work-tree-root` to `ri-tabs-git-work-tree-root`;
- retain its current `git rev-parse --show-toplevel` implementation, canonicalization, executable check, and nil-on-failure behavior;
- retain the rule that Git itself is authoritative and inherits Emacs' current `process-environment`;
- migrate every internal `ri-tabs` caller to the public name;
- update test stubs that bind the old private symbol;
- do not retain a compatibility alias: this is an internal repository cutover, and every caller will be migrated together.

Do not move the helper into `ri-pick`: `ri-pick` already requires `ri-tabs`, and duplicating repository-resolution semantics would create two implementations that can diverge.

### 2. Represent the candidate source explicitly

Revise `ri-pick--project-context` in `ri-pick/ri-pick.el` so callers can distinguish an ordinary `project.el` project from an explicit Git-environment source.

A minimal return contract is a three-element value:

```text
(PROJECT ROOT GIT-DIRECTORY)
```

where:

- `PROJECT` is the ordinary `project.el` object or nil;
- `ROOT` is the absolute directory used for labels and file targets;
- `GIT-DIRECTORY` is the source buffer directory from which direct Git commands must run, or nil when direct Git enumeration is not selected.

Resolution order:

1. Check whether `GIT_DIR` or `GIT_WORK_TREE` has a non-empty value in Emacs' `process-environment`.
2. If so, call `ri-tabs-git-work-tree-root` with the source buffer's `default-directory`.
3. If Git returns a root, return that root and the source directory as the explicit Git context without consulting `project-current` for precedence.
4. Otherwise call `project-current nil` and use its `project-root` when available.
5. If neither resolves, use the expanded, directory-form `default-directory` fallback.

Keep root normalization consistent with the current function: absolute names with a trailing directory separator. The Git helper already canonicalizes its result.

Update both callers:

- `ri-pick-open-buffers` uses `ROOT` for concise buffer labels and ignores the candidate-source fields;
- `ri-pick-open-files` passes all three fields to file enumeration.

This also makes Buffer labels relative to the effective external work tree, which is consistent with the existing project-root behavior.

### 3. Add direct Git file enumeration

Add a focused private helper in `ri-pick/ri-pick.el`, for example:

```text
ri-pick--git-files(DIRECTORY)
```

It must:

- bind `default-directory` to `DIRECTORY`;
- invoke `git ls-files` through `process-file`, not through `vc-git-command`;
- inherit the existing `process-environment` unchanged;
- request NUL-delimited, root-relative tracked and non-ignored untracked paths across the top-level work tree;
- split only on NUL and discard the final empty field;
- return relative names suitable for expansion against the resolved `ROOT`;
- signal a concise `user-error` if Git listing fails after the explicit Git context was resolved.

Do not silently fall back to unrestricted directory traversal after a Git listing error. That would hide the repository error and could expose ignored or otherwise unintended files.

### 4. Route file candidates by source

Extend `ri-pick--file-items` to accept the explicit Git source field and select exactly one path:

```text
explicit Git source -> ri-pick--git-files
ordinary project    -> project-files
no source           -> ri-pick--fallback-files
```

Keep the existing item construction unchanged:

- labels remain relative to `ROOT`;
- targets remain absolute paths expanded from `ROOT`;
- annotations remain empty;
- acceptance still calls `find-file` with the absolute target.

Do not merge results from multiple sources. Explicit Git environment, ordinary project discovery, and plain directory traversal have different ownership and ignore semantics; combining them would introduce duplicates and leak files outside the selected source contract.

### 5. Update user-facing documentation

Update the Pick section in `README.md`.

Retain the statement that ordinary projects follow their `project.el` backend ignore rules. Add that when `GIT_DIR` / `GIT_WORK_TREE` selects an external work tree, File uses Git's effective work-tree root and standard ignore rules.

State the process boundary precisely: those variables must exist in Emacs' own `process-environment`. Changing variables in an unrelated shell after an Emacs daemon has started cannot change that daemon's environment.

## Regression Coverage

### `ri-pick/ri-pick-test.el`

Add an ERT fixture that creates:

- a temporary work tree;
- a separate external Git directory;
- a nested source directory with no `.git` entry in the work tree;
- a file in the work-tree root;
- a file in the nested source directory;
- a Git-ignored file;
- a file name containing spaces to ensure candidate parsing is not replaced with whitespace splitting.

Initialize Git with explicit `--git-dir` and `--work-tree` arguments. Bind a copied `process-environment`, set `GIT_DIR` and `GIT_WORK_TREE`, and bind `default-directory` to the nested source directory. Skip the test when `git` is unavailable.

Exercise the real context and item-building helpers. Assert that:

- the resolved root equals the canonical work-tree root;
- the explicit Git source is selected even though there is no physical `.git` entry;
- the root-level and nested files both appear;
- labels are root-relative;
- targets are absolute and resolve below the work tree;
- the ignored file does not appear;
- the work tree still has no `.git` file or directory.

Add a focused precedence assertion: with a valid explicit Git environment, a `project-current` result must not replace the Git-selected root. This can be tested by stubbing `project-current` to fail if called after Git resolution succeeds.

Retain the existing fallback test `ri-pick-test-project-file-label-and-target-have-distinct-roles`; it protects the non-project traversal path. Add or extend a small ordinary-project test to assert that, with both Git environment variables absent, `project-files` remains the source and direct Git enumeration is not called.

All temporary directories and environment bindings must be unwound even after assertion failure.

### `ri-tabs/ri-tabs-test.el`

Migrate references from `ri-tabs--git-work-tree-root` to `ri-tabs-git-work-tree-root`.

Run the existing external Git environment owner test. It already proves that the shared resolver honors external `GIT_DIR` / `GIT_WORK_TREE`; no duplicate resolver test is needed unless the public rename changes that contract.

## Verification

Run the picker test suite:

```sh
emacs --batch -Q -L . -L ri-pick -L ri-tabs -L keymap-legend \
  -L mini-modal -L modal-cursor -L semantic-regions \
  -l ri-pick/ri-pick-test.el \
  -f ert-run-tests-batch-and-exit
```

Run the tab test suite because the shared resolver is renamed and all callers must migrate:

```sh
emacs --batch -Q -L . -L ri-tabs \
  -l ri-tabs/ri-tabs-test.el \
  -f ert-run-tests-batch-and-exit
```

Then smoke-test the real UI with Emacs started under a valid external Git environment:

1. Set `GIT_DIR` to an external Git directory and `GIT_WORK_TREE` to its work tree before starting Emacs, or set both inside Emacs' process environment.
2. Open a file in a nested directory of the work tree where no `.git` entry exists.
3. Open `Pick > File` with `SPC k d`.
4. Search for a non-ignored file located at the work-tree root or in a sibling directory and confirm that it appears.
5. Accept it and confirm that the absolute target opens.
6. Search for a Git-ignored file and confirm that it does not appear.
7. Repeat in an ordinary marker-based project with the Git environment variables absent and confirm that project-wide discovery still works.
8. Repeat outside a project and confirm that the picker still traverses only the current directory fallback.

## Acceptance Criteria

The fix is complete when:

1. `Pick > File` resolves the full effective work tree selected by `GIT_DIR` / `GIT_WORK_TREE` without requiring a local `.git` entry.
2. Files above and beside the source buffer's directory are available when they belong to that work tree.
3. Git-ignored files remain excluded, while tracked and non-ignored untracked files remain available.
4. File labels are work-tree-relative and accepted targets are absolute.
5. Explicit Git environment takes precedence over physical marker discovery, matching Git command behavior.
6. Ordinary `project.el` projects still use `project-files` and its backend ignore rules.
7. Non-project buffers still use the existing current-directory recursive fallback.
8. Buffer picker labels use the same effective root without changing buffer identity or acceptance behavior.
9. The picker and tab ERT suites pass, and the real external-work-tree UI scenario succeeds.

## Non-Goals

- Do not make `project.el` globally recognize environment-selected repositories.
- Do not change fuzzy matching, candidate rendering, picker geometry, navigation, or acceptance behavior.
- Do not make file enumeration asynchronous as part of this focused fix.
- Do not read environment variables from an unrelated shell process or attempt to mutate an already-running Emacs daemon from that shell.
- Do not fall back to listing ignored files when Git reports an enumeration error.
- Do not change Extend selection state, bounds, active edge, or cancellation behavior.
