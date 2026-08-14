# CHAR Vertical Navigation Goal Column — Plan

## Problem

In CHAR mode, `i` / `k` (`ri-momentary-char-up` / `ri-momentary-char-down`,
routed through `sr-nav-up` / `sr-nav-down`) always land at column 0 of the
target line: the CHAR branch falls into `sr-nav-up`'s default `forward-line`
case, and `forward-line` moves to the beginning of the line.

Desired: remember the column where vertical movement started. Moving down
(`k`) from column 4 onto a line with only 2 characters clamps the cursor to
the last character of that line; moving onto a line with 4 or more
characters restores the cursor to column 4. This is the classic
`temporary-goal-column` behavior of `next-line` / `previous-line`, applied
to CHAR-mode movement.

## Current state

- `sr-nav-up` / `sr-nav-down` (`semantic-regions/semantic-regions.el`)
  dispatch on `sr-submode`; the `_` default branch handles both `char` and
  `line-star` with a plain `forward-line ±1`, then
  `sr--snap-to-unit-start` (a no-op for `char`, since a CHAR unit starts at
  point).
- All other branches (LINE blank-line skipping, NODE, wordish line jumps,
  PARAGRAPH message) are untouched by this change.
- Emacs' own `temporary-goal-column` mechanism cannot be reused directly:
  it keys persistence off `last-command` being `next-line`/`previous-line`,
  but in this package vertical movement runs through KKP chord commands
  (`ri-momentary-char-down`, `ri-extend-nav-down`), which reset it on every
  press.

## Target behavior

In CHAR mode only:

- The first `i`/`k` of a vertical session captures the current column as the
  goal column.
- Each following `i`/`k` restores that goal column on the target line.
- Lines shorter than the goal column clamp the cursor to their **last
  character** (the user-visible "cursor on the Nth character" behavior —
  not to the newline position Emacs' `move-to-column` would leave).
- Any other movement command (horizontal CHAR, other submodes, unit
  navigation) or a submode change ends the session and clears the goal, so
  the next vertical move captures a fresh column.

### Decisions

1. **Own buffer-local `sr--goal-column`, not `temporary-goal-column`.**
   Reusing Emacs' variable would leak goal state between `sr-nav-*` and
   `next-line`/`previous-line`, and its `last-command` reset logic does not
   fire for KKP chord commands. A dedicated variable is the boring, correct
   choice.
2. **Clamp to the last character, not end-of-line.** Emacs' goal-column
   clamp lands point on the newline; in CHAR mode the cursor sits on a
   character, so the clamp must leave it on the last real character of the
   short line. This matches the reported behavior ("cursor on the 2nd
   character").
3. **Goal applies to CHAR mode only.** LINE, LINE*, WORD*, NODE, and
   PARAGRAPH navigation all snap to unit starts or word starts by design;
   column restoration would contradict those submodes' semantics.
4. **Clear on every non-vertical-CHAR navigation and on submode change.**
   Mirrors Emacs' "any intervening command resets the goal" rule: after
   `j`/`l`, a unit jump, a parent-line move, or a submode switch, the next
   vertical move starts a new goal column.

## Implementation

### `semantic-regions/semantic-regions.el`

Add the goal-column state and a CHAR vertical helper in the Navigation
commands section, before `sr-nav-up`:

```elisp
(defvar-local sr--goal-column nil
  "Goal column for vertical CHAR navigation, or nil to capture the
current column on the next move.")

(defun sr--nav-char-vertical (direction)
  "Move point DIRECTION lines, preserving the goal column.
The goal column is captured from the column where the vertical movement
started and restored on every subsequent move; lines shorter than the
goal clamp point to their last character."
  (let ((goal (or sr--goal-column (current-column))))
    (forward-line direction)
    (setq sr--goal-column goal)
    (goto-char (line-beginning-position))
    (move-to-column goal)
    (when (eolp)
      (when (> (point) (line-beginning-position))
        (backward-char 1)))))
```

Add a dedicated `'char` branch to `sr-nav-up` and `sr-nav-down`:

```elisp
    ('char (sr--nav-char-vertical -1))
```

and

```elisp
    ('char (sr--nav-char-vertical 1))
```

The `_` branch keeps plain `forward-line` for `line-star`.

Clear the goal in every other navigation path and on submode change:

- `sr--nav-wordish-line` (vertical word-based navigation);
- `sr-nav-prev`, `sr-nav-next`, `sr-nav-first`, `sr-nav-last`,
  `sr-nav-parent-line`;
- `sr-nav-left`, `sr-nav-right` (horizontal movement);
- `sr--set-submode`, inside the existing `(unless (eq sr-submode submode) ...)`
  block, so the per-press momentary-layer setter does not reset the goal
  mid-session.

### `ri-edit.el`

`ri--target-unit-bounds` runs `sr-nav-up`/`sr-nav-down` inside
`save-excursion` to compute deletion/swap targets. A CHAR-mode
`ri-swap-up`/`ri-swap-down` would otherwise record a goal column from the
scratch position. Clear the goal at the top of the function:

```elisp
(defun ri--target-unit-bounds (movement current &optional _preserve-reached)
  "Return semantic-regions bounds reached from CURRENT by MOVEMENT."
  (setq sr--goal-column nil)
  (save-excursion
    ...
```

## Coverage

### `ri-extend-test.el`

Add `ri-extend-test-momentary-char-vertical-remembers-goal-column` on
`"abcd\nef\nghij"` (positions: line 1 = 1-4, line 2 = 6-7, line 3 = 9-12):

- from point 3 (column 2) `ri-momentary-char-down` clamps to point 7
  (line 2's last character);
- a second `ri-momentary-char-down` restores column 2 → point 11 (line 3);
- `ri-momentary-char-up` re-clamps to point 7, a second `ri-momentary-char-up`
  restores point 3;
- after `ri-momentary-char-right` (horizontal move clears the goal),
  `ri-momentary-char-down` captures the new column (3) and clamps to point 7;
- under Extend (`ri--enter-extend` from point 2), `ri-momentary-char-down`
  extends the selection to the goal column and point stays on the active
  end edge; `ri-momentary-char-down` again restores column 1 (point 11).

## Documentation

None. This restores standard goal-column behavior users expect from
vertical movement; no keymap, layer, or README surface changes.

## Verification

- Focused suites: `ri-extend-test.el`, `semantic-regions-test.el`,
  `ri-chord-test.el`.
- Byte-compile `semantic-regions.el`, `ri-edit.el`.
- Smoke in batch Emacs: `sr-nav-down` from column 2 on `"abcd\nef\nghij"`
  clamps to line 2's last char, then restores column 2 on line 3;
  `sr-nav-right` resets the goal.

## Implementation status

Implemented on 2026-08-14.

- `sr--goal-column` + `sr--nav-char-vertical` added; `'char` branch added to
  `sr-nav-up` / `sr-nav-down`; goal cleared in all other navigation paths
  and on submode change.
- `ri--target-unit-bounds` clears the goal before scratch movement.
- New `ri-extend-test-momentary-char-vertical-remembers-goal-column` test
  passes; `ri-extend-test-line-to-word-after-swap-preserves-extend` updated
  to the goal-column landing (bounds `(8 . 31)`).
- Focused suites: semantic-regions 63 tests / 0 unexpected / 8 skipped,
  ri-extend 32 tests / 0 unexpected / 1 skipped, ri-chord 20 tests / 0
  unexpected (skips are pre-existing tree-sitter grammar gaps).
- Byte-compile of `semantic-regions.el` and `ri-edit.el`: clean apart from
  the two pre-existing warnings in `semantic-regions.el` (`_bounds` unused,
  free `sr-mode`).
- Smoke in batch Emacs on `"zero alpha\nab\nalpha beta gamma\ne"`: from
  point 8 (column 7), `k` clamps to line 2's last char (point 13), `k`
  restores column 7 on line 3 (point 22), `i` restores column 7 back, and
  `j` clears the goal so the next `k` captures a fresh column.
