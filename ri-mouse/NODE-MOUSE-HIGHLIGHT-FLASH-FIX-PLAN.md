# NODE Mouse Highlight Flash Fix Plan

## Problem

In NODE mode, a primary mouse click briefly highlights a larger syntax node before settling on the correct lowest node under the clicked character.

For example, in Odin:

```odin
player_run_texture := rl.LoadTexture("monk.png")
```

Observed behavior:

- clicking `player_run_texture` briefly highlights a larger expression extending through the final `)`, then correctly highlights only `player_run_texture`;
- clicking `LoadTexture` briefly highlights `LoadTexture("monk.png")`, then correctly highlights only `LoadTexture`.

The final selection is correct. The bug is the visible intermediate highlight.

## Current implementation and likely cause

`ri-mouse-set-point` handles only the completed `[mouse-1]` event. It calls `mouse-set-point`, then `sr-retarget-at-position`, which correctly selects `sr--node-lowest-at` and marks it as a direct NODE target.

However, `ri-mouse-setup` deliberately leaves `[down-mouse-1]` unbound in `mini-modal-map`. Therefore the mouse press can fall through to Emacs' normal mouse command before RI receives the completed click.

If that press moves point, `semantic-regions`' buffer-local `post-command-hook` runs `sr--update-highlight`. At that moment no direct mouse target has been installed yet, so NODE resolution uses the normal keyboard-oriented `sr--node-top-at` path. For Odin this can produce exactly the transient ranges being observed:

- the containing expression for an identifier click;
- the call expression for a `LoadTexture` click.

The later `[mouse-1]` event then runs `sr-retarget-at-position`, installs the lowest node, and repaints the correct final highlight.

The fix should make one physical click produce one semantic NODE retarget visually, rather than allowing the press and release phases to expose two different NODE interpretations.

## Goals

1. Eliminate the intermediate larger NODE highlight completely.
2. Preserve the current final behavior: a click selects the lowest real tree-sitter node under the clicked character.
3. Keep point at the clicked buffer position.
4. Do not change keyboard NODE entry or navigation semantics.
5. Do not introduce a delayed repaint, timer, redisplay workaround, or post-hoc correction.
6. Preserve normal non-RI mouse behavior for mode lines, tab bars, fringes, scroll bars, wheel events, and non-text UI areas.
7. Preserve drag behavior unless a minimal RI-specific press handler is proven necessary for correct click dispatch.

## Implementation plan

### 1. Reproduce and instrument the complete primary-button event sequence

Add focused diagnostics/tests around the press/release path rather than looking only at `ri-mouse-set-point`.

For an editable RI NORM buffer in NODE mode, determine which commands actually run for:

- `[down-mouse-1]`;
- `[mouse-1]`;
- `[drag-mouse-1]` when the pointer moves before release.

Record, at each phase:

- point;
- `this-command`;
- `sr--node-current` bounds;
- `sr--node-direct-target-p`;
- bounds requested by `ri--highlight-bounds` / `sr--update-highlight`.

Confirm that the transient larger highlight is produced between the press and completed click. The implementation should be based on this confirmed event sequence, not on adding an arbitrary extra highlight refresh.

### 2. Prevent the press phase from publishing a semantic NODE selection

Introduce a small mouse-gesture state in `ri-mouse`, buffer/window scoped as appropriate, representing an in-progress primary click in an RI text buffer.

The important invariant is:

> moving or preparing point during `down-mouse-1` must not cause NODE's keyboard-oriented `sr--node-top-at` result to become visible before the completed click installs the direct lowest-node target.

Prefer a solution in the mouse integration layer, because the unwanted state exists only during a mouse gesture. Do not weaken `semantic-regions` globally by changing normal NODE point-following semantics.

Two implementation shapes are acceptable, in this order of preference:

1. **Minimal press handler:** bind `[down-mouse-1]` in RI NORM text buffers to a small RI command that records the gesture and prevents the ordinary post-command semantic repaint, while leaving completed click positioning to the existing `[mouse-1]` path.
2. **Scoped highlight suppression:** if native press handling is required to preserve drag semantics, allow the native press command to run but suppress only RI semantic highlight publication while the primary gesture is pending; the completed click must immediately clear the suppression and perform the real retarget.

Do not solve this by hiding all overlays globally or disabling `post-command-hook` for an uncontrolled period.

### 3. Make the completed click an atomic semantic transition

Refactor the completed-click path so the visible model changes in this order:

1. validate that the event targets buffer text in a live window;
2. position point using Emacs' native event decoding;
3. exit Extend if necessary;
4. resolve the final semantic target exactly once;
5. install NODE direct-target state;
6. publish the highlight once using the final bounds;
7. clear any pending mouse-gesture state even if resolution fails.

For NODE, the resolution must remain `sr--node-lowest-at` at the clicked position. Do not call or temporarily expose `sr--node-top-at` during this transaction.

Where practical, separate "compute/install target state" from "render highlight" so tests can prove that no intermediate bounds are rendered.

### 4. Keep keyboard NODE semantics unchanged

Do not modify the existing meaning of:

- switching into NODE from LINE/WORD/etc.;
- `sr--node-top-at`;
- NODE Up/Down/Left/Right navigation;
- direct-target lifetime after a completed mouse click.

The fix is specifically about mouse gesture staging. Keyboard commands should continue to repaint through the normal `post-command-hook` path.

### 5. Handle aborted and non-click gestures safely

A press guard must never leave highlighting permanently suppressed.

Clear pending gesture state on all relevant endings, including:

- successful `[mouse-1]`;
- a drag sequence;
- a click that resolves to non-text UI;
- switching buffers/windows during the gesture where Emacs permits it;
- errors during native point movement or tree-sitter resolution;
- mode disable / RI teardown if needed.

Use `unwind-protect` around the completed semantic transaction when this simplifies guaranteed cleanup.

### 6. Preserve drag and native mouse behavior

Do not bind unrelated mouse events just to make the flash disappear.

Specifically verify that:

- `[drag-mouse-1]` still reaches normal Emacs behavior when RI does not intentionally implement a drag semantic;
- mode-line, tab-bar, fringe, scroll-bar, and wheel events remain untouched;
- INST mode keeps native mouse behavior and does not invoke RI semantic retargeting;
- clicking into another editable RI window still selects that window and targets the clicked node correctly.

If binding `[down-mouse-1]` is necessary, make that binding narrowly responsible for the primary-click staging problem rather than turning `ri-mouse` into a replacement mouse subsystem.

## Tests

### `ri-mouse/ri-mouse-test.el`

Add tests covering the gesture as a sequence, not just the final `mouse-1` callback.

Required cases:

1. A primary press followed by completed click in NODE mode produces only one published semantic highlight: the final lowest-node bounds.
2. No keyboard/top-node bounds are rendered between press and release.
3. Completed click still calls native point positioning before semantic retargeting.
4. Pending press state is cleared after a successful click.
5. Pending press state is cleared after errors or aborted/non-text completion.
6. INST mode does not start RI semantic mouse staging.
7. Non-text UI events do not start or finish an RI semantic selection.
8. Drag dispatch remains available and does not leave the semantic highlight suppressed.

Use stubs around the highlight renderer (for example `sr--render-highlight-bounds`) to capture every bounds value that would actually become visible. The regression test must fail if both a larger intermediate range and the final leaf range are rendered, even if the final state is correct.

### `semantic-regions/semantic-regions-test.el`

Keep or add focused tests proving that direct spatial targeting itself is already correct:

- identifier click position resolves to the identifier leaf;
- function-name click position resolves to the function-name leaf rather than the call expression;
- `sr--node-direct-target-p` retains that lowest node while point remains inside it.

These tests should distinguish resolver correctness from mouse-event ordering.

### Odin regression fixture

Add a tree-sitter-backed Odin regression when the Odin grammar is available in the test environment, using:

```odin
player_run_texture := rl.LoadTexture("monk.png")
```

Assert at minimum:

- click inside `player_run_texture` -> only `player_run_texture` is ever published as the click highlight;
- click inside `LoadTexture` -> only `LoadTexture` is ever published as the click highlight;
- `LoadTexture("monk.png")` is never published as an intermediate click highlight.

If CI cannot guarantee an Odin grammar, keep the core event-order regression grammar-independent and make the Odin test conditional rather than omitting the behavior from the plan.

## Validation

Run the package's ERT suites after the change, including at least:

```sh
emacs -Q --batch \
  -L mini-modal \
  -L semantic-regions \
  -L ri-mouse \
  -L . \
  -l ri-mouse/ri-mouse-test.el \
  -f ert-run-tests-batch-and-exit
```

Also run the existing `semantic-regions` and RI integration tests using the repository's normal test command/load paths.

Perform a manual GUI/terminal check in Odin because this bug is redisplay-sensitive:

1. enter NODE mode;
2. repeatedly click different characters inside `player_run_texture`;
3. repeatedly click different characters inside `LoadTexture`;
4. verify visually that there is no one-frame expansion to the assignment/call expression;
5. click and drag to verify that drag behavior has not regressed;
6. click in another window and in non-text UI areas to verify normal dispatch.

## Acceptance criteria

The change is complete when all of the following are true:

1. Clicking `player_run_texture` in NODE mode highlights only `player_run_texture` from the first visible repaint after the gesture.
2. Clicking `LoadTexture` highlights only `LoadTexture`; `LoadTexture("monk.png")` is never visibly highlighted as an intermediate state.
3. A physical click causes one semantic mouse retarget, not a visible press-phase top-node selection followed by a release-phase lowest-node selection.
4. The final selected node remains the deepest real tree-sitter node under the clicked character.
5. Keyboard NODE behavior is unchanged.
6. Drag, INST-mode mouse handling, other windows, and non-text UI mouse behavior remain intact.
7. Automated tests detect any future reintroduction of an intermediate rendered highlight, not merely an incorrect final state.

## Implementation status

Implemented on 2026-08-13.

The chosen implementation is the minimal press-handler variant from this plan:

- `[down-mouse-1]` is now bound to `ri-mouse-primary-down`;
- the press handler intentionally does not call `mouse-set-point` and does not retarget semantic state;
- `[mouse-1]` remains the single transaction that first positions point natively and then calls `sr-retarget-at-position`;
- `[drag-mouse-1]`, wheel events, and unrelated mouse gestures remain unbound in `mini-modal-map`;
- regression coverage asserts that a NODE press/release sequence renders the lowest direct target and never renders the larger keyboard-oriented top node.

This avoids adding timers, redisplay delays, or global changes to `semantic-regions` NODE semantics.
