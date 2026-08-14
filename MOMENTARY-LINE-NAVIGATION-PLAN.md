# Momentary LINE Navigation Plan

## Problem

RI overloads `i` / `k` according to the active semantic submode. In `LINE`,
`WORD`, and related text units they move vertically through physical lines. In
`NODE`, they traverse the tree-sitter hierarchy: Up selects a parent node and
Down selects its first child.

That NODE behavior is useful while descending into code structure, but it
makes a common local correction expensive:

1. switch to `NODE` with `d`;
2. descend to a deeply nested syntax node and edit it;
3. need to move to the preceding source line;
4. switch to `LINE` or `WORD`, move up, then press `d` to return to NODE.

The repeated persistent submode changes are ceremony. The existing `.` command
is not a substitute: it jumps to the nearest tree-sitter parent line, not the
immediately preceding navigable source line.

## Decision

Make `a` a tap-or-hold LINE key:

- tap `a`: keep the current behavior and switch persistently to `LINE`;
- hold `a`, press `i`: move to the preceding navigable source line, then remain
  in the original submode;
- hold `a`, press `k`: move to the following navigable source line, then remain
  in the original submode;
- while `a` remains held, repeated `i` / `k` presses repeat the movement.

For the motivating case, `a+i` from `NODE` means “move up using LINE geometry,
but keep NODE selected.” The destination is the first horizontally traversable
NODE target on the destination line. The mode line must still show
`NORM[NODE]`, and ordinary `i` / `k` must immediately resume NODE parent/child
navigation.

This uses RI's existing KKP tap-hold system. It does not add a new modifier,
prefix menu, transient submode state, or a general temporary-unit framework.

## User-visible contract

Given:

```elisp
(defun outer ()
  (let ((value (compute)))
    (consume value)))
```

with NODE focused on `consume`:

```text
hold a, press i, release a
```

must:

1. move to the preceding navigable source line;
2. select the first traversable NODE target on that line using the existing
   NODE horizontal-target rules;
3. leave `sr-submode` equal to `node`;
4. leave subsequent `i`, `k`, `j`, and `l` with their existing NODE semantics.

Additional rules:

- Blank lines and lines without a traversable NODE target are skipped.
- At the beginning or end of the buffer, the command is an exact no-op: point,
  NODE cache, virtual-string state, selection bounds, and active edge remain
  unchanged.
- A tap of `a` still switches to persistent `LINE`; no existing key sequence is
  removed.
- Ordinary `i` / `k` in NODE remain parent/child navigation.
- `.` remains the Ki-style parent-line command.
- Outside NODE, held-`a` vertical movement delegates to the existing vertical
  command. LINE, WORD, SUBWORD, and CHAR therefore retain their current line
  behavior; PARAGRAPH retains its current “not defined” message.
- The first change covers vertical LINE movement only. Do not add held `s`,
  held `d`, horizontal LINE actions, first/last actions, or a configurable
  temporary-submode registry without a concrete follow-up workflow.

## Implementation plan

### 1. Add explicit NODE-by-source-line movement

Update `semantic-regions/semantic-regions.el` with the smallest internal
movement path needed by the feature, conceptually one shared directional
helper plus two commands such as:

```text
sr-nav-node-line-up
sr-nav-node-line-down
```

The helper should:

1. require the active submode to be `node`;
2. keep the origin point and all NODE state untouched while searching;
3. walk physical lines in the requested direction, applying the same blank-line
   policy as existing LINE vertical navigation;
4. derive the candidate LINE bounds;
5. reuse `sr--node-first-target-in-region` to find the first NODE target wholly
   associated with that line;
6. therefore reuse `sr--node-horizontal-target-p` indirectly, preserving the
   existing treatment of named nodes, anonymous word-like tokens, and
   punctuation-only tokens;
7. commit movement only after a valid target is found by clearing virtual-node
   state, storing the target in `sr--node-current`, setting
   `sr--node-direct-target-p` for ordinary keyboard navigation, moving point to
   the target start, and refreshing the highlight.

Do not use `sr-retarget-at-position` for this transition. That function
intentionally selects the lowest spatial node for mouse/direct targeting,
whereas this command needs the already-established LINE → NODE rule: the first
horizontally traversable target in the line.

Do not implement this by temporarily assigning `sr-submode` to `line` and then
switching back. A failed movement could otherwise destroy or reinterpret the
current NODE target, and Extend would observe two semantic-mode transitions
for one navigation command.

### 2. Route the movement through RI's Extend wrapper

Add two thin interactive commands in `ri-extend.el`, for example:

```text
ri-extend-nav-line-up
ri-extend-nav-line-down
```

When `sr-submode` is `node`, each command must call the corresponding new
semantic-regions movement through `ri--run-extend-navigation`. This reuses the
existing undo record, preserved-boundary cleanup, highlight refresh, and active
edge snapping.

For every non-NODE submode, delegate directly to `ri-extend-nav-up` or
`ri-extend-nav-down`; do not duplicate the existing LINE/WORD/CHAR dispatch.

Extend behavior is part of the contract:

- changing submode is not part of the command;
- the destination NODE contributes its complete bounds to the selection;
- point ends on the last selected character for the `end` edge and on the first
  selected character for the `start` edge;
- only `ri-swap-cursor` may change the active edge;
- a boundary no-op must not change selection bounds or add a false movement.

### 3. Turn `a` into a tap-hold layer

In `ri.el`:

1. add a small `ri--line-layer-map` containing only:
   - `i` → momentary LINE Up;
   - `k` → momentary LINE Down;
2. add `?a` to `ri--layer-specs` with:
   - label `LINE`;
   - tap action `ri-extend-set-line-mode`;
   - map `ri--line-layer-map`;
   - release label suitable for the existing legend;
3. let `ri-chord-setup` register `a` exactly like the existing `c`, `r`, `e`,
   `g`, `t`, `v`, `x`, and `z` layers;
4. remove the later direct `a` binding in `ri-enable` that would overwrite the
   chord fallback, or replace it with the same `ri--press-layer` binding owned
   by the layer specification;
5. update `ri--normal-help-map` so the `a` entry advertises both tap-to-LINE and
   held vertical LINE movement.

Reuse the current `kkp-chord` lifecycle. In particular, the tap action must run
only when `a` is released without an intervening key, and the held map must
remain active until release. Do not add timers, key-duration thresholds, new
held-key state, or another transient-map implementation.

### 4. Add focused semantic-regions tests

Add ERT cases in `semantic-regions/semantic-regions-test.el` covering:

- NODE line-up selects the first traversable node on the preceding source line;
- NODE line-down performs the inverse;
- blank and punctuation-only lines are skipped;
- an anonymous word-like Elisp head remains a valid destination while `(` does
  not;
- `sr-submode` remains `node`;
- subsequent ordinary NODE Up/Down and Left/Right use the committed target;
- movement at buffer boundaries leaves point and all NODE state unchanged;
- movement out of a synthetic string-content node clears virtual state only
  after a destination is found.

Use an available tree-sitter grammar and the repository's existing guarded
NODE-test pattern. Do not mock tree-sitter for the main behavior.

### 5. Add RI and chord integration tests

Add focused tests in `ri-extend-test.el` for the real wrapper:

- normal NODE movement through `ri-extend-nav-line-up` / Down keeps NODE active;
- Extend moves only when the destination preserves the active edge: an `end`
  edge cannot move upward before the selection, and a `start` edge cannot move
  downward past it until `ri-swap-cursor` changes the edge;
- after a successful move, the `end` edge is on the destination node's last
  character and the `start` edge is on its first character;
- a boundary no-op preserves exact selection bounds and point.

Extend `ri-chord-test.el` to prove:

- the `a` layer specification uses `ri-extend-set-line-mode` as its tap action;
- tapping `a` still switches persistently to LINE;
- holding `a` and pressing `i` or `k` dispatches the momentary commands and
  suppresses the tap action on release;
- repeated movement keys work before release;
- the normal help/legend map exposes only the planned `i` / `k` actions.

Test behavior and KKP dispatch state, not source text or implementation names.

### 6. Update user documentation

Update the navigation table and tap-hold section in `README.md`:

- `a` switches to LINE when tapped;
- holding `a` and pressing `i` / `k` performs vertical LINE movement without
  leaving the current semantic submode;
- ordinary NODE `i` / `k` and `.` retain their structural meanings.

Keep the description to the actual two actions. Do not document speculative
WORD or NODE layers.

### 7. Verify behavior and startup cost

Because the implementation changes `ri-enable`, follow the repository's
`ri-startup-performance` skill:

1. record the required `before` benchmark immediately before editing;
2. run the focused semantic-regions, Extend, and chord ERT tests after the
   implementation;
3. run the actual RI interaction in a tree-sitter-enabled buffer and observe
   `NODE → hold a+i → still NODE → ordinary NODE navigation`;
4. record the required `after` benchmark with the same environment and compare
   it under the skill's regression policy;
5. run the full repository ERT suite only after the focused behavior passes.

The layer adds no dependency and should have no material startup cost, but the
measurement is required because `ri-enable` is startup-sensitive.

## Acceptance criteria

The change is complete when:

- from a deeply selected NODE, held `a` plus `i` reaches the preceding
  navigable source line without a persistent mode switch;
- held `a` plus `k` moves in the opposite direction;
- the destination is a valid, horizontally traversable NODE target from that
  line;
- the mode line remains `NORM[NODE]` and normal NODE navigation continues from
  the destination;
- tap `a`, ordinary `i` / `k`, and `.` preserve their existing behavior;
- blank/targetless lines and buffer boundaries behave as specified;
- both Extend edges satisfy the repository selection invariants;
- help and README describe the new gesture;
- focused tests, the interaction smoke check, the startup comparison, and the
  full ERT suite pass.

## Deliberate non-goals

No general momentary-submode framework. No held WORD or NODE selector keys. No
new customization variable. Add another borrowed-unit gesture only after a
specific workflow demonstrates that the two LINE motions are insufficient.

## Implementation status

Implemented on 2026-08-14.

- Added held-`a` LINE Up/Down navigation while preserving the active submode.
- NODE destinations reuse the existing first-traversable-target rule, skip
  blank/targetless lines, preserve virtual NODE state on boundary no-ops, and
  keep subsequent NODE traversal anchored to the committed target.
- Extend preflights destination bounds so movement cannot detach point from
  the active edge.
- Added semantic-regions, RI, and chord regression coverage and updated the
  help map and README.
- The affected 112-test suite completed with 103 passes, zero failures, and
  nine grammar-dependent skips. The interaction smoke check reported
  `submode=node line-target=alpha node-right=one`.
- Startup comparison found no material change: load increment
  `117.644 → 113.996 ms` and enable increment `44.552 → 48.101 ms`.
- The repository-wide 264-test run remains red on 32 failures confined to
  unrelated `ri-tabs`/`ri-pairs` behavior; all tests covering this feature passed.
