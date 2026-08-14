# Momentary CHAR on `w`, LINE back on `a` — Plan

## Problem

Commit `07a481c` made `a` a tap-hold key: tap `a` selects persistent `LINE`,
hold `a` + `i` / `j` / `k` / `l` navigates with `CHAR` movement. The user wants
to undo the hold side of that change:

- move the momentary `CHAR` layer from `a` to `w`;
- restore `a` to the momentary `LINE` layer it was before `07a481c`
  (commit `9e436ef` state: hold `a` + `i` / `k` moves by source lines).

`w` currently has no layer: it is a plain `SUBWORD` selector
(`ri-extend-set-subword-mode` in the NORM help map and `mini-modal-map`).

## Current state

| Key | Tap | Hold layer | Map | Restore on release |
| --- | --- | --- | --- | --- |
| `a` | `ri-extend-set-line-mode` | `CHAR` | `ri--char-layer-map` (`i j k l`) | yes |
| `s` | `ri-extend-set-word-plus-mode` | `WORD+` | `ri--word-plus-layer-map` (`i j k l`) | yes |
| `w` | `ri-extend-set-subword-mode` (plain, no layer) | — | — | — |
| `W` | `ri-extend-set-character-mode` | — | — | — |
| `M-s` | `ri-extend-set-word-plus-mode` | — | — | — |

## Target behavior

| Key | Tap | Hold layer | Map |
| --- | --- | --- | --- |
| `a` | `ri-extend-set-line-mode` (unchanged) | `LINE` | `ri--line-layer-map` (`i k`) |
| `s` | unchanged | `WORD+` | unchanged |
| `w` | `ri-extend-set-subword-mode` (unchanged) | `CHAR` | `ri--char-layer-map` (`i j k l`) |

`W` (persistent CHAR) and `M-s` (persistent WORD+) stay as they are.

Held movement uses the existing momentary machinery: the origin submode is
recorded on the first sub-key, the layer submode is active while held, and
release restores the origin submode without moving point.

### Decisions

1. **`w` keeps its `SUBWORD` tap.** The tap-hold duality is the established
   pattern (`a` taps LINE while its hold layer is CHAR; `s` taps WORD+).
   Dropping or relocating the `SUBWORD` selector was not requested and would
   remove functionality. Rejected alternatives: tap `w` = CHAR (orphans
   SUBWORD with no NORM binding), move SUBWORD to another key (no free key
   with an obvious spot).
2. **Do not resurrect the pre-`07a481c` NODE-specific line navigation**
   (`ri-extend-nav-line-up/down`, `ri--run-node-line-navigation`,
   `sr-nav-node-line-*`). Those were deliberately removed as superseded by
   the momentary layer machinery. The `restore-on-release` mechanism already
   returns to NODE on release, so a plain "run this movement as LINE" layer
   gives the same NODE-mode benefit (line movement without leaving NODE)
   with less code. The LINE map has only `i` / `k`: line units have no
   horizontal movement, matching the pre-`07a481c` two-key map.

## Implementation

### `ri-extend.el`

Add the two LINE momentary commands next to `ri-momentary-char-*`:

```elisp
(defun ri-momentary-line-up ()
  (interactive)
  (ri--run-momentary-navigation #'ri-extend-set-line-mode
                                 #'ri-extend-nav-up))
(defun ri-momentary-line-down ()
  (interactive)
  (ri--run-momentary-navigation #'ri-extend-set-line-mode
                                 #'ri-extend-nav-down))
```

`ri-momentary-char-*` and `ri-momentary-word-plus-*` are unchanged; only the
key they are reached through changes.

Update the `ri--momentary-origin-submode` docstring to mention the LINE layer
("momentary LINE/CHAR/WORD+ layer").

### `ri.el`

Add the LINE layer map next to `ri--char-layer-map` / `ri--word-plus-layer-map`:

```elisp
(defvar ri--line-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "i" '(menu-item "LINE ^" ri-momentary-line-up))
    (define-key map "k" '(menu-item "LINE v" ri-momentary-line-down))
    map)
  "Keymap for momentary LINE navigation (a held).")
```

Update `ri--char-layer-map` docstring: "(w held)".

Update `ri--layer-specs`:

- `a`: `:label` `"CHAR"` → `"LINE"`, `:map` `ri--char-layer-map` →
  `ri--line-layer-map`. `:tap`, `:restore-on-release t`, `:release nil`
  unchanged.
- `s`: unchanged.
- add after `s`:

```elisp
   (list :key ?w
         :label "CHAR"
         :tap #'ri-extend-set-subword-mode
         :activate-on-press nil
         :restore-on-release t
         :map ri--char-layer-map
         :release nil)
```

`ri--normal-help-map` (legend only; the actions are documentation):

- `a`: `'(menu-item "LINE / hold: ^ v" ri-extend-set-line-mode)`
  (the pre-`07a481c` form);
- `w`: `'(menu-item "SUBWORD / hold: CHAR" ri-extend-set-subword-mode)`.

`mini-modal-map`:

- `w`: `ri-extend-set-subword-mode` → `ri--press-layer` (`a` and `s` already
  go through `ri--press-layer`).

`ri-chord-setup` picks up the new `w` spec automatically (it iterates
`ri--layer-specs`).

## Coverage

### `ri-chord-test.el`

`ri-chord-test-navigation-layers-tap-commits-hold-restores`:

- spec data: `?a` → label `"LINE"`, map `ri--line-layer-map`; keep `?s`;
  add `?w` → label `"CHAR"`, tap `ri-extend-set-subword-mode`, map
  `ri--char-layer-map`, right `ri-momentary-char-right`, `:restore-on-release`
  set, `:release` nil.
- the `i j k l` commandp loop applies to the `w` and `s` maps; the LINE map
  asserts `i` / `k` commandp and `(lookup-key map "k")` =
  `ri-momentary-line-down`.
- help-map assertions: keep `"a"` → `ri-extend-set-line-mode`, add `"w"` →
  `ri-extend-set-subword-mode`.
- release data (buffer becomes `"alpha,beta\ngamma\n"` so line-down has a
  target):
  - `(?w "119;:3u" line char ri-momentary-char-right 2)` — the old `?a`
    case with keycode 119 (`w`);
  - `(?a "97;:3u" char line ri-momentary-line-down 11)` — hold sub-key
    `"k"`, line-down to line 2 start;
  - `(?s "115;:3u" char word-plus ri-momentary-word-plus-right 6)` —
    unchanged.
- tap assertion becomes a `pcase`: after tap, `sr-submode` is `line` for
  `a`, `subword` for `w`, `word-plus` for `s`.

`ri-chord-test-hold-a-i-uses-char-highlight` → rename to
`ri-chord-test-hold-w-i-uses-char-highlight`; press `?w` instead of `?a` and
`(key-binding "i")` stays `ri-momentary-char-up`.

Add `ri-chord-test-hold-a-k-uses-line-highlight`: from `sr-submode 'line`
on `"ab\ncd"`, press `?a`, `(key-binding "k")` is `ri-momentary-line-down`,
point moves to line 2, the whole line 2 is highlighted, `sr-submode` is
`line`; release restores the origin submode without moving point.

### `ri-extend-test.el`

Add `ri-extend-test-momentary-line-navigation-records-origin-and-restores`,
mirroring the CHAR test:

- from `sr-submode 'char` on `"ab\ncd"`, `ri-momentary-line-down` → point on
  line 2, `sr-submode` `'line`, `ri--momentary-origin-submode` `'char`;
  `ri-momentary-line-up` → point back on line 1;
- after `ri--restore-momentary-submode`: `sr-submode` `'char`, point
  unmoved, `ri--momentary-origin-submode` nil;
- under Extend: exact selection bounds survive the switch and the restore,
  point stays on the recorded active edge.

The existing CHAR and WORD+ momentary tests are unchanged (they drive
`ri-momentary-char-*` / `ri-momentary-word-plus-*` directly, independent of
the key).

## Documentation

`README.md`:

- table row `a`: `Select `LINE`; hold with `i` / `k` for `LINE` movement`;
- table row `w`: `Select `SUBWORD`; hold with `i` / `j` / `k` / `l` for
  `CHAR` movement`;
- momentary-layer paragraph: hold `w` with `i` / `j` / `k` / `l` for CHAR,
  hold `a` with `i` / `k` for LINE, hold `s` for WORD+;
- quick-tap sentence: tap `a` enters `LINE`, tap `w` enters `SUBWORD`, tap
  `s` enters `WORD+`.

This plan supersedes the key layout documented in
`MOMENTARY-LINE-NAVIGATION-PLAN.md`, which now describes the reverted
state; leave that file untouched as history.

## Verification

- Focused suites: `ri-chord-test.el`, `ri-extend-test.el`.
- Smoke both hold paths in an interactive RI session: `w` + `i`/`j`/`k`/`l`
  moves by characters and releases back to the origin submode; `a` + `i`/`k`
  moves by lines from NODE and returns to NODE on release; taps `a`, `w`,
  `s` still switch to LINE, SUBWORD, WORD+.
- Follow `.agents/skills/ri-startup-performance/SKILL.md` because the change
  touches `ri.el` top-level definitions and `ri-enable` bindings; expected
  cost is negligible (one new keymap defvar and one layer-spec entry).
- The repository-wide suite has pre-existing unrelated failures in
  `ri-tabs`/`ri-pairs`; report focused results separately.

## Implementation status

Implemented on 2026-08-14.

- `a` is again the momentary LINE layer (hold `a` + `i` / `k`); tap `a` still
  enters LINE.
- `w` is the momentary CHAR layer (hold `w` + `i` / `j` / `k` / `l`); tap `w`
  still enters SUBWORD.
- `s`, `W`, and `M-s` are unchanged.
- Focused `ri-chord-test.el` + `ri-extend-test.el` run: 50 passed, 0 failed,
  1 skipped (pre-existing tree-sitter grammar skip).
- Smoke through `ri--press-layer`: `w` + `i` moves to point 1 in CHAR and
  releases back to `char`; `a` + `k` moves to line 2 (bounds `(4 . 6)`) and
  releases back to `char`; tap `w` commits `subword`, tap `a` commits `line`.
- Byte-compile clean apart from two pre-existing cross-file warnings.
- NODE-origin smoke could not run here (no elisp tree-sitter grammar); the
  restore path is submode-agnostic, and the repository-wide suite has
  pre-existing unrelated `ri-tabs`/`ri-pairs` failures.
