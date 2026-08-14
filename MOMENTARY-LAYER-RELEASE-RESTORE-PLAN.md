# Momentary Layer Release Restore Plan

## Problem

The `a` and `s` layers commit their submode on press, not on release:

- `ri--layer-specs` sets `:activate-on-press t` for both, so pressing `a` or `s`
  immediately runs the persistent setter (`ri-extend-set-character-mode` /
  `ri-extend-set-word-plus-mode`).
- Each held sub-key then calls `ri--run-momentary-navigation`, which switches
  the submode again and navigates.
- `ri-chord-setup` registers `:on-release #'keymap-legend-hide` for every
  layer, so releasing `a` or `s` leaves the switched submode active.

Result: from NODE, holding `a` and pressing `i` moves up one character but
permanently leaves CHAR selected. The user expects the held layer to be truly
momentary: navigation runs in the layer's unit, and releasing the modifier
returns to the submode that was active before the layer opened (NODE, WORD,
LINE, ...).

A quick tap must keep its current meaning: `a` still selects CHAR and `s`
still selects WORD+ persistently. Only the held-navigation path restores.

## Required behavior

- Tap `a` (no sub-key): select CHAR persistently (unchanged). Tap `s`: select
  WORD+ persistently (unchanged).
- Hold `a` + `i`/`j`/`k`/`l`: navigate with CHAR behavior; on release, restore
  the submode active when the layer opened. Point stays where navigation left
  it (no snap-to-unit-start on restore).
- Hold `s` + `i`/`j`/`k`/`l`: same contract with WORD+.
- The layer legend shows the mode that release will return to, e.g.
  "Release hold: NODE".
- During Extend, both the switch and the restore preserve the exact existing
  selection bounds, and point remains on the active edge after navigation
  (existing AGENTS.md invariants).
- A non-layer key pressed while the layer is held keeps its own effect: it is
  not undone by the release restore.
- Other layers (`c`, `r`, `e`, `g`, `t`, `v`, `x`, `z`) are unchanged.

## Mechanism

`kkp-chord` already provides the needed distinction without changes:

- Tap dispatch (`kkp-chord--on-release`) runs the tap action only when no
  intervening key was pressed.
- Release actions run before tap dispatch, so a restore can run first and the
  tap still commits CHAR/WORD+ when the layer was a pure tap.

The fix moves the commit point from press to release-tap, records the origin
submode when held navigation runs, and restores it in a per-layer release
action.

## Implementation

### 1. Record and restore the origin submode (ri-extend.el)

Near `ri--run-momentary-navigation`:

```elisp
(defvar-local ri--momentary-origin-submode nil
  "Submode to restore when a momentary CHAR/WORD+ layer releases.")
```

Extend the shared runner:

```elisp
(defun ri--run-momentary-navigation (setter movement)
  "Record the active submode, switch with SETTER, then run MOVEMENT."
  (unless ri--momentary-origin-submode
    (setq ri--momentary-origin-submode sr-submode))
  (funcall setter)
  (funcall movement))
```

The `unless` guard records the origin on the first sub-key only; repeated
sub-keys keep the original submode.

Add the restore functions:

```elisp
(defun ri--restore-submode (submode)
  "Switch back to SUBMODE after a momentary layer, without moving point.
Outside Extend, the raw semantic-regions setters do not move point, so
the position left by held navigation is kept."
  (when (ri--selection-active-p)
    (ri--preserve-selection-for-submode-switch))
  (pcase submode
    ('line (sr-set-line-mode))
    ('line-star (sr-set-line-star-mode))
    ('paragraph (sr-set-paragraph-mode))
    ('char (sr-set-character-mode))
    ('word (sr-set-word-mode))
    ('word-plus (sr-set-word-plus-mode))
    ('word-star (sr-set-word-star-mode))
    ('subword (sr-set-subword-mode))
    ('node (sr-set-node-mode)))
  (ri--update-highlight))

(defun ri--restore-momentary-submode ()
  "Restore the submode active before the current momentary layer."
  (when ri--momentary-origin-submode
    (let ((origin ri--momentary-origin-submode))
      (setq ri--momentary-origin-submode nil)
      (ri--restore-submode origin)
      (force-mode-line-update))))
```

Notes:

- Use the raw `sr-set-*` setters, not the `ri-extend-set-*` wrappers: the
  wrappers snap point to the unit start outside Extend, which would move the
  cursor on restore.
- `sr-set-node-mode` re-checks the parser; origin `node` proves a parser was
  active when the layer opened, so the check succeeds. It also only moves
  point when seeding from LINE/LINE*, which cannot happen on restore.
- `ri--preserve-selection-for-submode-switch` is safe to run twice in one
  layer cycle (switch to the layer unit, then back): it re-reads current
  bounds and re-anchors each time.
- The setters echo "semantic-regions: X Mode". This doubles as release
  feedback; suppress it later only if users find it noisy.

### 2. Wire the layer specs and chord setup (ri.el)

In `ri--layer-specs`:

- `?a`: set `:activate-on-press nil`, add `:restore-on-release t`, set
  `:release nil`.
- `?s`: same changes.

Extend the spec docstring with:

```
:restore-on-release -- Non-nil restores the pre-layer submode on release and
                      shows it as the release label.
```

In `ri-chord-setup`:

- Read `restore-on-release` from the spec.
- In the shared `:on-press` lambda, reset the stale-state guard and derive
  the release label:

```elisp
(setq ri--momentary-origin-submode nil)
(when restore-on-release
  (setq release (ri--submode-name)))
```

(The reset is unconditional: harmless for layers that never record an
origin, and it prevents a dropped chord from leaving a stale origin behind.)

- Register the composed release action instead of the constant:

```elisp
:on-release (if restore-on-release
                (lambda ()
                  (keymap-legend-hide)
                  (ri--restore-momentary-submode))
              #'keymap-legend-hide)
```

Keep `:tap` pointing at the persistent setters; with `activate-on-press` nil,
KKP dispatches the tap on release only when no sub-key intervened, which is
exactly the tap-commits / hold-restores split.

`ri--press-layer` needs no change: its non-chord fallback still calls the tap
directly, and the mixed-encoding path (press as byte, release as CSI-u)
naturally moves the commit to the release event.

### 3. Update tests

`ri-chord-test.el`, `ri-chord-test-navigation-layers-select-their-units`:

- Spec assertions: `activate-on-press` is nil, `restore-on-release` is t for
  `?a` and `?s`; other layers keep plain `keymap-legend-hide`.
- Press-only path: after `ri--press-layer` the submode is still the tap-start
  mode; the switch assertion moves to the tap path (press + release without a
  sub-key commits CHAR/WORD+).
- Held path: after `l` and the release event, assert point moved by the layer
  unit and `sr-submode` equals the tap-start mode again, with unit bounds
  recomputed for it.

`ri-chord-test.el`, `ri-chord-test-hold-a-i-uses-char-highlight`:

- After `kkp-chord--on-release ?a`, assert `sr-submode` is `line` again and
  the highlight covers the LINE unit, not the CHAR unit.

`ri-extend-test.el`, momentary CHAR and WORD+ tests:

- Command level: after each momentary command, assert the layer submode is
  active and `ri--momentary-origin-submode` holds the origin; after
  `ri--restore-momentary-submode`, assert the origin submode is back and
  point has not moved.
- Extend level: assert exact selection bounds survive the switch and the
  restore, and point remains on the recorded active edge after navigation.

### 4. Update user documentation (README.md)

- Rows for `a` and `s`: "Select CHAR/WORD+; hold with i/j/k/l to navigate,
  releasing returns to the previous submode".
- Replace the sentence "The selected semantic submode remains active after
  the layer closes" with the tap-commits / hold-restores contract.

The prior plan `MOMENTARY-CHAR-WORD-PLUS-MODE-FIX-PLAN.md` stays as the
historical record; this plan revises only the held-path contract.

## Verification

1. Run the focused `ri-extend-test.el` and `ri-chord-test.el` ERT suites.
2. Smoke from NODE: hold `a`, press `i` — point moves up one character; on
   release the mode line reads `NORM[NODE]` and the NODE unit is highlighted
   around the new point.
3. Smoke from WORD: hold `a`, press `k` — one character down; release returns
   to `NORM[WORD]` with point untouched.
4. Smoke the `s` layer symmetrically from WORD/NODE.
5. Smoke a pure tap of `a` and `s`: the mode line commits `CHAR` / `WORD+`.
6. Repeat hold navigation inside Extend from each active edge; confirm exact
   selection bounds survive switch and restore and point stays on the edge.
7. Run the repository-wide ERT suite and report unrelated failures separately.

## Acceptance criteria

- Releasing a held `a` or `s` layer restores the pre-layer submode (NODE,
  WORD, LINE, ...).
- A tap of `a` or `s` still commits CHAR or WORD+ persistently.
- Held navigation leaves point where the movement put it; only the submode,
  highlight, and mode line change on release.
- The layer legend shows the mode release returns to.
- Extend bounds and active-edge invariants remain intact through switch and
  restore.
- Non-layer keys pressed while holding `a` or `s` are not undone on release.
