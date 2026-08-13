# Tab Bar Line Hover Removal Plan

## Goal

Remove the unwanted green background that appears when the mouse pointer moves over a row of the custom wrapped Ri tab bar. The tab surface must not visually highlight a whole wrapped line on hover.

The change must preserve the existing custom tab-bar behavior: wrapping, tab sizing, active/inactive tab faces, mouse hit-testing, clicking, middle-click closing, context menus, wheel navigation, and frame-wide rendering.

## Current behavior and root cause

`ri-tabs--tab-label` currently assigns every rendered tab label:

```elisp
'mouse-face 'ri-tabs-highlight
```

and `ri-tabs-highlight` inherits from Emacs' generic `highlight` face:

```elisp
(defface ri-tabs-highlight
  '((t :inherit highlight :box nil))
  ...)
```

The custom tab bar is rendered into a dedicated buffer and explicitly split into multiple text rows by `ri-tabs--render-rows`. In this surface, Emacs' mouse-face rendering can make the hover background look like a row-level highlight, especially once the tab bar contains wrapped rows. The visible green color comes from the user's/current theme's `highlight` face.

The hover face is not required for mouse hit-testing. Ri already attaches explicit `ri-tabs-frame` and `ri-tabs-buffer` text properties in `ri-tabs--prepare-item-display`, and mouse commands resolve their target from those properties. Therefore the visual mouse face can be removed independently from mouse interaction.

## Implementation

### 1. Remove visual `mouse-face` from tab labels

Update `ri-tabs--tab-label` so it no longer adds `mouse-face` to the returned string.

Keep these properties/behaviors unchanged:

- normal `face` for active/inactive tabs;
- `help-echo` tooltip text;
- marker and label contents;
- the active tab styling controlled by `ri-tabs--tab-face`.

After this change, moving the pointer over either the first or any subsequent wrapped row must not alter its background.

### 2. Remove the now-unused hover face

Delete `ri-tabs-highlight` if no other code uses it after step 1.

This is preferable to leaving a dead public face whose only purpose was the removed hover behavior. Before deleting it, search the package for all references to `ri-tabs-highlight` and confirm that only `ri-tabs.el` and its tests depend on it.

If backward compatibility for user customizations of this face is intentionally required, keep the face definition but do not assign it through `mouse-face`. Otherwise remove it completely.

### 3. Preserve mouse target properties

Do not remove or weaken `ri-tabs--prepare-item-display`.

The rendered text must continue to receive:

```elisp
'ri-tabs-frame frame
'ri-tabs-buffer (ri-tabs--item-buffer item)
'pointer 'hand
```

These properties are the interaction contract for the custom surface and must remain independent of hover styling.

### 4. Do not solve the issue at row level

Do not add compensating faces to newline separators, row padding, the whole surface buffer, or the side window. The correct fix is to stop requesting visual mouse highlighting rather than covering it with another background.

Likewise, do not change wrapping or row packing logic in:

- `ri-tabs--pack-items-into-rows`;
- `ri-tabs--render-rows`;
- `ri-tabs--set-surface-height`.

The defect is presentation-only and should not affect layout.

## Tests

### 5. Replace the hover-face test

Update `ri-tabs-test-faces-are-independent-of-native-tab-bar-faces` so it continues to verify the active and inactive Ri tab faces but no longer expects `ri-tabs-highlight` to inherit from `highlight` if that face is removed.

If `ri-tabs-highlight` is retained only for compatibility, the test should not treat it as part of rendered tab behavior.

### 6. Add a regression test for tab-label properties

Add an ERT test that calls `ri-tabs--tab-label` and verifies:

- the returned text has the expected normal `face` property;
- it has the expected `help-echo` property;
- it does **not** have a `mouse-face` property anywhere in the label.

Test both selected and unselected tabs if necessary to ensure neither path introduces hover styling.

### 7. Add a regression test for interactive render properties

Render or prepare an item through `ri-tabs--prepare-item-display` and verify that removing `mouse-face` did not remove the interaction metadata:

- `ri-tabs-frame` is present;
- `ri-tabs-buffer` points to the correct buffer;
- `pointer` remains `hand`;
- `mouse-face` is absent.

This test documents that click targeting and hover appearance are intentionally decoupled.

### 8. Cover a wrapped two-row surface

Add or extend a rendering test that forces several tabs into at least two rows using a narrow available width. Inspect the final rendered buffer text and verify that no character on either row carries a `mouse-face` property.

The test should also verify that `ri-tabs-buffer` properties still exist on tab text in both rows. This directly covers the reported failure mode rather than only testing a single isolated label.

## Validation

Run the complete `ri-tabs` ERT suite after the change.

Then manually verify in graphical Emacs with enough marked/open files to force wrapping:

1. Make the custom Ri tab bar wrap to at least two rows.
2. Move the pointer across empty space and tabs in the first row.
3. Confirm that the first row background never changes.
4. Repeat for the second and later rows.
5. Confirm that the pointer still becomes a hand over tabs.
6. Confirm left-click switching still works on tabs in every row.
7. Confirm middle-click close, right-click context menu, and wheel navigation still work.
8. Confirm active/inactive tab colors remain unchanged while moving the pointer.

## Expected result

The wrapped Ri tab bar remains visually stable under mouse movement. No row receives the theme's green `highlight` background, while all existing tab mouse interactions continue to work through Ri's explicit text properties.
