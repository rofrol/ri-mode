# Momentary Navigation Status Plan

## Problem

The mode line currently shows only `sr-submode`. Holding `a`, `s`, or `w` opens a temporary navigation layer, but the display does not distinguish the persistent selection unit from the held navigation unit. During a hold from NODE, users therefore see either `NODE` before movement or `LINE` / `WORD+` / `CHAR` after movement instead of the intended compound state.

## Required behavior

- Hold `a`: show `BASE(LINE)`.
- Hold `s`: show `BASE(WORD+)`.
- Hold `w`: show `BASE(CHAR)`.
- Keep the compound label while navigation keys are used, including during Extend.
- On release, restore the existing `BASE` label and submode.
- A quick tap must retain its current behavior and commit LINE, WORD+, or CHAR.
- Selection bounds and the active Extend edge must remain unchanged by status handling.

Example: NODE plus held `a` renders `NORM[NODE(LINE)]`; releasing `a` renders `NORM[NODE]`.

## Implementation

1. Add the navigation target submode to the three existing layer specifications. This keeps key, tap command, map, label, and status target in one table.
2. Record the active target when a navigation layer opens and clear it in that layer's release action. Force a mode-line refresh at both transitions.
3. Render the mode-line unit as `BASE(TARGET)` while a target is active. Before the first movement, `BASE` is `sr-submode`; after movement switches `sr-submode`, use the already-recorded momentary origin as `BASE`.
4. Extend the existing chord test table to cover the specification target and the mode-line text before movement, after movement, and after release for `a`, `s`, and `w`.
5. Document the compound held-layer label in `README.md`.

## Verification

- Run the focused `ri-chord-test.el` ERT suite.
- Run the focused `ri-extend-test.el` ERT suite to protect selection and release invariants.
- Byte-compile the changed Emacs Lisp files with warnings treated as errors.

## Acceptance criteria

- NODE plus held `a`, `s`, or `w` displays `NODE(LINE)`, `NODE(WORD+)`, or `NODE(CHAR)` respectively.
- Any other starting submode is displayed as the base in the same format.
- The compound label remains stable after one or more held navigation commands.
- Release removes the suffix and restores the original submode label.
- Tap behavior, navigation behavior, selection bounds, and active-edge placement are unchanged.
