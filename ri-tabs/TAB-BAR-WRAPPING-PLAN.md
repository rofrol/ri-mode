# Tab Bar Wrapping Plan

## Goal

Change `ri-tabs` so that when the visible file tabs no longer fit in the frame width, the Tab Bar grows vertically and wraps the remaining tabs onto additional rows instead of visually clipping/truncating the right-hand portion of the tab list.

The desired behavior is:

```text
[-] foo.el   [-] bar.el   [-] very-long-name.odin
[-] baz.el   [-] main.el
```

rather than:

```text
[-] foo.el   [-] bar.el   [-] very-long-name.o...
```

or silently hiding the tabs that extend past the right edge.

This change must preserve the existing content-sized tab labels introduced by `ASYMMETRIC-DUPLICATE-NAMES-AND-DYNAMIC-TAB-WIDTH-PLAN.md`.

## Current Relevant Behavior

`ri-tabs--configure-frame` currently forces every ordinary frame to exactly one Tab Bar row:

```elisp
(set-frame-parameter frame 'tab-bar-lines 1)
(set-frame-parameter frame 'tab-bar-lines-keep-state t)
```

The package also installs:

```elisp
(setq-default tab-bar-format '(ri-tabs--format-tabs)
              tab-bar-auto-width nil)
```

`tab-bar-auto-width` is intentionally disabled so that individual Ri tabs remain content-sized rather than being stretched to equal widths.

The important problem for wrapping is therefore not label width. It is the frame policy that pins `tab-bar-lines` to `1` and prevents Emacs from increasing the Tab Bar height when the generated menu items need more horizontal space.

GNU Emacs already has multi-line Tab Bar display support at the frame/display level: `tab-bar-lines` may grow above one line, and core Tab Bar code explicitly accounts for values greater than `1` together with `auto-resize-tab-bars`. Ri should use that native mechanism instead of implementing its own pseudo-tab rows. citeturn218701view0L2665-L2682

## Required Behavior

### 1. Tabs wrap as complete items

A tab must remain visually intact when possible.

If the next complete tab does not fit on the current row, it should continue on the next Tab Bar row rather than being clipped at the frame edge.

Ri must not shorten a filename merely to keep the Tab Bar at one line.

### 2. Tab Bar height is dynamic

For an ordinary frame:

- one row is used when all tabs fit;
- two rows are used when one row is insufficient;
- additional rows are allowed as required by the rendered tab content;
- when the frame becomes wider or tabs are removed, the Tab Bar should shrink back to the minimum required number of rows.

Do not impose an arbitrary fixed maximum number of Ri tab rows unless Emacs itself requires such a limit.

### 3. Existing dynamic tab width remains unchanged

The wrapping work must not undo the content-sized-label behavior.

Keep:

```elisp
tab-bar-auto-width nil
```

unless testing against Emacs 30.2 demonstrates that another native setting is required specifically for multiline wrapping without restoring equal-width stretching.

Each tab should still occupy only the width of:

```text
<left padding> <marker> <space> <computed filename label> <right padding>
```

### 4. Duplicate-name qualification remains independent

Do not use path shortening/truncation as an overflow strategy.

The existing naming rules must remain responsible only for disambiguation, for example:

```text
main.el
bar/main.el
```

Wrapping is a display/layout concern and must not change which label is chosen for a file.

### 5. Frame resize must immediately recompute wrapping

When the user resizes a frame horizontally:

- narrowing the frame should allow the Tab Bar to grow to more rows;
- widening the frame should allow it to collapse back to fewer rows.

This must not require changing buffers, toggling marks, or manually refreshing Ri tabs.

### 6. New frames use the same wrapping policy

Frames created while `ri-tabs-mode` is active must receive the dynamic multiline Tab Bar configuration immediately.

The behavior must remain consistent with the current ordinary-frame versus auxiliary-frame distinction.

## Implementation Plan

### 1. Stop permanently pinning ordinary frames to one row

Refactor `ri-tabs--configure-frame`.

The current ordinary-frame branch:

```elisp
(set-frame-parameter frame 'tab-bar-lines 1)
(set-frame-parameter frame 'tab-bar-lines-keep-state t)
```

is incompatible with dynamic wrapping.

Replace that policy with one that:

1. keeps the Ri Tab Bar visible;
2. permits the display engine to increase `tab-bar-lines` above `1` when content wraps;
3. permits the value to decrease again when fewer rows are required;
4. does not let ordinary native Tab Bar bookkeeping hide the Ri row just because `ri-tabs` does not use `tab-bar-tabs-function` as its source of file tabs.

The implementation should prefer Emacs's native Tab Bar resizing mechanism rather than manually estimating row count from `frame-width`.

### 2. Integrate deliberately with `auto-resize-tab-bars`

Inspect the Emacs 30.2 semantics of `auto-resize-tab-bars` and choose the native setting that allows both growth and shrinkage of multiline Tab Bars.

Do not use `grow-only`, because the required behavior includes shrinking the Tab Bar after:

- widening the frame;
- closing a file buffer;
- unmarking a tab;
- shortening a visible duplicate-name label because the collision disappears.

If `auto-resize-tab-bars` must be temporarily changed globally/default-wise while `ri-tabs-mode` is active, Ri must save and restore the user's exact previous value.

### 3. Revisit `tab-bar-lines-keep-state`

The current code deliberately sets:

```elisp
tab-bar-lines-keep-state t
```

because native Tab Bar bookkeeping otherwise recalculates the frame parameter from workspace tabs.

For multiline Ri tabs, keeping this permanently true may also prevent the native resizing path Ri now needs.

Determine whether Emacs's display engine can still grow/shrink `tab-bar-lines` while `tab-bar-lines-keep-state` is non-nil.

Then choose one of these narrowly scoped approaches:

- leave `tab-bar-lines-keep-state` enabled if display-driven multiline resizing still works correctly; or
- stop using it and replace the old protection with a Ri-specific visibility mechanism that prevents native workspace-tab counting from collapsing the bar to zero/one line while still permitting actual row resizing.

Do not simply remove `tab-bar-lines-keep-state` without covering the original reason it was introduced.

### 4. Add a dedicated frame-layout helper

Separate "should this frame have an Ri Tab Bar?" from "how many lines should the Tab Bar currently occupy?".

Introduce a helper with a responsibility conceptually like:

```elisp
ri-tabs--configure-frame-tab-bar-layout
```

or refactor the existing `ri-tabs--configure-frame` so its intent is explicit.

It should centralize:

- auxiliary frame => `tab-bar-lines = 0`;
- ordinary Ri frame => visible and dynamically resizable;
- preservation of any frame-local state needed for exact restoration.

Avoid scattering direct writes to `tab-bar-lines` across refresh paths.

### 5. Ensure Ri refresh triggers a Tab Bar redisplay, not manual wrapping

Keep `ri-tabs--format-tabs` returning one flat sequence of native `menu-item` entries.

Do **not** split the items into manually constructed row groups and do not insert newline characters into labels.

The native Tab Bar/display engine should decide row breaks from the complete sequence and current frame width.

After mark/buffer/name changes, Ri should request normal Tab Bar/frame redisplay and allow Emacs to recompute the necessary number of lines.

### 6. Handle horizontal frame-size changes

Verify whether native Tab Bar resizing is automatically recomputed on frame-size changes under the chosen configuration.

If Emacs 30.2 already does this, add no Ri resize hook.

Only if required, install the narrowest available frame-size hook/callback that requests Tab Bar redisplay/recalculation for affected Ri frames.

Do not implement continuous custom width measurement or reconstruct tabs from pixel coordinates.

Any hook installed by Ri must be:

- installed once;
- removed on disable;
- harmless for auxiliary frames;
- safe across repeated enable/disable cycles.

### 7. Preserve mouse and touch hit-testing across rows

Multi-row rendering must keep every generated item associated with the same key-to-buffer mapping stored in:

```elisp
ri-tabs--item-buffers
```

Verify that the existing event path:

```elisp
ri-tabs--event-target
  -> tab-bar--event-to-item
  -> ri-tabs--item-buffers
```

continues to resolve clicks on tabs displayed on the second and later rows.

Do not introduce row-local duplicate keys. The existing `current-tab`, `tab-2`, `tab-3`, ... identity scheme should remain unique across the whole Tab Bar.

### 8. Preserve and restore all modified native state

Extend `ri-tabs--capture-tab-bar-state` / `ri-tabs--restore-tab-bar-state` for every additional global/default variable changed by this implementation, especially `auto-resize-tab-bars` if Ri changes it.

Continue restoring per-frame values captured by `ri-tabs--capture-frame-state`, including:

```elisp
tab-bar-lines
tab-bar-lines-keep-state
```

A frame that had a custom multiline Tab Bar configuration before `ri-tabs-mode` was enabled must get that exact configuration back on disable.

### 9. Update comments that currently describe a single owned row

The code currently contains wording such as:

```text
Ri owns the Tab Bar row
```

and:

```text
Pin the row while Ri is active
```

Update these comments and the package commentary to describe a dynamically sized Tab Bar area that may occupy multiple rows.

Do not leave documentation implying that one visible row is an invariant.

## Tests

Update `ri-tabs/ri-tabs-test.el` with focused ERT tests for the configuration logic, plus GUI-capable/manual verification where actual visual wrapping cannot be reliably asserted in batch mode.

### Configuration/state tests

Add tests that verify:

1. ordinary frames are no longer permanently configured with a one-row-only policy;
2. auxiliary/ineligible frames still use zero Ri Tab Bar lines;
3. the selected `auto-resize-tab-bars` policy supports shrinking as well as growth;
4. enabling `ri-tabs-mode` installs the required resizing policy exactly once;
5. disabling `ri-tabs-mode` restores the exact previous `auto-resize-tab-bars` value if Ri changes it;
6. previous `tab-bar-lines` and `tab-bar-lines-keep-state` frame parameters are restored exactly;
7. frames created while Ri is active get the same dynamic wrapping configuration;
8. repeated enable/disable cycles do not accumulate hooks or altered defaults.

### Renderer structure tests

Verify that wrapping is not implemented by mutating labels:

1. `ri-tabs--format-tabs` still returns one flat ordered list of native menu items;
2. labels contain no inserted newline used as a synthetic row break;
3. labels remain content-sized;
4. long labels are not truncated by Ri;
5. all menu item keys remain unique across a large tab set.

### Interaction tests

Where practical, exercise event decoding with enough items to require multiple rows in a graphical test environment and verify that:

- a tab on row 2+ selects the correct buffer;
- middle-click on row 2+ closes the correct buffer;
- right-click on row 2+ opens the context menu for the correct buffer.

Do not make ordinary batch ERT depend on a specific font, DPI, or pixel width.

### Manual/GUI acceptance scenarios

Use a narrow graphical Emacs frame and enough marked files to exceed one row.

Verify these scenarios:

#### Scenario A: initial overflow

1. Open/mark enough files that their combined labels exceed the frame width.
2. Confirm the extra tabs appear on row 2 rather than being clipped.
3. Continue adding files and confirm row 3 appears when required.

#### Scenario B: resize narrower

1. Start with all tabs fitting on one row.
2. Narrow the frame.
3. Confirm tabs automatically wrap and `tab-bar-lines` grows.

#### Scenario C: resize wider

1. Start with two or more rows.
2. Widen the frame.
3. Confirm rows collapse automatically until the minimum required height is reached.

#### Scenario D: remove tabs

1. Start with multiple rows.
2. Unmark/close enough files to fit on fewer rows.
3. Confirm the Tab Bar shrinks vertically without manual intervention.

#### Scenario E: duplicate path labels

1. Create duplicate basenames that cause parent-directory qualification.
2. Confirm the longer qualified labels can cause wrapping.
3. Remove the collision.
4. Confirm the labels shorten and the Tab Bar can collapse to fewer rows.

#### Scenario F: mouse interaction

Click tabs on every visible row and confirm each one selects the correct buffer.

## Acceptance Criteria

The change is complete when all of the following are true:

1. Ri tabs remain content-sized and are not stretched to equal widths.
2. When their combined width exceeds the frame width, tabs continue onto additional Tab Bar rows instead of being visually clipped.
3. Ri itself does not truncate filenames to solve overflow.
4. The Tab Bar grows to as many rows as are required by the visible tabs.
5. Narrowing a frame increases the row count automatically.
6. Widening a frame decreases the row count automatically.
7. Removing or shortening tabs decreases the row count automatically.
8. All rows preserve current/inactive faces, markers, help text, mouse highlighting, and full-path tooltips.
9. Mouse/touch actions on tabs in row 2+ target the correct buffers.
10. Duplicate-name disambiguation and repository-owner semantics remain unchanged.
11. Auxiliary frames remain free of the Ri Tab Bar.
12. New ordinary frames created while Ri is enabled use the same wrapping behavior.
13. Disabling `ri-tabs-mode` restores every Tab Bar/global/frame setting changed by Ri.
14. The full `ri-tabs` ERT suite passes.
