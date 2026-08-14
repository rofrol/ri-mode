# Momentary CHAR and WORD+ Navigation Plan

## Problem

Persistent semantic submodes are useful for editing whole units, but changing
submode only to make a short local movement adds unnecessary key presses.

The required gestures are:

- keep `a` as the persistent `LINE` selector when tapped, but use `CHAR`
  movement while it is held;
- keep `s` as the persistent `WORD` selector when tapped, but use `WORD+`
  movement while it is held.

## Behavior

### Held `a`

`a` remains a tap-hold key:

- tap `a` → switch persistently to `LINE`;
- hold `a` + `i` / `k` → move up / down with existing `CHAR` semantics;
- hold `a` + `j` / `l` → move left / right by one character.

### Held `s`

`s` becomes a tap-hold key:

- tap `s` → switch persistently to `WORD`;
- hold `s` + `i` / `k` → move up / down with existing `WORD+` semantics;
- hold `s` + `j` / `l` → move left / right by one `WORD+` unit, including
  punctuation as its own unit.

Each borrowed movement leaves the persistent `sr-submode` unchanged. Repeated
movement keys work while the layer key remains held.

## Implementation

### Shared borrowed-navigation wrapper

`ri-extend.el` owns one small wrapper that:

1. preserves exact Extend bounds before borrowing another submode;
2. dynamically binds `sr-submode` to `char` or `word-plus`;
3. invokes the existing RI navigation command;
4. preserves the moved Extend bounds before restoring the persistent submode;
5. refreshes the highlight under the persistent submode.

This reuses existing CHAR/WORD+ navigation rather than duplicating movement
logic or introducing press/release submode state. A tap therefore cannot move
point before its persistent LINE/WORD setter runs.

Extend must retain its exact bounds and active edge. Point remains on the last
selected character for the `end` edge and the first selected character for the
`start` edge.

### Layer maps

`ri.el` defines two four-key maps:

```text
a held: i/j/k/l → CHAR up/left/down/right
s held: i/j/k/l → WORD+ up/left/down/right
```

`ri--layer-specs` remains the single registration source:

- `a`: label `CHAR`, tap action `ri-extend-set-line-mode`, release label
  `LINE`;
- `s`: label `WORD+`, tap action `ri-extend-set-word-mode`, release label
  `WORD`.

`ri-enable` binds both `a` and `s` through `ri--press-layer`. No timer,
duration threshold, new dependency, or second transient-map system is added.

### Clean cutover

Remove the superseded NODE-specific source-line resolver, navigation commands,
and tests. Held `a` no longer means “find the first NODE on another line”; it
means exactly “run this movement as CHAR.”

## Coverage

Focused ERT coverage must prove:

- held-`a` commands move horizontally by one character and vertically with
  CHAR behavior;
- held-`s` horizontal movement follows WORD+ punctuation behavior and vertical
  movement follows WORD+ line targeting;
- both borrowed modes leave the persistent submode unchanged;
- CHAR movement under Extend changes exact selection bounds one character at a
  time without changing the active edge;
- tap `a` still enters LINE and tap `s` still enters WORD;
- both KKP maps expose exactly `i`, `j`, `k`, and `l`;
- an intervening movement suppresses the tap action on release.

## Documentation

Update the README navigation table and momentary-layer description with both
tap/hold contracts. Keep `W` as the persistent CHAR selector and `M-s` as the
persistent WORD+ selector.

## Verification

Run the focused RI Extend/chord suites, smoke both held-unit movement paths,
and follow the repository startup-performance workflow because `ri-enable`
changes. Run the repository-wide ERT suite and report unrelated failures
separately from this feature's focused result.

## Implementation status

Implemented on 2026-08-14.

- Held `a` now borrows CHAR `i` / `j` / `k` / `l`; tap `a` still enters LINE.
- Held `s` now borrows WORD+ `i` / `j` / `k` / `l`; tap `s` still enters WORD.
- Removed the superseded NODE-specific source-line implementation and tests.
- The affected 111-test suite completed with 102 passes, zero failures, and
  nine grammar-dependent skips.
- Smoke result:
  `char-point=2 char-mode=line word+-point=6 word+-char=, word+-mode=char`.
- Startup showed no material regression: load increment
  `115.528 → 124.500 ms` (`+8.972 ms`, `+7.766%`) and enable increment
  `50.472 → 50.576 ms` (`+0.104 ms`, `+0.206%`).
- The repository-wide 263-test run remains red on the same 32 failures
  confined to unrelated `ri-tabs`/`ri-pairs` behavior; all tests covering
  these momentary layers passed.
