# keymap-legend

A standalone Emacs package that renders keymap legends — temporary, text-only keyboard diagrams displayed above the source window's mode line, similar to Ki editor's `KeymapLegend`.

## Features

- **Physical keyboard layout** — renders bindings on a 3×10 QWERTY grid with normal/Shift/Alt slots
- **Responsive rendering** — auto-selects between full table, split halves, or compact list based on window width
- **Mode-line integration** — hides the source window's mode line and re-displays it in the legend window
- **Overflow handling** — bindings that don't fit the physical layout appear in a sorted overflow section
- **Window resize** — rerenders on width changes
- **Graceful cleanup** — restores the source mode line on hide, even when the legend buffer is killed externally

## Usage

```elisp
(require 'keymap-legend)

;; Show a legend for a keymap
(keymap-legend-show
 "Copy"
 copy-keymap
 '(:title "Copy" :release "Copy"))

;; Hide it
(keymap-legend-hide)
```

### Legend spec

The third argument to `keymap-legend-show` is a plist:

- `:title` — header text (required)
- `:release` — release-hold label for momentary layers (optional)

### Keymap entries

Bindings are discovered via `map-keymap`. To appear in the legend, bindings should use `menu-item`:

```elisp
(define-key map (kbd "c") '(menu-item "Copy" my-copy-command))
```

## Customization

- `keymap-legend-layout` — physical keyboard layout (default: QWERTY)
- `keymap-legend-max-label-width` — maximum display width of one binding label (default: 10); longer labels are shown with an ellipsis

## License

Apache-2.0
