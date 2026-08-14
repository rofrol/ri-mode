# Momentary Tap/Hold Restore Plan

Supersedes the tap targets of `MOMENTARY-LAYER-RELEASE-RESTORE-PLAN.md` and
the held-path contract of `MOMENTARY-CHAR-WORD-PLUS-MODE-FIX-PLAN.md`. The
release-restore mechanism designed there is kept; only the tap targets
change, and the two older plans stay as the historical record.

## Problem

Today the `a` and `s` layers commit their submode on press:

- `ri--layer-specs` sets `:activate-on-press t` for both, so pressing `a` or
  `s` immediately runs `ri-extend-set-character-mode` /
  `ri-extend-set-word-plus-mode` (the plan-2 contract).
- Releasing `a` or `s` leaves that switched submode active, and `ri-chord-setup`
  registers only `#'keymap-legend-hide` as the release action.

From NODE, `a` + `i` moves up one character and works, but releasing `a`
leaves CHAR selected. The layer must be truly momentary on hold: navigate in
the layer unit, and on release return to the submode that was active when the
layer opened (NODE, WORD, LINE, ...).

The tap targets also regressed relative to the plan-1 contract: a quick tap of
`a` must enter `LINE`, not `CHAR`.

## Required behavior

| Gesture                | Result                                                        |
|------------------------|---------------------------------------------------------------|
| Tap `a` (press + release, no sub-key) | Select `LINE` persistently.                            |
| Hold `a` + `i`/`j`/`k`/`l` | Navigate with `CHAR` semantics; on release restore the submode active when the layer opened. |
| Tap `s`                | Select `WORD+` persistently (unchanged from the current contract). |
| Hold `s` + `i`/`j`/`k`/`l` | Navigate with `WORD+` semantics; on release restore the pre-layer submode. |

Invariants (unchanged from `MOMENTARY-LAYER-RELEASE-RESTORE-PLAN.md`):

- Point stays where held navigation left it; only the submode, highlight, and
  mode line change on release (no snap-to-unit-start on restore).
- The layer legend shows the mode release will return to, e.g. "Release hold:
  NODE".
- During Extend, switch and restore preserve the exact existing selection
  bounds and point remains on the active edge after navigation (AGENTS.md).
- A non-layer key pressed while the layer is held keeps its own effect; the
  release restore does not undo it.
- Other layers (`c`, `r`, `e`, `g`, `t`, `v`, `x`, `z`) are unchanged.

`W` remains the persistent CHAR selector; `M-s` remains the persistent WORD+
selector. If plain `WORD` is ever wanted as the `s` tap target instead of
`WORD+`, only the tap setter changes — keeping tap and hold units identical
is the reason `s` stays `WORD+`.

## Mechanism

`kkp-chord` already provides the tap/hold distinction without changes:

- Tap dispatch (`kkp-chord--on-release`) runs the tap action only when no
  intervening sub-key was pressed.
- Release actions run before tap dispatch, so a restore can run first and the
  tap still commits LINE/WORD+ on a pure tap.

The change moves the commit point from press to release-tap, records the
origin submode when held navigation runs, and restores it in a per-layer
release action. This is exactly the plan-3 mechanism; the deltas from that
plan are the `?a` tap target (`ri-extend-set-character-mode` →
`ri-extend-set-line-mode`) and the corresponding test/doc expectations.

### 1. Record and restore the origin submode (ri-extend.el)

Near `ri--run-momentary-navigation` (currently a bare
"switch with SETTER, then run MOVEMENT"):

```elisp
(defvar-local ri--momentary-origin-submode nil
  "Submode to restore when a momentary CHAR/WORD+ layer releases.")

(defun ri--run-momentary-navigation (setter movement)
  "Record the active submode, switch with SETTER, then run MOVEMENT."
  (unless ri--momentary-origin-submode
    (setq ri--momentary-origin-submode sr-submode))
  (funcall setter)
  (funcall movement))
```

The `unless` guard records the origin on the first sub-key only; repeated
sub-keys keep the original submode.

Restore functions:

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

Notes (same as the prior plan):

- Use the raw `sr-set-*` setters, not the `ri-extend-set-*` wrappers: the
  wrappers snap point to the unit start outside Extend, which would move the
  cursor on restore.
- `sr-set-node-mode` re-checks the parser; origin `node` proves a parser was
  active when the layer opened, so the check succeeds, and it only moves
  point when seeding from LINE/LINE*, which cannot happen on restore.
- `ri--preserve-selection-for-submode-switch` is safe to run twice in one
  layer cycle (switch to the layer unit, then back): it re-reads current
  bounds and re-anchors each time.
- The setters echo "semantic-regions: X Mode"; this doubles as release
  feedback. Suppress later only if users find it noisy.

### 2. Layer specs and chord setup (ri.el)

In `ri--layer-specs`:

- `?a`: `:tap` → `#'ri-extend-set-line-mode` (was character-mode),
  `:activate-on-press nil`, `:release nil`, `:restore-on-release t`.
  `:label` stays `"CHAR"` — it is the legend title while held and the held
  unit is still CHAR.
- `?s`: `:tap` stays `#'ri-extend-set-word-plus-mode`,
  `:activate-on-press nil`, `:release nil`, `:restore-on-release t`.
  `:label` stays `"WORD+"`.

Extend the spec docstring:

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

`ri-extend-test.el`:

- `ri-extend-test-momentary-char-navigation-records-origin-and-restores` and
  `...-word-plus-navigation-records-origin-and-restores`: keep the
  movement/Extend assertions, but after each momentary command also assert
  `ri--momentary-origin-submode` holds the origin; after
  `ri--restore-momentary-submode`, assert the origin submode is back and
  point has not moved. Under Extend, assert exact selection bounds survive
  the switch and the restore, and point remains on the recorded active edge.

`ri-chord-test.el`:

- `ri-chord-test-navigation-layers-tap-commits-hold-restores`:
  - Spec assertions: `?a` tap is `ri-extend-set-line-mode`, `?s` tap is
    `ri-extend-set-word-plus-mode`; both have `activate-on-press` nil and
    `restore-on-release` t; other layers keep plain `keymap-legend-hide`.
  - Press-only path: after `ri--press-layer` the submode is still the
    tap-start mode; the switch assertion moves to the tap path (press +
    release without a sub-key commits LINE/WORD+).
  - Held path: after `l` and the release event, assert point moved by the
    layer unit and `sr-submode` equals the tap-start mode again, with unit
    bounds recomputed for it.
- `ri-chord-test-hold-a-i-uses-char-highlight`: after
  `kkp-chord--on-release ?a`, assert `sr-submode` is `line` again and the
  highlight covers the LINE unit, not the CHAR unit.

### 4. Update user documentation (README.md)

- Row for `a`: "Select `LINE`; hold with `i` / `j` / `k` / `l` for `CHAR`
  movement, releasing returns to the previous submode".
- Row for `s`: "Select `WORD+`; hold with `i` / `j` / `k` / `l` for `WORD+`
  movement, releasing returns to the previous submode".
- Replace "The selected semantic submode remains active after the layer
  closes" with the tap-commits / hold-restores contract.
- Replace "A quick tap of `a` enters `CHAR`" with "a quick tap of `a` enters
  `LINE`".
- Update `ri--normal-help-map` entries for `a` (`LINE`, hold for CHAR
  navigation) and `s` (`WORD+`, hold for WORD+ navigation).

## Verification

1. Run the focused `ri-extend-test.el` and `ri-chord-test.el` ERT suites.
2. Smoke from NODE: hold `a`, press `i` — point moves up one character; on
   release the mode line reads `NORM[NODE]` and the NODE unit is highlighted
   around the new point.
3. Smoke from WORD: hold `a`, press `k` — one character down; release returns
   to `NORM[WORD]` with point untouched.
4. Smoke the `s` layer symmetrically from WORD/NODE.
5. Smoke a pure tap of `a` and `s`: the mode line commits `LINE` / `WORD+`.
6. Repeat hold navigation inside Extend from each active edge; confirm exact
   selection bounds survive switch and restore and point stays on the edge.
7. Run the repository-wide ERT suite and report unrelated failures separately
   (the known `ri-tabs`/`ri-pairs` red set is expected).

## Acceptance criteria

- Releasing a held `a` or `s` layer restores the pre-layer submode (NODE,
  WORD, LINE, ...).
- A tap of `a` enters `LINE` persistently; a tap of `s` enters `WORD+`
  persistently.
- Held navigation leaves point where the movement put it; only the submode,
  highlight, and mode line change on release.
- The layer legend shows the mode release returns to.
- Extend bounds and active-edge invariants remain intact through switch and
  restore.
- Non-layer keys pressed while holding `a` or `s` are not undone on release.

## Implementation status

Implemented on 2026-08-14.

- `ri-extend.el`: `ri--momentary-origin-submode` recorded on the first
  sub-key of a held layer; `ri--restore-submode` /
  `ri--restore-momentary-submode` restore the origin through the raw
  `sr-set-*` setters (point-safe) with Extend bounds preserved.
- `ri.el`: `?a` tap is now `ri-extend-set-line-mode`, `?s` tap stays
  `ri-extend-set-word-plus-mode`; both use `activate-on-press nil` +
  `restore-on-release t`; the press action derives the release label from
  the current submode and the release action restores it; help-map `a`
  entry updated to `LINE/≡ CHAR`.
- Tests renamed to `...-records-origin-and-restores` /
  `ri-chord-test-navigation-layers-tap-commits-hold-restores`; the
  hold-a-i test now asserts the LINE restore and highlight after release.
- README rows and the momentary-layer contract paragraph updated to the
  tap-commits / hold-restores wording.
- Focused chord + extend suites: 49 tests, 48 passed, 1 skipped
  (grammar-dependent node test), 0 failures.
- Smoke from a tree-sitter NODE buffer: `enter NODE point=2` → `press a`
  stays NODE → `hold a + i` moves to `char point=1` → `release a` restores
  `node point=1`. Tap `a` commits LINE, tap `s` commits WORD+, hold
  `s + l` navigates WORD+ then release restores WORD with point kept.
- Byte-compile of `ri-extend.el` / `ri.el` shows only the two pre-existing
  warnings.
- Repository-wide 261-test run: 218 passed, 32 unexpected, 11 skipped — the
  failures are the known `ri-tabs`/`ri-pairs` set, unchanged by this work.
