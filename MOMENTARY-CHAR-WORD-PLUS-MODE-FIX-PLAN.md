# Momentary CHAR and WORD+ Mode Fix Plan

## Problem

The `a` and `s` layers currently borrow a navigation unit without changing the
persistent semantic submode:

- `a` runs movement with a dynamic `char` binding, then restores the previous
  mode; its tap action still selects `LINE`.
- `s` runs movement with a dynamic `word-plus` binding, then restores the
  previous mode; its tap action still selects `WORD`.

After a held-layer movement, navigation therefore follows `CHAR` or `WORD+`
while the mode line and semantic-region highlight are recomputed from `LINE` or
`WORD`. The displayed unit and the movement unit disagree.

## Required behavior

- Tapping `a`, or invoking navigation from its held layer, selects `CHAR` as
  the real persistent `sr-submode`.
- `a` + `i` / `j` / `k` / `l` navigates with normal `CHAR` behavior and leaves
  `sr-submode` set to `char`.
- Tapping `s`, or invoking navigation from its held layer, selects `WORD+` as
  the real persistent `sr-submode`.
- `s` + `i` / `j` / `k` / `l` navigates with normal `WORD+` behavior and leaves
  `sr-submode` set to `word-plus`.
- The mode line, semantic-region highlight, current-unit bounds, and navigation
  must all use the same active submode.
- Changing either submode during Extend must preserve the exact existing
  selection bounds. Subsequent navigation must keep point on the active edge:
  first selected character for `start`, last selected character for `end`.

`W` and `M-s` remain unchanged; remapping unrelated selectors is outside this
fix.

## Implementation

### 1. Commit the navigation submode

In `ri-extend.el`, replace the borrowed-submode behavior in
`ri--run-momentary-navigation` with a persistent switch through the existing RI
submode setters:

- CHAR commands use `ri-extend-set-character-mode` before movement.
- WORD+ commands use `ri-extend-set-word-plus-mode` before movement.
- Then call the existing `ri-extend-nav-*` command.

Reuse `ri--set-submode-with-extend` through those setters. It already preserves
active Extend bounds while switching and snaps normally outside Extend. Remove
the dynamic `let` binding and the extra pre/post preservation used only to
restore the old submode. Do not add new mode state or press/release bookkeeping.

### 2. Correct layer metadata and visible bindings

In `ri.el`:

- change the `a` layer tap command from `ri-extend-set-line-mode` to
  `ri-extend-set-character-mode` and its release label from `LINE` to `CHAR`;
- change the `s` layer tap command from `ri-extend-set-word-mode` to
  `ri-extend-set-word-plus-mode` and its release label from `WORD` to `WORD+`;
- update `ri--normal-help-map` so `a` is documented as `CHAR` and `s` as
  `WORD+`.

Keep `ri--layer-specs` as the registration source and keep the existing four-key
layer maps. No new transient-map mechanism is needed.

### 3. Replace obsolete expectations

In `ri-extend-test.el`:

- rename the momentary CHAR and WORD+ tests to describe persistent switching;
- assert that every CHAR layer command leaves `sr-submode` as `char`;
- assert that every WORD+ layer command leaves `sr-submode` as `word-plus`;
- verify current-unit bounds match the selected mode after movement, covering
  the highlight/navigation mismatch;
- under Extend, verify exact pre-switch bounds survive the mode change and each
  movement keeps point on the recorded active edge.

In `ri-chord-test.el`:

- update the `a` and `s` spec expectations to the CHAR and WORD+ setters and
  release labels;
- update tap assertions to expect `char` and `word-plus`;
- update held-layer assertions to prove the same submode remains active after an
  intervening movement suppresses the release tap;
- keep coverage that both maps expose `i`, `j`, `k`, and `l`.

### 4. Update user documentation

In `README.md`, remove the temporary/borrowed wording. Document `a` as the CHAR
selector/layer and `s` as the WORD+ selector/layer, and state that held
navigation continues in the selected persistent mode.

Do not rewrite the completed historical plan; this corrective plan records the
new contract.

## Verification

1. Run the focused `ri-extend-test.el` and `ri-chord-test.el` ERT suites.
2. Smoke `a` from `LINE`: confirm the mode line reads `NORM[CHAR]`, the highlight
   covers one character, and `j` / `l` move one character at a time.
3. Smoke `s` from `WORD`: confirm the mode line reads `NORM[WORD+]`, punctuation
   is highlighted as a WORD+ unit, and horizontal movement follows WORD+
   boundaries.
4. Repeat both paths in Extend from each active edge; confirm exact selection
   bounds survive the switch and point remains attached to that edge after
   navigation.
5. Run the repository-wide ERT suite and report unrelated failures separately.

## Acceptance criteria

- No path through the `a` layer restores `LINE` after CHAR navigation.
- No path through the `s` layer restores `WORD` after WORD+ navigation.
- Tap and held-layer behavior agree on the resulting persistent submode.
- Highlight, mode-line label, current-unit bounds, and navigation agree for both
  layers.
- Extend bounds and active-edge invariants remain intact.
