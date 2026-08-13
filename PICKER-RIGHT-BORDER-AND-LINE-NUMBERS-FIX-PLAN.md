# Picker Right Border and Line Numbers Fix Plan

## Problem

`Pick > File` can show line numbers on the left and `$` at the right edge instead of the rounded frame's closing glyphs.

The renderer is not choosing `$`. `ri-pick--title-line`, `ri-pick--border-line`, and `ri-pick--render` already emit the intended right edge:

- `╮` for the top border;
- `│` for the query, result, status, and blank rows;
- `┤` for the separator;
- `╯` for the bottom border.

The existing render test confirms those characters are present in the buffer. `$` is Emacs' truncation indicator: the line-number gutter consumes columns and pushes the rendered right edge outside the visible text area.

`ri-pick-mode` currently sets `display-line-numbers` to nil in the derived-mode body. That is too early for user configuration which enables line numbers from `ri-pick-mode-hook` or `after-change-major-mode-hook`; those hooks run before `ri-pick-mode` returns and can overwrite the value. A batch reproduction with a mode hook enabling `display-line-numbers-mode` leaves both `display-line-numbers-mode` and `display-line-numbers` non-nil.

## Decision

Disable `display-line-numbers-mode` after `ri-pick-mode` has returned and before the picker buffer is displayed or rendered. Use the minor-mode function rather than assigning only `display-line-numbers`, so the minor-mode state and its display variable remain consistent.

Do not introduce a replacement glyph for `$`. Once the gutter is removed before the first width calculation, the existing rounded right-border glyphs fit and become visible. Keep the fix in the shared `ri-pick-start` path; File, Buffer, Document Symbol, and Workspace Symbol pickers use the same surface and should not diverge.

## Implementation

### 1. Enforce the picker display state after mode hooks

Update `ri-pick-start` in `ri-pick/ri-pick.el`.

Immediately after `(ri-pick-mode)` returns in the generated picker buffer, call:

```elisp
(display-line-numbers-mode -1)
```

This must happen before `display-buffer` creates the child-frame window and before `ri-pick--render` reads `window-body-width`. Keep the current mode-line, tab-line, header-line, fringe, scroll-bar, and native-border suppression unchanged.

Retain the existing `display-line-numbers nil` mode default unless the implementation can remove it without changing direct `ri-pick-mode` behavior. The post-mode call is the required guard against later mode hooks; the current assignment alone is not sufficient.

### 2. Preserve the existing border renderer

Do not change `ri-pick--title-line`, `ri-pick--border-line`, or the row suffixes in `ri-pick--render`. Their current `╮`, `│`, `┤`, and `╯` output is the desired right side.

Do not compensate for the gutter with a hard-coded width subtraction, add configurable border characters, or replace Emacs' truncation glyph. Removing the unintended gutter fixes the source of the overflow and keeps the existing width calculation shared by every picker.

## Regression Coverage

Extend `ri-pick-test-start-uses-undecorated-child-frame` in `ri-pick/ri-pick-test.el`:

1. Temporarily install a `ri-pick-mode-hook` function which enables `display-line-numbers-mode`, reproducing user configuration that overrides the mode body's initial nil value.
2. Start the picker through the existing fake-UI helper.
3. In the generated picker buffer, assert that both `display-line-numbers-mode` and `display-line-numbers` are nil after startup.
4. Keep the existing assertions for the undecorated child frame and absent header line.

The existing `ri-pick-test-render-draws-rounded-frame-and-preserves-query` already verifies that every rendered row has the correct closing box character and expected display width. Do not duplicate those assertions in a second rendering test.

## Verification

Run the picker suite:

```sh
emacs -Q --batch \
  -L . -L ri-pick -L ri-tabs -L semantic-regions -L mini-modal \
  -l ri-pick/ri-pick-test.el \
  -f ert-run-tests-batch-and-exit
```

Then verify the actual TTY surface with line-number customization deliberately enabled:

1. In `emacs -Q -nw`, add a hook that enables `display-line-numbers-mode` for `ri-pick-mode`.
2. Open `Pick > File`.
3. Confirm that no row numbers or empty line-number gutter appear on the left.
4. Confirm that the visible right edge uses `╮`, `│`, `┤`, and `╯` as appropriate and no row ends in `$`.
5. Type a query, move through results, and resize the terminal; confirm the right edge remains visible and aligned.
6. Open one other picker, such as Buffer, and confirm the shared startup path applies the same fix.

## Documentation

No README change is required. This restores the already documented centered rounded picker and does not change commands, keys, providers, or candidate behavior.

## Non-Goals

- Do not special-case `Pick > File`.
- Do not change picker geometry, candidate rendering, filtering, selection, or query editing.
- Do not add new border helpers or configurable glyphs.
- Do not change global line-number settings outside the generated picker buffer.
