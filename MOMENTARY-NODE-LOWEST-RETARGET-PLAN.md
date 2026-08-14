# MOMENTARY-NODE-LOWEST-RETARGET-PLAN.md

## Problem

While in NODE submode, holding `s` (WORD+ momentary layer) or `w` (CHAR
momentary layer) and navigating down/right/left/up moves point by WORD+ or
CHAR units. Releasing the layer restores the origin submode via
`ri--restore-submode`, which for NODE calls the keyboard entry setter
`sr-set-node-mode`. That setter seeds `sr--node-current` to nil, so the
next highlight query falls back to `sr--node-top-at`, the Ki-style
top-node rule used for keyboard entry.

A mouse click in NODE, by contrast, calls `sr-retarget-at-position`, which
selects `sr--node-lowest-at` — the smallest real tree-sitter node covering
the clicked position — and marks it as a direct target
(`sr--node-direct-target-p`), keeping point where the user clicked.

Result: after a held `s`/`w` navigation, the landing position is
reinterpreted with the keyboard top-node rule, so the highlighted NODE can
differ from what a click at the same position would select. Measured
divergence (elisp grammar, buffer `(defun foo ()\n  (bar baz))`):

| position | `sr--node-top-at` (current restore) | `sr--node-lowest-at` (mouse click) |
|----------|-------------------------------------|-------------------------------------|
| 7 (space after `defun`) | `defun` (2 . 7) | defun form (1 . 27) |
| 21 (space after `bar`) | `bar` (18 . 21) | `(bar baz)` (17 . 26) |
| 17 (`(` of `(bar baz)`) | `(bar baz)` (17 . 26) | `(` (17 . 18) |

## Decision

On momentary-layer release, when the restored origin submode is NODE and no
Extend selection is active, retarget the NODE unit at the resting point
with `sr-retarget-at-position`, reproducing the mouse-click semantics
exactly: lowest node at point, point unmoved, direct-target state set.

Restricted to the non-Extend path: with Extend active, the selection must
keep its exact bounds (AGENTS.md invariant), which
`ri--preserve-selection-for-submode-switch` already guarantees. Retargeting
there would shrink/expand the selection.

Applies uniformly to every momentary layer that restores NODE (`a`, `s`,
`w`): all three leave point at a position that should be interpreted as a
direct click target. Restricting to `s`/`w` only would special-case the
same defect in `a` and require extra conditions.

## Change

`ri-extend.el`, `ri--restore-submode` — replace the plain `node` branch:

```elisp
('node
 (sr-set-node-mode)
 (unless (ri--selection-active-p)
   (sr-retarget-at-position (point))))
```

Order matters: `sr-set-node-mode` first (makes `sr-submode` `'node`, so
`sr-retarget-at-position` takes its NODE branch), then the retarget, which
clears virtual-node state, installs `sr--node-lowest-at` as
`sr--node-current`, sets `sr--node-direct-target-p`, keeps point, and
refreshes the highlight. The trailing `(ri--update-highlight)` is left
untouched; it still renders the Extend-preserved bounds in the Extend path.

No change to `sr-set-node-mode`, `sr-retarget-at-position`, or
`ri-mouse.el`; the retarget helper already encodes the click semantics.

## Verification

- New regression test in `ri-extend-test.el` (elisp grammar, available in
  CI emacs build): NODE origin, hold-`w` right onto the space after
  `defun`, release, assert `sr-submode` is `node`, point unmoved, and
  current unit equals the defun form (lowest node at the landing
  position) — plus a WORD+ variant landing at a divergent position.
- Extend path: existing momentary tests
  (`ri-extend-test-momentary-*records-origin-and-restores`) already assert
  exact bounds survive restore; they must stay green.
- Full `ri-extend-test.el` run.
