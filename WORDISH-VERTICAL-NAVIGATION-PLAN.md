# Wordish Vertical Navigation Plan

## Problem

In `WORD`, `WORD+`, `WORD*`, and `SUBWORD` modes, `sr-nav-up` and `sr-nav-down`
currently choose a destination by semantic-unit ordinal position instead of
text column. That fails when syntax punctuation and identifiers have
different lengths. For example, moving down from the first `0` in an Odin
initializer lands on the final `1` instead of the `f32` word aligned under the
cursor.

## Desired behavior

Vertical word-based navigation must preserve the current text column:

- moving down targets the traversable unit containing that column on the next
  traversable line;
- moving up applies the same rule in reverse;
- if the target column falls in separators, use the next traversable unit;
- if the target line ends before the column or has fewer units, clamp to its
  last traversable unit;
- blank and separator-only lines remain skipped;
- the rule applies consistently to `WORD`, `WORD+`, `WORD*`, and `SUBWORD`.

The column is semantic only through each submode's existing unit and
separator rules; no new word parser is introduced.

## Implementation

1. Replace ordinal destination lookup in
   `semantic-regions/semantic-regions.el` with a column-based destination
   lookup. Reuse `sr--meaningful-unit-bounds-at` so each submode keeps its
   existing separator behavior.
2. Preserve one goal column across consecutive vertical word-based moves,
   matching CHAR-mode vertical navigation. Clear it through the existing
   non-vertical navigation paths and submode changes.
3. Keep `sr--nav-wordish-line` responsible for skipping lines without a
   traversable unit and restoring the original point when no destination
   exists.
4. Leave horizontal navigation, NODE navigation, Extend selection bounds,
   and all submode definitions unchanged.

## Regression coverage

Add an ERT test in `semantic-regions/semantic-regions-test.el` using the
reported Odin lines. In each of `WORD`, `WORD+`, `WORD*`, and `SUBWORD`, place
point on the first `0`, move down, and assert that `f32` is selected. Move
back up and assert that the original semantic unit is selected. Retain the
existing tests for leading whitespace and symbol-only lines.

## Verification

- Re-run the reproduction in batch Emacs and confirm all four modes select
  `f32` instead of the final `1`.
- Run the focused `semantic-regions` ERT suite.
- Byte-compile the changed semantic-regions source and test file if supported
  by the local Emacs installation.

## Acceptance criteria

- `WORD`, `WORD+`, `WORD*`, and `SUBWORD` preserve semantic-unit position when
  moving vertically.
- Short lines clamp to their last traversable unit; empty lines remain
  skipped.
- Existing horizontal and non-word vertical navigation behavior is unchanged.
- Focused regression tests pass.

## Implementation status

Implemented on 2026-08-14.

- Word-based vertical navigation now preserves a goal text column and selects
  the unit under that column, with separator skipping and short-line
  clamping.
- Added regression coverage for the reported Odin case across `WORD`,
  `WORD+`, `WORD*`, and `SUBWORD`.
- The semantic-regions suite passes 64 tests with 56 passes, 0 failures, and
  8 pre-existing tree-sitter skips.
- Batch smoke confirms all four modes move from the first `0` to `f32`.
- Byte compilation is clean apart from the two pre-existing warnings in
  `semantic-regions.el` (`_bounds` unused and free `sr-mode`).
- The RI Extend integration suite could not load because the external `kkp`
  package is unavailable in this environment.
