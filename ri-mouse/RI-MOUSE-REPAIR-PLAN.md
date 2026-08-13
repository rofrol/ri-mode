# RI Mouse Selection Repair Plan

## Objective

Fix mouse positioning in RI based on observed Emacs input behavior rather than assuming that adding bindings to `mini-modal-map` is sufficient.

The required end state is:

1. In NORM, a primary-button click on editable buffer text moves point to the clicked buffer position.
2. The RI semantic highlight follows that position immediately.
3. In NODE mode, the click selects the deepest/lowest real tree-sitter node at the clicked character.
4. Subsequent NODE navigation starts from that clicked node.
5. INST keeps normal Emacs mouse behavior.
6. Mouse behavior remains implemented as the separate `ri-mouse` package in the `ri-mouse/` directory.

## Why the previous fix is not sufficient

The current implementation proves only that these bindings were inserted into `mini-modal-map`:

```elisp
[down-mouse-1] -> ri-mouse-set-point
[mouse-1]      -> ri-mouse-set-point
```

The current ERT test also checks only `lookup-key` on that map.

That does **not** prove any of the following:

- that the terminal/GUI actually delivers `down-mouse-1` or `mouse-1` to Emacs;
- that Emacs mouse support is enabled in the current terminal session;
- that another active keymap has higher precedence than `mini-modal-map`;
- that the event is translated into another mouse event before command lookup;
- that `ri-mouse-set-point` is actually invoked;
- that `mouse-set-point` receives a usable text position;
- that the click reaches the intended window/buffer;
- that semantic retargeting succeeds after point movement.

The next repair must therefore diagnose the complete event path first and only then change code.

---

## Phase 1 — Determine whether Emacs receives a mouse event at all

### 1.1 Inspect the real runtime environment

Record, in the same Emacs instance where RI fails:

```elisp
(window-system)
(display-graphic-p)
(bound-and-true-p xterm-mouse-mode)
(bound-and-true-p mini-modal-mode)
(bound-and-true-p sr-mode)
```

The distinction between GUI Emacs and terminal Emacs is critical.

RI is used in a Kitty-terminal-oriented setup, so terminal mouse input must be treated as a first-class case rather than assuming GUI mouse events.

### 1.2 Capture the raw event

Temporarily execute:

```elisp
(read-event "Click mouse-1 now: ")
```

Then click once in ordinary buffer text.

Record the exact returned event.

Expected possibilities include events such as:

- `down-mouse-1`;
- `mouse-1`;
- a terminal mouse event represented differently;
- no mouse event at all.

Do not modify RI mouse bindings until this is known.

### 1.3 Terminal-specific check

If Emacs is running in Kitty/another terminal and `read-event` does not receive a normal mouse event, verify whether terminal mouse reporting is enabled.

Test explicitly with:

```elisp
(xterm-mouse-mode 1)
```

Then repeat `read-event`.

If this is the missing layer, decide where responsibility belongs:

- preferably `ri-mouse` detects terminal Emacs and enables the standard Emacs terminal mouse facility when RI mouse support is enabled;
- alternatively document it as a prerequisite only if enabling it from RI would be inappropriate.

The package must not implement terminal escape-sequence parsing itself. Use Emacs' existing mouse support.

### Acceptance gate for Phase 1

Do not proceed until a physical click produces a known Emacs event containing a valid text/window position.

---

## Phase 2 — Determine which command Emacs actually resolves for the click

Once the raw event is known, inspect the binding in the failing buffer rather than only in `mini-modal-map`.

### 2.1 Compare map-local and effective bindings

For the actual event, inspect both:

```elisp
(lookup-key mini-modal-map [mouse-1])
(key-binding [mouse-1] t)
```

and, if the press event exists:

```elisp
(lookup-key mini-modal-map [down-mouse-1])
(key-binding [down-mouse-1] t)
```

`key-binding` is the important result because it follows active keymap precedence.

### 2.2 Inspect active map precedence

Check whether any of these override `mini-modal-map`:

- `overriding-terminal-local-map`;
- `overriding-local-map`;
- emulation-mode maps;
- minor-mode overriding maps;
- other minor-mode maps;
- local major-mode maps;
- text-property or overlay keymaps at the clicked location.

Pay particular attention to RI's KKP/chord machinery because it is active in the same editing stack and may participate in event dispatch.

Use runtime inspection rather than assumptions. The diagnostic code may temporarily log:

```elisp
(current-active-maps t)
```

and the effective binding for the observed mouse event.

### 2.3 Check input/event translation

Inspect whether the raw event is transformed by:

- `input-decode-map`;
- `local-function-key-map`;
- `function-key-map`;
- `key-translation-map`.

This is especially relevant in terminal Emacs.

The RI binding must target the event that reaches command lookup, not merely the event name expected from GUI Emacs.

### Acceptance gate for Phase 2

A physical primary click must resolve to either:

- `ri-mouse`'s command in NORM, or
- a clearly identified standard Emacs command that `ri-mouse` intentionally wraps/delegates to.

---

## Phase 3 — Reduce `ri-mouse` to a minimal proven point-movement path

Before involving semantic-regions or NODE, prove ordinary point movement.

### 3.1 Add a temporary diagnostic command

Create a development-only command in `ri-mouse` that does nothing except:

1. receive the event with `(interactive "e")`;
2. log the event type and `event-start`;
3. call the standard Emacs mouse point command;
4. log the resulting `(point)` and `(current-buffer)`.

No NODE state, Extend state, overlays, or semantic refresh should participate in this test.

### 3.2 Verify window switching

Test clicking:

- earlier/later on the same line;
- another visible line;
- another editable window;
- wrapped text.

The point must move correctly using native Emacs position decoding.

### 3.3 Do not bind both press and release blindly

The current implementation runs the full semantic action for both `down-mouse-1` and `mouse-1`. This may cause duplicated processing and is not justified until the real event sequence is known.

After Phase 1 identifies the event sequence, use the smallest correct design:

- bind only the release event when Emacs supplies it normally;
- bind/pass through the press event only when required for the release event to occur;
- if the standard command uses a press event to initiate its own tracking, preserve that contract rather than replacing both phases with the same command.

### Acceptance gate for Phase 3

With semantic-regions temporarily ignored, a physical click in NORM must move point reliably.

Only after this passes should semantic selection be reintroduced.

---

## Phase 4 — Integrate point movement with semantic selection

Once native point movement is proven, call semantic retargeting exactly once after a completed click.

### 4.1 Keep package boundaries clean

`ri-mouse/ri-mouse.el` owns:

- mouse availability/setup;
- event dispatch;
- native point positioning;
- determining when an RI text click has completed;
- calling the semantic retarget API.

`semantic-regions/semantic-regions.el` owns:

- interpreting the resulting buffer position;
- selecting semantic units;
- NODE resolution;
- NODE cache state;
- highlight bounds.

`ri.el` should only initialize `ri-mouse`; it should not contain event-decoding logic.

### 4.2 Narrow the applicability check

The current `ri-mouse--editable-window-p` checks the target window's buffer before `mouse-set-point` runs. Verify this against real `event-start` values.

The repaired flow should distinguish:

1. buffer text positions — RI owns semantic retargeting;
2. another editable buffer window — native Emacs window selection first, then RI retargeting in that target buffer if RI is active there;
3. mode line/fringe/scroll bar/tab bar — delegate completely to standard Emacs behavior;
4. minibuffer/special buffers — do not force RI semantics.

Avoid swallowing UI clicks merely because the event is bound in a modal map.

### 4.3 Extend state

Only after point movement works should Extend interaction be restored.

For a plain click during Extend:

- end/reset the old extended selection through RI's public/centralized Extend API;
- perform the new click selection;
- do not manipulate overlays directly from `ri-mouse`.

---

## Phase 5 — Repair NODE direct targeting independently of mouse transport

NODE correctness must be testable using a plain buffer position, without constructing a GUI/terminal mouse event.

### 5.1 Keep two different NODE entry semantics

Retain:

- `sr--node-top-at` for existing keyboard/Ki-style NODE entry;
- `sr--node-lowest-at` for direct spatial targeting such as a mouse click.

Do not replace one with the other globally.

### 5.2 Define "lowest node" precisely

For a clicked buffer character at `POS`, choose the deepest live tree-sitter node whose range contains that character.

Rules:

1. deepest child wins;
2. anonymous punctuation nodes are valid targets;
3. if parent and child have identical ranges, prefer the deepest node;
4. do not synthesize the special string-content pseudo-child merely because NODE `Down` can enter it;
5. at EOB, probe the previous character only when no character exists at `POS`;
6. parser gaps/errors return nil without breaking point movement.

### 5.3 Decouple clicked point from selected NODE bounds

A direct click has two pieces of state:

- the actual clicked point;
- the selected semantic NODE.

Do not force the selected node back through keyboard entry logic merely because point lies inside rather than exactly on a node edge.

Represent direct targeting explicitly, for example with the existing `sr--node-direct-target-p` concept, but validate its lifecycle carefully:

- click sets the selected lowest node and direct-target state;
- highlight uses that selected node while point remains within its bounds;
- the first keyboard NODE navigation consumes/directly transitions from this node;
- afterward normal keyboard cache/edge semantics resume.

### 5.4 Verify navigation from the clicked node

After clicking a leaf/deep node:

- Up must select its meaningful parent;
- Down must follow existing NODE child semantics;
- Left/Right must use existing sibling semantics;
- the operation must start from the clicked lowest node, not recompute `sr--node-top-at` first.

---

## Phase 6 — Replace shallow tests with tests of the real failure boundary

The existing test:

```elisp
(lookup-key mini-modal-map [mouse-1])
```

is necessary but insufficient and must not be treated as proof that mouse support works.

### 6.1 Pure unit tests

Keep unit tests for:

- setup bindings;
- event classification helpers;
- semantic retargeting by buffer position;
- lowest NODE resolution;
- NODE cache/direct-target transitions;
- Extend reset behavior.

### 6.2 Effective-binding tests

In a temporary RI buffer with all relevant modes enabled, assert the **effective** key binding using `key-binding`, not just `lookup-key` on one map.

The test setup must enable the same stack used by RI, including any KKP/chord/emulation maps that can affect precedence.

### 6.3 Event-path test

Where batch ERT can construct a realistic event, test a synthetic event through the interactive mouse entry point and verify point movement.

If batch mode cannot faithfully emulate the terminal event path, keep a small manual integration test script/checklist in `ri-mouse` that prints:

- GUI vs terminal;
- `xterm-mouse-mode` state;
- raw event;
- effective binding;
- target window/position;
- command invoked;
- point before/after;
- semantic submode;
- selected NODE bounds.

This is an acceptable place for explicit instrumentation because the current defect occurs at the integration boundary between terminal input and Emacs key dispatch.

### 6.4 Real terminal acceptance test

Run the final implementation in the actual environment where the bug was observed, especially Kitty if that is the active frontend.

Test at least:

- LINE click;
- CHAR click;
- WORD click;
- NODE click on an identifier/string/number;
- NODE click on punctuation;
- NODE click followed by Up/Down/Left/Right;
- click in another RI window;
- INST click;
- drag selection behavior;
- wheel scrolling;
- mode-line/tab-bar clicks.

The feature is not considered fixed until the physical-click test passes. Passing ERT alone is insufficient for this bug.

---

## Phase 7 — Package/layout requirements

Keep mouse support as a standalone package directory:

```text
ri-mode/
  ri.el
  ri-mouse/
    ri-mouse.el
    ri-mouse-test.el
    RI-MOUSE-REPAIR-PLAN.md
```

There must be only one current mouse repair plan, located inside `ri-mouse/`.

`ri-mouse.el` should have normal package metadata and provide `ri-mouse`.

`ri.el` may add the package directory to `load-path`, require `ri-mouse`, and invoke one setup entry point such as:

```elisp
(ri-mouse-setup)
```

Avoid reintroducing mouse implementation details into `ri.el`.

---

## Recommended implementation order

1. Capture the actual physical mouse event with `read-event`.
2. Confirm/enable standard terminal mouse reporting if needed.
3. Inspect the effective binding with `key-binding` and active-map precedence.
4. Make a minimal RI command move point with no semantic logic.
5. Verify physical clicks in the failing environment.
6. Add semantic retargeting for non-NODE modes.
7. Validate `sr--node-lowest-at` independently by position.
8. Connect NODE direct-target state to the proven click path.
9. Verify navigation from the clicked NODE.
10. Restore/reset Extend behavior.
11. Add effective-binding and semantic regression tests.
12. Run the full ERT suite.
13. Perform the final physical Kitty/GUI acceptance test.

---

## Final acceptance criteria

The repair is complete only when all of the following are true:

1. A real physical primary click produces an observed Emacs mouse event in the failing environment.
2. In terminal Emacs, required standard mouse reporting is active.
3. `key-binding` in an actual RI NORM buffer resolves the delivered click event to the intended RI/native dispatch path.
4. A physical NORM click moves point before any semantic logic is considered.
5. LINE/CHAR/WORD/etc. highlights follow the clicked position.
6. NODE selects the deepest real tree-sitter node under the clicked character.
7. NODE keyboard navigation continues from that clicked node.
8. Keyboard NODE entry semantics remain unchanged.
9. INST retains ordinary Emacs mouse behavior.
10. Scroll, drag, mode-line, fringe, tab-bar, and other unrelated mouse behavior is not swallowed.
11. `ri-mouse` remains a separate package under `ri-mouse/`.
12. Tests verify effective dispatch and semantic behavior, not merely the presence of a binding in `mini-modal-map`.
13. The feature has been manually verified with a physical click in the actual frontend where it previously failed.
