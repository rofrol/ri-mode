# Momentary Navigation Must Activate the Temporary Submode — Plan

## Problem

Holding `a` opens the temporary `LINE` layer and shows a legend for vertical
line navigation, but `sr-submode` remains `NODE` until the first layer
movement command runs. The KKP transient map is sparse: when `j` or `l` is not
bound in the LINE map, Emacs falls through to `mini-modal-map`, where those
keys still run NODE sibling navigation.

This is not primarily a missing `ignore` binding. The momentary layer and the
semantic selection submode are being activated at different times. `s` and
`w` hide the mismatch because their maps explicitly bind `j` and `l`.

## Current flow

1. KKP receives the held modifier press.
2. `ri-chord-setup` shows the legend and records only
   `ri--momentary-layer-submode` for the mode line.
3. `sr-submode` stays at its original value (`NODE`, `WORD`, etc.).
4. A bound layer movement later calls `ri--run-momentary-navigation`, which
   records the origin, switches submode, and moves.
5. An unbound key falls through to the original NORM map before step 4.

## Target behavior

- On a held `a`, `s`, or `w`, switch `sr-submode` immediately to the layer's
  temporary submode (`LINE`, `WORD+`, or `CHAR`).
- Preserve the exact original submode as the release target.
- A held `a` from NODE must never use NODE semantics for `j` or `l`; those keys
  resolve through the normal navigation commands while `sr-submode` is LINE,
  where horizontal navigation is unsupported and does not move between nodes.
- A held `s` or `w` continues to use its explicit four-direction layer map.
- On release after a hold, restore the original submode without moving point.
- On a pure tap, restore the original submode first, then dispatch the tap
  action so `a`, `s`, and `w` still commit their persistent modes.
- Extend selection bounds and active-edge invariants remain unchanged.
- No per-key `ignore` workaround is used; the semantic mode determines the
  fallback command's behavior.

## Implementation

### `ri-extend.el`

Reuse the existing raw, no-point-snap submode switch used by
`ri--restore-submode`. Make that switch usable when entering a momentary
layer, and add a small internal operation that:

1. records `sr-submode` in `ri--momentary-origin-submode`;
2. switches to the requested layer submode with the raw semantic-regions
   setter;
3. refreshes the highlight without moving point.

The existing movement runner keeps the recorded origin and continues to use
its movement-specific setter before the first movement. This preserves the
existing snap/movement behavior while making the layer active as soon as the
hold begins.

### `ri.el`

In `ri-chord-setup`, for specs with `:restore-on-release`, activate the
specified `:submode` during `:on-press`, before the legend is shown. Keep the
existing release action so it restores the recorded origin before KKP dispatches
the tap action.

Remove the `j` and `l` `ignore` bindings from `ri--line-layer-map`. Its map
should contain only the actual LINE actions (`i` and `k`); fallback now sees
`sr-submode` LINE rather than NODE.

Do not change KKP event decoding or transient-map fallback globally.

### `ri-chord-test.el`

Update the navigation-layer test:

- pressing a restore-on-release layer immediately changes `sr-submode` to its
  layer submode and records the tap-start submode as the origin;
- a pure release restores the tap-start mode before the tap commits the layer;
- held movement still restores the tap-start mode after release;
- `s` and `w` retain their explicit `j` / `l` bindings;
- LINE no longer has per-key `ignore` bindings.

Replace the fallback regression with a NODE-origin test that enters the `a`
layer, verifies the active submode is LINE, and confirms `j` / `l` resolve to
the normal horizontal commands but cannot navigate NODE siblings while LINE is
active. Verify release restores NODE.

### `ri-extend-test.el`

Add focused coverage for entering a momentary submode without movement:

- from NODE, entering LINE records NODE, switches to LINE, and leaves point
  unmoved;
- restoring returns to NODE at the same point;
- inside Extend, exact bounds and the active edge survive both switches.

Existing movement and restore tests remain valid and continue to cover actual
navigation.

## Verification

Run the focused chord and Extend ERT tests, then the complete
`ri-chord-test.el` and `ri-extend-test.el` files.

Behavioral smoke path:

1. Enter NODE.
2. Hold `a`: the mode line reports NODE(LINE); `i` / `k` move by lines; `j` /
   `l` do not move between sibling nodes.
3. Release `a`: NODE is restored and the highlight follows the new point.
4. Hold `s` and `w`: WORD+ and CHAR movement remain available on all four
   directions and release restores the origin.
5. Tap `a`, `s`, and `w`: persistent mode selection remains unchanged.

## Implementation status

Implemented on 2026-08-14.

- Restore-on-release layers now activate their semantic submode on press using
  the existing no-snap raw setter path.
- Release restores the origin before a pure tap commits its persistent mode.
- LINE has only `i` / `k`; `j` / `l` fall through normally but run while
  `sr-submode` is LINE, so they cannot navigate NODE siblings.
- Added press/restore and Extend-boundary coverage.
- Chord and Extend suites: 52 passed, 0 failed, 1 pre-existing tree-sitter
  skip.
