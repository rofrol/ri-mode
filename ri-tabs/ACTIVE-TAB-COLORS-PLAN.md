# Active Tab TTY White Background Plan

## Goal

Make the current `ri-tabs` tab use pure white (`#ffffff`) in both graphical
Emacs and `emacs -nw`.  Inactive tabs and all tab-selection behavior must
remain unchanged.

Exact RGB output is required when the character terminal supports 24-bit
color.  Less capable terminals may use their nearest available white.

## Confirmed Diagnosis

The current face-selection path is correct:

1. `ri-tabs--format-tab` marks the window buffer as selected.
2. `ri-tabs--tab-face` returns `ri-tabs-current-tab` for that selected tab.
3. The formatting regression test confirms that the rendered current tab has
   the `ri-tabs-current-tab` text property.
4. There are no package-level face overrides elsewhere in this repository.

The remaining difference is the color value declared by
`ri-tabs-current-tab`:

```elisp
:background "white"
```

The graphical and xterm-compatible terminal backends do not realize that
name to the same RGB value.  Graphical Emacs treats the standard color name
`white` as `#ffffff`, matching the observed GUI result.  Emacs's xterm
backend reserves the name `white` for ANSI color slot 7, whose registered
value is `(229 229 229)`, or `#e5e5e5`.  ANSI slot 15 is registered as
`brightwhite` with `(255 255 255)`.

This remains true on a 24-bit terminal.  `xterm-register-default-colors`
registers the first 16 ANSI names before it registers the remaining named
RGB colors, and it deliberately does not replace names already present.
Consequently, `white` keeps the slot-7 RGB value instead of taking the pure
white value from `color-name-rgb-alist`.

A fresh `emacs -Q -nw` session in the current 24-bit PTY reported:

- `display-color-cells`: `16777216`;
- `face-background` for `ri-tabs-current-tab`: `"white"`;
- `tty-color-desc "white"`: RGB `(58853 58853 58853)`, equivalent to
  `#e5e5e5`;
- `tty-color-desc "#ffffff"`: RGB `(65535 65535 65535)`, equivalent to
  pure white.

Temporarily assigning `#ffffff` to the face in that same terminal produced
the 24-bit pixel value `16777215` (`0xffffff`).  The discrepancy is therefore
not caused by the selected-tab routing, tab-line caching, the active theme,
or lack of truecolor support.  It is the terminal-specific meaning of the
named color `white`.

The previous version of this plan described an inactive-window face branch.
That branch has already been removed from the current implementation and is
not part of this defect.

## Behavioral Contract

1. A tab representing its window's displayed buffer uses
   `ri-tabs-current-tab`.
2. Its background resolves to RGB `(255 255 255)` on graphical and 24-bit
   terminal frames.
3. Its foreground remains black, with bold weight and no box.
4. Every unselected tab continues to use `ri-tabs-tab` without a color
   change.
5. Switching buffers and moving focus between windows continue to preserve
   the existing selected-tab behavior.
6. Terminals without an exact RGB white use Emacs's normal nearest-color
   approximation; the package must not alter their global palette.

## Implementation

In `ri-tabs/ri-tabs.el`:

1. Change only the `ri-tabs-current-tab` background from the ambiguous color
   name `"white"` to the explicit RGB literal `"#ffffff"`.
2. Keep `:foreground "black"`, `:weight bold`, `:box nil`, and the
   `tab-line-tab-current` inheritance unchanged.
3. Do not add separate GUI/TTY face clauses.  One RGB literal expresses the
   same requirement on both backends and lets Emacs perform normal
   approximation on limited terminals.
4. Do not use `"brightwhite"`: it encodes an xterm palette name rather than
   the backend-independent RGB requirement.
5. Do not call `tty-color-define` or otherwise replace the global meaning of
   `"white"`; that would change unrelated Emacs and third-party faces.
6. Do not change `ri-tabs--tab-face`, `ri-tabs--format-tab`, or cache-refresh
   logic.  The confirmed defect is below that layer.

## Regression Coverage

In `ri-tabs/ri-tabs-test.el`:

1. Update the current-face test to require `"#ffffff"` as the resolved
   background while preserving its black foreground, bold weight, and
   no-box assertions.
2. Keep the existing selection-routing test and the formatted-tab face
   property assertion.  Together they ensure the correct face still reaches
   the visible current tab.
3. Add a terminal-only assertion that, on a live 24-bit character frame,
   passes the face background to `tty-color-desc` and requires all three RGB
   components to equal `65535`.
4. Explicitly skip that terminal assertion outside a character frame or
   when `display-color-cells` is not `16777216`; a batch or low-color frame
   must not produce a vacuous success or a false failure.
5. Leave all inactive-tab, marker, keymap, and selected-property assertions
   unchanged.

## Verification

1. Run the complete batch ERT suite:

   ```sh
   emacs --batch -Q -L ri-tabs -l ri-tabs/ri-tabs-test.el \
     -f ert-run-tests-batch-and-exit
   ```

2. Run the terminal-specific test in a real PTY, without `--batch`, so Emacs
   creates a live character frame:

   ```sh
   emacs -Q -nw -L ri-tabs -l ri-tabs/ri-tabs-test.el \
     --eval '(ert-run-tests-batch-and-exit \
              "^ri-tabs-test-current-tab-tty-background-is-pure-white$")'
   ```

3. In a fresh `emacs -Q -nw` session, inspect the realized background:

   ```elisp
   (let ((background
          (face-background 'ri-tabs-current-tab nil t)))
     (list background (tty-color-desc background)))
   ```

   On the current 24-bit terminal, the result must identify `#ffffff` and
   report RGB components `(65535 65535 65535)`, not `(58853 58853 58853)`.

4. Perform a visual smoke test with at least two file tabs in graphical
   Emacs and `emacs -nw`:
   - the current tab is pure white with black text;
   - switching buffers transfers that appearance to the new current tab;
   - the previous tab returns to the unchanged inactive appearance.
5. Split each frame into two windows and move focus between them.  The
   selected tab in each window must retain the active colors.
6. Use fresh Emacs processes for both smoke tests so a previously realized
   face or user customization cannot mask the package default being tested.

## Completion Criteria

The change is complete when the batch suite passes, the live 24-bit TTY
assertion reports `#ffffff`, and visual checks in graphical Emacs and
`emacs -nw` show the same pure-white current-tab background without any
change to inactive tabs or selection behavior.
