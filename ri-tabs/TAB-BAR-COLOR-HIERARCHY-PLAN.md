# Tab Bar Color Hierarchy Plan

## Goal

Change the custom `ri-tabs` surface so its colors communicate four distinct
visual levels within a frame:

1. **Active tab** — pure white background.
2. **Tab bar surface** — very light gray background; this is the lightest
   non-active gray and fills all unused tab-bar space.
3. **Inactive tab whose buffer is visible in another ordinary window of the
   same frame** — a medium-light gray between the active tab and a normal
   inactive tab.
4. **Normal inactive tab** — the darkest of the tab-bar grays.

The intended lightness order is therefore:

```text
active tab
    > tab bar background
        > inactive tab visible in another window
            > ordinary inactive tab
```

Use explicit RGB values rather than named colors so GUI Emacs and true-color
TTY Emacs resolve the palette consistently. A suitable initial palette is:

```text
active tab:                    #ffffff
whole tab bar background:      #f4f4f4
visible in another window:     #d8d8d8
ordinary inactive tab:         #c4c4c4
```

The exact gray values may be adjusted during the visual smoke test, but their
ordering and semantic roles must remain fixed.

## Current Implementation

`ri-tabs/ri-tabs.el` currently has only two tab faces:

- `ri-tabs-current-tab` for the selected editing window's buffer;
- `ri-tabs-tab` for every other tab.

`ri-tabs--tab-face` accepts a boolean `selected` argument and therefore cannot
represent the new third tab state.

`ri-tabs--visible-items` computes only whether a tab is active. It does not
record whether the same buffer is displayed by another ordinary window in the
frame.

The optimized selection path in `ri-tabs--selection-update-frame` also assumes
only two states. It updates the old tab to inactive and the new tab to active
without reconsidering whether either buffer is still visible elsewhere in the
frame.

The custom tab surface is a dedicated side-window buffer. At present the
unused area of that window does not have a dedicated Ri face, so the requested
light-gray full-width tab-bar background must be applied at the surface-buffer
level rather than only to tab strings.

## Behavioral Contract

For one frame, classify every visible Ri tab independently from other frames.

### Active

A tab is active when its buffer is displayed in the frame's selected ordinary
editing window, as determined by the existing `ri-tabs--frame-selected-window`
logic.

It uses:

```text
background: #ffffff
```

and retains the current black foreground, bold weight, and no box.

### Visible in another window

A non-active tab is in the `visible` state when its buffer is displayed in at
least one other live, ordinary, non-minibuffer, non-Ri-surface window belonging
to the same frame.

Examples:

- frame has two editing windows showing `a.el` and `b.el`;
- focus is on the window showing `a.el`;
- `a.el` is active and white;
- `b.el` is inactive but visible and uses the intermediate gray.

If two ordinary windows display the same buffer and one of them is selected,
that buffer remains active, not merely visible.

Visibility in another frame must not affect the color in this frame.

### Ordinary inactive

A tab that is neither active nor displayed in another ordinary window of the
same frame uses the darkest inactive gray.

### Tab bar background

The entire Ri-owned tab surface, including:

- unused horizontal space after the last tab on each row;
- empty space on a short wrapped row;
- the surface when no actual tab text occupies a cell;

uses the dedicated light-gray tab-bar background.

That background must be lighter than both inactive-tab backgrounds but darker
than the white active tab.

## Face Definitions

In `ri-tabs/ri-tabs.el`:

1. Keep `ri-tabs-current-tab`, but make its explicit background `#ffffff`.
2. Change `ri-tabs-tab` into the ordinary inactive-tab face and give it the
   darkest gray, initially `#c4c4c4`.
3. Add a new face, for example `ri-tabs-visible-tab`, for an inactive tab whose
   buffer is visible elsewhere in the same frame. Give it the intermediate
   gray, initially `#d8d8d8`.
4. Add a new face, for example `ri-tabs-bar`, for the whole dedicated surface.
   Give it the lightest non-active gray, initially `#f4f4f4`.
5. Keep tab foregrounds readable and neutral. Preserve existing foreground,
   weight, and box semantics unless a visual test shows an inherited face is
   overriding them unexpectedly.
6. Do not introduce hover-specific faces or mouse-face properties. This change
   is purely about persistent tab state and surface background.

## Tab State Model

Replace the boolean-only face selection with an explicit semantic state.

A clean model is:

```elisp
active
visible
inactive
```

Update `ri-tabs--tab-face` to accept this state and map it to:

```text
active   -> ri-tabs-current-tab
visible  -> ri-tabs-visible-tab
inactive -> ri-tabs-tab
```

Do not encode the new behavior as nested ad-hoc face checks spread across the
renderer. Keep state classification separate from face selection.

## Detect Buffers Visible in the Frame

Add a helper that computes the buffers displayed by ordinary editing windows
of a frame.

The helper must:

1. inspect `window-list` for the target frame;
2. exclude minibuffer windows;
3. exclude the Ri tab surface using `ri-tabs--surface-window-p`;
4. ignore dead windows;
5. return buffer identity using `eq`, not file-name comparison;
6. remain frame-local.

Prefer computing the visible-buffer set once per structural render instead of
calling `get-buffer-window` or rescanning all windows separately for every tab.

For example, `ri-tabs--visible-items` can compute:

```text
selected editing buffer
set/list of buffers displayed in ordinary windows
```

and classify each item as:

```text
active, if buffer == selected buffer
visible, if buffer is in the frame-visible set
inactive, otherwise
```

Extend `ri-tabs--item` so the cached renderer-independent item stores this
semantic state, or stores enough information to derive it without rescanning
windows.

## Rendering Changes

Update `ri-tabs--tab-label` so it receives the semantic tab state rather than
only `selected-buffer`/a boolean selected flag.

Its help text can continue distinguishing the active file from switchable
files; the new visible state does not require different mouse behavior.

`ri-tabs--prepare-item-display`, wrapping, sizing, mouse hit testing, file
markers, duplicate-name disambiguation, and ordering must remain unchanged.

No separator, padding, box, or width behavior should change as part of this
work.

## Whole-Surface Background

Apply `ri-tabs-bar` to the dedicated surface buffer itself so the face covers
cells that have no tab string text property.

Prefer a buffer-local face mechanism such as `buffer-face-mode-face` /
`buffer-face-mode` on the internal ` *ri-tabs*` buffer. This scopes the change
to the Ri-owned surface and avoids changing the global `default` face.

Tab strings continue to carry their own explicit tab faces, which override the
surface background inside each tab.

Verify that wrapped rows and the final newline do not expose the normal Emacs
background instead of `ri-tabs-bar`.

## Fast Selection Update

The existing `ri-tabs--selection-update-frame` optimization must be upgraded
from a two-face transition to a frame-state reconciliation.

A focus change can alter more than two semantic colors. For example:

```text
window 1: a.el
window 2: b.el
```

When focus moves from window 1 to window 2:

```text
a.el: active  -> visible
b.el: visible -> active
```

If the selected window changes its buffer, the old buffer may become either
`visible` or `inactive` depending on whether another window still displays it.

Therefore:

1. recompute the frame's ordinary-window visible-buffer set on selection or
   window-buffer changes;
2. determine the desired semantic state for cached tab items;
3. update only tabs whose desired state differs from their cached state;
4. preserve the existing structural-refresh fallback when entering/leaving an
   unmarked temporary tab changes the visible tab set;
5. do not call Git, persistent-state migration, label disambiguation, or full
   layout measurement merely to change colors.

This retains the performance improvement of the current custom tab surface
while making the three tab states correct.

## Window Layout Changes

The visible-in-another-window state can change without the selected buffer
changing, for example when:

- a window is split;
- a window is deleted;
- `set-window-buffer` changes a non-selected window;
- another command displays a marked buffer in a secondary window.

Ensure an existing lightweight hook path refreshes tab states after such
window configuration changes. If the current hooks only react to selected
window/buffer changes, add or extend a `window-configuration-change-hook`
handler that reconciles semantic tab states for affected frames.

Avoid unconditional full structural rebuilds when only state colors changed.
The state reconciliation helper should be reusable by both selection-change
and window-configuration-change paths.

## Regression Tests

Extend `ri-tabs/ri-tabs-test.el` with tests for the full four-level palette and
state behavior.

### Face defaults

Assert that the package faces use explicit backgrounds:

```text
ri-tabs-current-tab  -> #ffffff
ri-tabs-bar          -> #f4f4f4
ri-tabs-visible-tab  -> #d8d8d8
ri-tabs-tab          -> #c4c4c4
```

Also assert the intended luminance/order contract so later edits cannot
accidentally make an inactive state lighter than the bar background.

### State classification

With one ordinary editing window:

- selected buffer -> `active`;
- all other tabs -> `inactive`.

With two ordinary editing windows showing different marked buffers:

- selected-window buffer -> `active`;
- other displayed buffer -> `visible`;
- a third undisplayed marked buffer -> `inactive`.

With the same marked buffer visible in a window on another frame only:

- it remains `inactive` in the first frame.

### Focus transition

Create two editing windows with different tab buffers and move selection
between them. Assert the in-place transition:

```text
old selected tab: active -> visible
new selected tab: visible -> active
```

without requiring a structural layout rebuild.

### Secondary-window buffer change

Change the buffer of a non-selected window and assert that:

- the old secondary buffer becomes inactive when no other frame-local window
  displays it;
- the new secondary buffer becomes visible;
- the selected tab remains active.

### Surface background

Assert that the internal Ri surface buffer has the buffer-local `ri-tabs-bar`
face enabled and that tab text retains the more specific tab face property.

Keep existing wrapping, dynamic-width, mouse, marker, owner-context, and
performance regression tests unchanged.

## Verification

1. Run the complete Ri tabs ERT suite:

   ```sh
   emacs --batch -Q -L ri-tabs -l ri-tabs/ri-tabs-test.el \
     -f ert-run-tests-batch-and-exit
   ```

2. Run any existing broader package test command from the repository to catch
   hook or integration regressions.

3. In graphical Emacs, create one frame with at least three marked buffers and
   two editing windows:

   - selected-window tab is pure white;
   - the tab displayed in the other window is the intermediate gray;
   - a marked tab displayed nowhere is the darkest gray;
   - all unused tab-bar area is the lightest gray.

4. Move focus between the two editing windows and verify that white and
   intermediate gray exchange immediately without flicker or tab relayout.

5. Change the buffer shown in the non-selected window and verify that the
   intermediate gray moves to the newly displayed buffer.

6. Split and delete windows and verify the colors update without requiring a
   buffer switch.

7. Repeat with enough marked tabs to wrap onto multiple rows. Every unused cell
   on every row must retain the same `ri-tabs-bar` background.

8. Repeat in `emacs -nw` on a true-color terminal and confirm the same ordering.
   Limited-color terminals may approximate the RGB values, but the package must
   not redefine the terminal palette globally.

## Non-Goals

Do not change:

- which files appear as tabs;
- mark persistence or owner-context behavior;
- tab ordering;
- duplicate-name qualification;
- tab widths or wrapping;
- keyboard navigation;
- mouse actions or hover behavior;
- selected-window semantics;
- global Emacs faces or terminal color definitions.

## Completion Criteria

The change is complete when one frame can visibly distinguish all four levels:

```text
white active tab
> light-gray bar background
> medium-gray tab visible in another frame-local window
> darker ordinary inactive tab
```

and those states update correctly when focus, window contents, splits, or
window layout change, with no regression in tab switching performance or
wrapping behavior.
