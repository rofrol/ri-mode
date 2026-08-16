# Plan: Extend a CHAR selection to the left

## Problem

After selecting `CHAR` and entering Extend, `ri--enter-extend` records the selected character's start as `anchor`, its end as `initial-end`, and marks `end` as active. `ri--extend-horizontal-move` classifies Left from that state as shrinking and rejects the previous character because its end equals the anchor. Consequently, the first Left command cannot turn the initial one-character selection into a leftward extension.

The existing WORD-family exception is not reusable as-is: it permits crossing the anchor while leaving `end` active, which would leave point at the start edge. The repository invariant requires point to remain at the active edge after every Extend navigation command.

## Implementation

1. In `ri-extend.el`, represent a newly entered one-character CHAR Extend selection as direction-neutral (`active-edge` is nil) while retaining both the start `anchor` and `initial-end`. This preserves the visible initial selection and point position.
2. In `ri--extend-horizontal-move`, resolve that neutral CHAR state on its first horizontal command:
   - Right keeps the start anchor and establishes `end` as active.
   - Left moves the anchor to `initial-end`, establishes `start` as active, and moves to the preceding character.
   Subsequent movement continues through the existing active-edge shrink/expand logic. Do not change the active edge on later navigation; `ri-swap-cursor` remains the only edge swap.
3. Keep `ri--selection-bounds` and `ri--extend-point-boundary` generic. The state transition above makes their existing horizontal-boundary calculation produce `[previous-character-start, initial-character-end]` and keeps point on the `start` edge.
4. Update `ri--enter-extend` documentation to explain the neutral initial CHAR case. Do not alter other submodes or add a new state field.

## Regression coverage

1. Add a focused ERT case in `ri-extend-test.el`: at the middle character of `"abc"`, select CHAR, enter Extend, then navigate Left. Assert bounds `(1 . 3)`, point `1`, and active edge `start`.
2. In the same test, navigate Right once and assert the selection shrinks to the original character, point is its start edge, and `start` remains active. This proves the command did not silently swap edges.
3. Retain the existing swapped-cursor CHAR-left case as coverage that explicit cursor swaps still use the normal path.

## Verification

Run the focused `ri-extend-test` ERT selector in the repository's Emacs environment (including the external `kkp` dependency), then run the complete `ri-extend-test.el` suite. Confirm the new test and the existing submode-preservation, momentary-CHAR, and horizontal-navigation tests pass.
