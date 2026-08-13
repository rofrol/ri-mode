# Custom Ri Tab Bar Implementation Plan

## Goal

Replace the current `ri-tabs` rendering layer, which depends on Emacs's native workspace-oriented `tab-bar-mode` machinery, with a small Ri-owned frame-wide tab bar implementation.

The new implementation must preserve the existing `ri-tabs` data model and behavior:

- marked buffers remain persistent;
- marked sets remain owned by an owner context/repository;
- opening a file from another repository does not implicitly change the active owner;
- marked tabs remain ordered according to the existing rules;
- an unmarked selected buffer may still be appended to the visible list;
- duplicate filenames keep the existing asymmetric parent-directory qualification rules;
- tab labels remain content-sized rather than fixed-width;
- active/inactive/modified/marked states retain their current semantics;
- mouse selection, middle-click close, context menu, and wheel navigation continue to work.

Only the presentation layer should be replaced.

The primary reason for the replacement is to make multiline wrapping deterministic and entirely under Ri's control:

```text
[-] foo.el   [-] bar.el   [-] very-long-name.odin
[-] baz.el   [-] main.el
```

instead of relying on the native Tab Bar to decide whether or how custom entries wrap.

---

## Architectural Principle

Separate the implementation into three independent layers:

```text
persistent marked-tab state
          ↓
visible tab model
          ↓
layout engine
          ↓
Ri-owned frame-wide renderer
```

The persistent state and visible-tab model already largely exist and should not be rewritten unnecessarily.

The new code should make the layout and renderer explicit instead of encoding them indirectly through native `menu-item` entries.

### Layer 1: State

Keep the current owner-context and persistent marked-buffer machinery.

Examples of code that should remain conceptually unchanged:

- `ri-tabs--frame-owner`
- `ri-tabs--set-frame-owner`
- `ri-tabs--marked-buffer-list`
- persistent state reading/writing
- restore of marked files
- mark/unmark/toggle commands
- owner-context switching

### Layer 2: Visible tab model

Create or extract one function that returns an ordered, renderer-independent model for every visible tab.

Conceptually:

```elisp
(:buffer BUFFER
 :label "foo.el"
 :marker "[-]"
 :active t
 :marked t
 :modified nil)
```

The final display label must be computed only once.

The existing logic for:

- duplicate-name qualification;
- parent-directory prefixes;
- marked/unmarked markers;
- modified markers;
- active-tab detection;

must feed this model rather than being duplicated by the renderer.

### Layer 3: Layout

The layout engine receives the visible tab model and the available width and returns rows.

Conceptually:

```text
tabs + available width
        ↓
measure each rendered tab
        ↓
greedy row packing
        ↓
row 1: tab A, tab B, tab C
row 2: tab D, tab E
```

### Layer 4: Rendering surface

Render those rows on a Ri-owned frame-wide surface.

Do not use Emacs workspace tabs as the data model.

Do not depend on:

- `tab-bar-tabs-function`;
- native workspace tab objects;
- `tab-bar--update-tab-bar-lines`;
- `auto-resize-tab-bars`;
- native tab count;
- native tab selection.

If an Emacs frame-level display surface is reused, it should be treated only as a place to display Ri-owned strings, not as the authority for tab layout or state.

---

# Phase 1 — Extract a Renderer-Independent Tab Model

## 1. Refactor `ri-tabs--format-tabs`

The current `ri-tabs--format-tabs` combines several responsibilities:

1. determining which buffers are visible;
2. deriving labels;
3. deciding the active item;
4. creating native `menu-item` structures;
5. building mouse mappings.

Split this apart.

Introduce a function such as:

```elisp
ri-tabs--visible-items
```

It should return the complete ordered item model for one frame.

For example:

```elisp
((:id 1
  :buffer #<buffer foo.el>
  :marker "[-]"
  :label "foo.el"
  :active t
  :marked t
  :modified nil)
 (:id 2
  :buffer #<buffer bar.el>
  :marker "[:]"
  :label "src/bar.el"
  :active nil
  :marked nil
  :modified t))
```

The exact representation may be a plist, struct, or another simple internal form.

Prefer a `cl-defstruct` if it makes the later layout/render code materially clearer.

## 2. Preserve one source of truth for names

Existing duplicate-name behavior must not be reimplemented inside the new layout code.

In particular, preserve cases such as:

```text
project-a/foo/main.txt
project-a/bar/main.txt
```

and the current asymmetric rule where the earlier/local item may remain minimally named while a later/foreign collision receives a parent prefix where required.

The visible-item model must already contain the final label before layout starts.

## 3. Give every visible item a stable internal identity

Mouse hit testing should not depend on the final rendered string.

Assign each visible item a stable ID for one refresh/layout pass.

The ID can be:

- the buffer itself, if sufficient;
- a monotonically assigned index plus buffer;
- or another deterministic internal token.

Do not encode identity by parsing rendered text.

---

# Phase 2 — Implement a Pure Multiline Layout Engine

## 1. Create a tab display-string builder

Introduce:

```elisp
ri-tabs--item-display-string
```

It should create the complete visual representation of one item before positioning.

For example:

```text
" [-] foo.el "
```

The output should already include:

- marker;
- filename/qualified label;
- intended horizontal padding;
- item face;
- active/inactive styling;
- mouse face if appropriate;
- any separator owned by the item.

The layout engine must measure exactly what the renderer will display.

## 2. Add an explicit width-measurement abstraction

Introduce something like:

```elisp
ri-tabs--display-width
```

The implementation should support two modes.

### Graphical frames

Prefer pixel-accurate measurement of the final propertized display string.

Use an Emacs primitive that measures the actual rendered string with the relevant face/font where practical.

Do not derive pixel widths from filename character count.

### Terminal frames

Use display-column width, such as `string-width`, because pixel geometry does not exist there.

Keep graphical and terminal measurement behind the same helper so the row-packing algorithm does not care which unit is being used.

## 3. Implement pure greedy packing

Create a pure helper, conceptually:

```elisp
ri-tabs--pack-items-into-rows
```

Inputs:

```text
available width
ordered items with measured widths
```

Output:

```text
((ITEM-A ITEM-B ITEM-C)
 (ITEM-D ITEM-E))
```

Rules:

1. Preserve item order.
2. Start with an empty first row.
3. Add the next whole tab when it fits.
4. Otherwise start a new row.
5. Never split one tab between rows.
6. A tab wider than the available width occupies a row by itself.
7. Never create an empty row before an oversized tab.
8. Empty visible-tab input produces the renderer's minimal empty state.
9. Packing must be deterministic.

This helper should not access frames, buffers, faces, or global state.

That makes the critical wrapping behavior directly testable with ERT.

## 4. Account for exact separators and padding

Do not calculate:

```text
sum(tab widths)
```

while rendering additional separators that were not included in the widths.

Every displayed cell must have a known measured width.

The invariant should be:

```text
width used for packing == width actually rendered
```

except for unavoidable Emacs redisplay rounding.

---

# Phase 3 — Choose and Encapsulate the Frame-Wide Rendering Surface

## Preferred approach

Create one small renderer abstraction rather than letting the rest of `ri-tabs` know which Emacs UI facility is used.

For example:

```elisp
ri-tabs--surface-install
ri-tabs--surface-update
ri-tabs--surface-remove
```

The rest of `ri-tabs` should pass rows to this API.

## Rendering requirements

The surface must be:

- frame-wide rather than independently duplicated for every normal window;
- able to display multiple physical rows;
- dynamically grow and shrink;
- not scroll horizontally;
- not clip tabs merely because row 1 is full;
- clickable;
- compatible with ordinary window splitting;
- removable without leaving altered global UI state behind.

## Evaluate candidate surfaces in this order

### Option A — A frame-level Ri-owned use of the native Tab Bar display area

This is acceptable only if the native Tab Bar can be treated as a dumb multiline display surface.

The implementation may reuse the physical frame area, but Ri must provide the already-laid-out row content itself.

Do not reintroduce native workspace-tab semantics.

Before selecting this option, prove with a focused prototype/test that Ri can place explicit multiline content there and reliably control its height.

If the area still insists on native item layout semantics or clips embedded rows, reject it.

### Option B — A dedicated top side window

If the native Tab Bar display area cannot render arbitrary Ri rows reliably, use a dedicated top side window managed by Ri.

This is likely the cleanest fallback because it gives Ri:

- normal buffer text rendering;
- explicit rows;
- straightforward mouse text properties;
- predictable width;
- direct control over height.

The side window should use a dedicated internal buffer, e.g.:

```text
 *ri-tabs*
```

or one internal buffer per frame if per-frame state requires it.

Configure it as a UI window:

- dedicated;
- no mode line;
- no header line;
- no fringes if they are not wanted;
- no scroll bars;
- no cursor;
- non-selectable for ordinary editing;
- fixed/minimal height equal to the number of rendered rows;
- preserved while ordinary windows are split/deleted.

The implementation must avoid stealing the selected editing window during refresh.

### Option C — Child frame

Do not use a child frame unless both simpler approaches fail.

It adds unnecessary complexity:

- geometry synchronization;
- focus;
- multiple monitor behavior;
- terminal incompatibility;
- lifecycle management;
- font and scaling synchronization.

This project does not need those costs merely to draw wrapped file tabs.

---

# Phase 4 — Implement the Minimal Ri Renderer

## 1. Render rows explicitly

Given:

```elisp
((ITEM-A ITEM-B ITEM-C)
 (ITEM-D ITEM-E))
```

produce:

```text
ITEM-AITEM-BITEM-C
ITEM-DITEM-E
```

with exactly one newline between rows.

Do not ask Emacs to infer where wrapping should occur.

The newline positions are the result of `ri-tabs--pack-items-into-rows`.

This is the central design change.

## 2. Attach properties directly to item strings

Each rendered tab should carry direct text properties for:

- face;
- `mouse-face`;
- help text if desired;
- item identity/buffer;
- local keymap or pointer handling.

The renderer should be able to discover the target item directly from the clicked character position.

Remove the need to decode a native `tab-bar--event-to-item` result.

## 3. Preserve current faces where sensible

Existing faces such as:

- `ri-tabs-tab-inactive`;
- active-tab face;
- highlight face;

should be retained or minimally adapted.

They should no longer have to inherit native `tab-bar-tab` faces if that inheritance exists only because of the old implementation.

Prefer Ri-owned face definitions with deliberate inheritance from generic UI faces where appropriate.

This prevents native Tab Bar styling from remaining as a hidden dependency.

## 4. Make row height purely content-derived

The renderer height must equal:

```text
max(1, number of packed rows)
```

or an explicit zero-row state if the UI should disappear when there are no tabs.

Based on current Ri behavior, prefer keeping one visible row while `ri-tabs-mode` owns the UI and an eligible frame exists.

When tabs are removed or the frame becomes wider:

```text
3 rows -> 2 rows -> 1 row
```

must happen immediately after refresh.

---

# Phase 5 — Replace Native Tab-Bar Event Decoding

## 1. Selection

Replace native event-item lookup in:

```elisp
ri-tabs--mouse-select
```

with direct lookup of the clicked tab's text property.

The action remains:

```elisp
ri-tabs--select-buffer
```

so buffer-selection semantics do not change.

## 2. Middle-click close

Preserve current middle-click close behavior.

The clicked rendered item should provide the target buffer directly.

## 3. Right-click context menu

Preserve:

- Select;
- Mark/Unmark;
- Close;
- any existing context operations.

The context menu should receive the frame and buffer from the clicked item.

## 4. Wheel navigation

Preserve current wheel navigation commands.

Wheel events do not need to be tied to individual tab identity and can be installed on the renderer surface itself.

## 5. Pointer feedback

Keep a hover/highlight effect equivalent to the current `ri-tabs-highlight` behavior.

Do not make the entire row one mouse target; each tab must remain individually targetable.

---

# Phase 6 — Frame Lifecycle

## 1. Per-frame renderer state

Store only the minimum state required per frame, for example:

```elisp
(:surface-window WINDOW
 :surface-buffer BUFFER
 :layout-width WIDTH
 :rows ROWS
 :item-generation GENERATION)
```

This may live in frame parameters or a dedicated weak-key table.

Avoid global state when the value is inherently frame-specific.

## 2. New frames

When an ordinary frame is created while `ri-tabs-mode` is active:

1. identify whether it is eligible;
2. initialize the renderer surface;
3. inherit/resolve the appropriate owner-context behavior already used by Ri;
4. render its current visible items.

Auxiliary frames such as tooltips, child frames, minibuffer-only frames, etc. must not receive the Ri tab surface.

Reuse the existing eligibility logic where possible:

```elisp
ri-tabs--structurally-ineligible-frame-p
ri-tabs--frame-eligible-p
```

## 3. Deleted frames

Remove associated buffers/windows/state without affecting other frames.

No stale frame references should remain in persistent global lists.

## 4. Disable

When `ri-tabs-mode` is disabled:

- remove every Ri-owned surface;
- remove renderer-specific hooks;
- remove renderer-specific keymaps/event bindings;
- kill internal renderer buffers when safe;
- clear per-frame renderer state.

The user's native `tab-bar-mode` configuration should not need restoration if the new implementation never takes ownership of it.

This is an important simplification over the current save/restore machinery.

---

# Phase 7 — Resize Handling

## 1. Re-layout after frame width changes

Install a narrowly scoped resize hook.

On width change:

```text
new width
  ↓
re-measure if necessary
  ↓
re-pack
  ↓
update rows
  ↓
update surface height
```

Do not refresh merely because frame height changed unless the rendering surface actually requires it.

## 2. Avoid resize recursion

Changing the renderer height can itself trigger window-size or frame-size hooks.

Guard against recursive layout.

For example, use:

```elisp
ri-tabs--layout-in-progress-p
```

or compare the previously rendered geometry before mutating the surface.

The update should be idempotent.

## 3. Cache only where useful

Correctness is more important than premature width caching.

A reasonable first implementation can rebuild and remeasure the small visible tab set on refresh.

If profiling later proves measurement expensive, cache by:

```text
display string + face/font context
```

but do not make caching part of the initial correctness path unless necessary.

---

# Phase 8 — Refresh Pipeline

Replace the current native-tab enforcement flow:

```text
ri-tabs--refresh
    ↓
ri-tabs--enforce-tab-bar
    ↓
tab-bar-mode/native redisplay
```

with an Ri-owned pipeline:

```text
ri-tabs--refresh
    ↓
for each eligible frame
    ↓
ri-tabs--visible-items
    ↓
ri-tabs--build-display-items
    ↓
ri-tabs--measure-items
    ↓
ri-tabs--pack-items-into-rows
    ↓
ri-tabs--surface-update
```

`force-mode-line-update` should no longer be the primary renderer invalidation mechanism.

Use the update mechanism appropriate to the selected surface.

## Refresh triggers

Ensure re-layout occurs after at least:

- mark;
- unmark;
- toggle mark;
- selected buffer change;
- owner-context switch;
- buffer rename;
- visited filename change;
- buffer modification-state changes if the marker changes;
- buffer kill;
- restored marked-buffer changes;
- frame creation;
- frame width change;
- any operation that changes duplicate-name qualification.

Continue to batch refreshes where the existing batching mechanism avoids redundant work.

---

# Phase 9 — Remove Native Tab-Bar Coupling

Once the custom renderer is functional, remove obsolete presentation-specific code.

Likely candidates include:

- `(require 'tab-bar)` if no remaining non-rendering dependency needs it;
- `ri-tabs--tab-bar-event-bindings`;
- native `tab-bar-map` modifications;
- native `tab-bar-mode-map` modifications;
- `ri-tabs--capture-tab-bar-state`;
- `ri-tabs--install-tab-bar`;
- `ri-tabs--restore-tab-bar-state`;
- `ri-tabs--enforce-tab-bar`;
- `ri-tabs--capture-frame-state` fields related only to native Tab Bar;
- manipulation of `tab-bar-lines`;
- manipulation of `tab-bar-lines-keep-state`;
- manipulation of `tab-bar-format`;
- manipulation of `tab-bar-show`;
- manipulation of `tab-bar-auto-width`;
- manipulation of `auto-resize-tab-bars`;
- `default-frame-alist` changes for `tab-bar-lines`;
- native `tab-bar--event-to-item` event decoding;
- hiding native workspace shortcuts solely because Ri occupied `tab-bar-mode`.

Do not remove an item mechanically if another Ri feature still uses it. Verify references first.

The final implementation should not globally alter the user's native Tab Bar configuration.

A user should be able to have their own `tab-bar-mode` preference independently of `ri-tabs`.

---

# Phase 10 — Tests

## A. Pure layout tests

Add deterministic ERT tests for `ri-tabs--pack-items-into-rows`.

### Fits on one row

```text
available: 100
widths:    20 30 40
result:    1 row
```

### Exact boundary

```text
available: 100
widths:    20 30 50
result:    1 row
```

### Wrap one item

```text
available: 100
widths:    60 50
result:    2 rows
```

### Multiple rows

```text
available: 100
widths:    60 50 40 70
```

Verify exact row membership, not only row count.

### Oversized item

```text
available: 100
widths:    140 20
```

Expected:

```text
row 1: 140
row 2: 20
```

No empty row.

### Empty items

Verify the chosen minimal renderer state.

## B. Model tests

Verify that refactoring does not change visible tab semantics:

- marked buffers appear in the same order;
- selected unmarked buffer is appended as before;
- active state is correct;
- mark/modified markers are correct;
- owner context remains frame-specific;
- foreign-repository files do not silently replace the owner;
- duplicate-name qualification is unchanged.

Explicitly retain coverage for:

```text
project-a/foo/main.txt
project-a/bar/main.txt
```

and cross-repository duplicate-name scenarios.

## C. Render tests

Where possible without a GUI:

- verify the number and positions of inserted newlines;
- verify each tab's text carries the correct buffer/item property;
- verify faces;
- verify local keymaps or event properties;
- verify no tab string is internally split by the layout engine.

## D. Resize tests

Mock width measurement/layout inputs where practical.

Verify transitions:

```text
wide frame   -> 1 row
narrow frame -> 3 rows
wider again  -> 1 row
```

The important regression is shrinking as well as growing.

## E. Lifecycle tests

Verify:

- enable creates the surface on eligible frames;
- auxiliary frames are ignored;
- new ordinary frames receive a surface;
- disabling removes all Ri surfaces;
- no renderer buffer/window remains;
- the user's native `tab-bar-mode`, `tab-bar-format`, and related settings remain untouched.

## F. Mouse tests

Test the target-resolution layer independently from graphical event details where possible:

- left-click target buffer;
- middle-click target buffer;
- right-click target buffer;
- mark/unmark context action;
- stale/dead buffer target safely refreshes instead of erroring.

---

# Phase 11 — Manual Acceptance Tests

Run these in a graphical Emacs session.

## 1. Basic wrapping

Open enough marked files to exceed the frame width.

Expected:

- complete tabs wrap to row 2;
- no tab is clipped at the right edge;
- no horizontal scrolling is required.

## 2. Three or more rows

Make the frame narrow enough to require at least three rows.

Expected:

- all tabs remain visible;
- row order is stable;
- tabs are never split.

## 3. Dynamic shrinking

Widen the frame.

Expected:

```text
3 rows -> 2 rows -> 1 row
```

without toggling `ri-tabs-mode`.

## 4. Dynamic growth

Narrow the frame again.

Expected:

```text
1 row -> 2 rows -> 3 rows
```

immediately.

## 5. Content-sized tabs

Verify short filenames remain short.

No equal-width stretching should return.

## 6. Duplicate names

Test:

```text
project-a/foo/main.txt
project-a/bar/main.txt
```

and files with the same basename in separate repositories.

Expected:

- current qualification rules remain unchanged;
- wrapping does not affect label calculation.

## 7. Repository ownership

Mark files in repository A, visit repository B, and mark according to the existing owner rules.

Expected:

- the custom renderer does not change owner semantics;
- the visible list remains associated with the correct owner context.

## 8. Mouse interaction on every row

Test all rows, not only row 1:

- left click;
- middle click;
- right click;
- wheel navigation.

Every row must behave identically.

## 9. Split windows

Split the editing area several times.

Expected:

- exactly one Ri tab surface per frame;
- it remains frame-wide;
- it is not duplicated per editing window.

## 10. Multiple frames

Create two ordinary frames with different selected buffers/owner contexts.

Expected:

- each frame renders its own correct active state and visible tab set;
- resizing one frame does not reflow the other incorrectly.

## 11. Native Tab Bar independence

Before enabling Ri, configure native `tab-bar-mode` to a known custom state.

Enable and disable `ri-tabs-mode`.

Expected:

- Ri does not repurpose or destructively rewrite native workspace tabs;
- disabling Ri leaves the user's native Tab Bar configuration as it was.

---

# Phase 12 — Migration Strategy

Implement this as a renderer replacement rather than a broad rewrite of `ri-tabs`.

Recommended sequence:

1. Extract and test the visible-item model while keeping the current renderer.
2. Implement and test pure width packing.
3. Prototype the chosen frame-wide surface with static rows.
4. Render real visible items on that surface.
5. Add mouse interaction.
6. Add resize handling.
7. Switch `ri-tabs--refresh` to the new renderer.
8. Run behavioral regression tests.
9. Remove the old native Tab Bar renderer and state-capture code.
10. Run the full test suite again.
11. Perform manual GUI acceptance tests.

During development, avoid maintaining two full production renderers behind a permanent option.

A temporary development switch is acceptable while validating the new renderer, but remove it once the replacement is proven.

---

# Recommended Concrete Design

Unless a short prototype proves that the physical native Tab Bar area can reliably display Ri-computed multiline strings without reintroducing native layout constraints, use a **dedicated top side window** as the custom Ri tab bar.

This gives the cleanest ownership boundary:

```text
Emacs frame
┌─────────────────────────────────────────────┐
│ Ri tab surface                              │
│ [-] foo.el  [-] bar.el  [-] long-name.odin │
│ [-] baz.el  [-] main.el                    │
├─────────────────────────────────────────────┤
│                                             │
│ ordinary Emacs editing windows              │
│                                             │
└─────────────────────────────────────────────┘
```

Ri then owns only:

- one small internal buffer;
- one top side window per eligible frame;
- row packing;
- text properties;
- mouse actions;
- resize refresh.

It does **not** own or emulate Emacs workspace tabs.

This is preferable to fighting native `tab-bar-mode` behavior because the UI being implemented is not actually a workspace-tab system; it is a persistent, owner-scoped file switcher with tab-like presentation.

---

# Definition of Done

The custom implementation is complete when all of the following are true:

1. `ri-tabs` no longer depends on native workspace-tab layout for rendering.
2. All existing marked-tab/owner-context semantics are preserved.
3. Tab widths are content-derived.
4. Tabs wrap to additional rows before clipping.
5. No tab is split between rows.
6. The bar grows and shrinks immediately with frame width and content.
7. The bar is frame-wide and appears only once per frame.
8. Mouse interactions work on every row.
9. Multiple frames maintain independent layouts.
10. Split editing windows do not duplicate the bar.
11. Enabling/disabling Ri does not rewrite the user's native Tab Bar configuration.
12. Pure row-packing tests cover boundary and oversized-item cases.
13. Existing `ri-tabs` tests continue to pass after adapting only renderer-specific expectations.
14. Manual graphical Emacs tests confirm wrapping, resize, clicks, repository ownership, and duplicate-name behavior.
