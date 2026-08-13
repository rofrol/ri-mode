# Picker Rounded Frame Plan

## Problem

`Pick > File` opens in a centered child frame, but the picker does not render the rounded text frame already shown in the original picker design. Its buffer currently contains only an empty query line and result rows, while the title is delegated to `header-line-format`. The child frame also requests native frame chrome with `(undecorated . nil)`, a one-pixel internal border, and a one-pixel child-frame border.

A batch render confirms the mismatch:

```text
--- current picker buffer ---

src/main.el
```

The intended surface is already documented in `PICK-LAYER-IMPLEMENTATION-PLAN.md`:

```text
╭─ File ───────────────────────────────────────╮
│ query                                        │
├──────────────────────────────────────────────┤
│ src/ri.el                                    │
│ src/ri-lsp.el                                │
│ ri-pick/ri-pick.el                           │
╰──────────────────────────────────────────────╯
```

`keymap-legend/keymap-legend.el` provides the repository's visual precedent. `keymap-legend--render-table` uses `╭`, `╮`, `╰`, `╯`, `│`, `├`, `┤`, and `─`, builds every border from display widths, and applies `fixed-pitch` so the glyphs remain aligned.

## Decision

Render the picker as one rounded, fixed-width text box inside an undecorated child frame. Use the same box-drawing vocabulary and fixed-pitch treatment as Keymap Legend:

- `╭` / `╮` for the titled top border;
- `│` for content sides;
- `├` / `┤` for the query/results separator;
- `╰` / `╯` for the bottom border;
- `─` for horizontal runs.

Implement this in the shared `ri-pick` renderer. `File`, `Buffer`, `Symbol (Document)`, and `Symbol (Workspace)` all use `ri-pick-start`; special-casing only `File` would duplicate the rendering path and make the picker surfaces inconsistent.

Do not call `keymap-legend--border-line` from `ri-pick`. It is a private helper shaped around table segments and junction columns. Reusing its glyph choices and width rules is appropriate; coupling the picker to a private table implementation is not. A small picker-local border-line helper is the shorter stable solution.

## Implementation

### 1. Make query bounds explicit

Update `ri-pick--session` in `ri-pick/ri-pick.el` with `query-start` and `query-end` markers.

The current implementation assumes that the query occupies the complete first buffer line. A visible top border and side glyphs invalidate that assumption. Markers keep the editable query independent from its rendered row without introducing a second query string or synchronizing duplicate state.

Initialize both markers when the picker buffer is created:

- `query-start` points immediately after the query row's `│ ` prefix;
- `query-end` points immediately before its padding and ` │` suffix;
- use insertion type nil for the start marker and non-nil for the end marker so ordinary insertion expands the query range;
- the markers remain owned by the generated picker buffer and become invalid naturally when cleanup kills that buffer.

Update the existing query commands to use these bounds:

- `ri-pick--query` reads only between the markers;
- `ri-pick-delete-backward` stops at `query-start`;
- `ri-pick-delete-forward` stops at `query-end`;
- `ri-pick-query-beginning` and `ri-pick-query-end` move to the markers;
- picker startup places point at `query-start`, not `point-min`.

Keep printable-key handling, filtering, provider debounce, acceptance, and cancellation unchanged.

### 2. Render the complete box

Update `ri-pick--render` to rebuild the full visual surface from the session model.

Before erasing the buffer, capture:

- the current query with `ri-pick--query`;
- point's offset within the query, clamped to its bounds.

Render these rows at exactly `window-body-width` columns:

1. titled top border: `╭─ TITLE ─…╮`;
2. editable query row: `│ QUERY… │`;
3. separator: `├────…┤`;
4. visible result, status, or `No matches` rows: `│ … │`;
5. empty framed rows as needed to keep the bottom border at the child-frame bottom;
6. bottom border: `╰────…╯`.

Use `string-width`, `truncate-string-to-width`, and `make-string`, matching the width-safe approach already used by Keymap Legend and `ri-pick--result-text`. Reserve two columns for the side glyphs and one padding column on each side before calculating label and annotation width.

After rendering:

- reset `query-start` and `query-end` around the unpadded query text;
- restore point from the saved query offset;
- retain read-only properties on every border, padding, result, status, and empty row;
- leave only the query marker range editable;
- retain `ri-pick-item` properties on result rows;
- set window point to the query and window start to the top border.

Apply `fixed-pitch` to the rendered picker surface so box glyphs and padding align even when the source buffer uses a variable-pitch face. Keep `ri-pick-selected` and `ri-pick-annotation`; their faces must affect content, not replace the border glyph face.

Do not truncate or mutate the user's query merely to keep the right border visible. Preserve the current long-query behavior; horizontal overflow is separate from this visual repair.

### 3. Account for frame rows

Update `ri-pick--visible-count`.

The body will now reserve four structural rows: top border, query, separator, and bottom border. Return:

```elisp
(max 1 (- body-height 4))
```

Use this count for paging, selection clamping, result slicing, and blank-row filling. The existing minimum height of eight rows leaves at least four result rows under normal geometry; the defensive `max 1` keeps small-frame behavior safe.

### 4. Remove duplicate native chrome

Update `ri-pick--frame-parameters`:

- set `(undecorated . t)`;
- keep `(border-width . 0)`;
- set `(internal-border-width . 0)`;
- set `(child-frame-border-width . 0)`.

The text box becomes the sole visible frame. Keeping native borders or a graphical title bar would produce a double frame and would differ between GUI and TTY displays.

Remove the picker-specific `header-line-format` assignment from `ri-pick-start`. The title now belongs in the rounded top border. Keep `header-line-format`, `mode-line-format`, fringes, scroll bars, and line numbers disabled in `ri-pick-mode`.

Do not replace `display-buffer-in-child-frame`, geometry calculation, resize hooks, or `quit-window` cleanup. Those already provide the correct surface lifecycle.

## Regression Coverage

Update `ri-pick/ri-pick-test.el` with one focused rendering contract test using the real `ri-pick--render` and an in-memory picker buffer.

Assert that:

- the first line starts with `╭─ File ` and ends with `╮`;
- the query row starts and ends with `│`;
- the separator is `├` + horizontal run + `┤`;
- every result and blank row starts and ends with `│`;
- the final line starts with `╰`, ends with `╯`, and has the same display width as every other row;
- total row count matches the fallback picker height;
- inserting a query, rerendering, and moving the selection preserves the exact query and point offset;
- Backspace, Delete, `C-a`, and `C-e` cannot enter or delete the frame glyphs;
- the selected item's text still has the `ri-pick-selected` face and its row retains the `ri-pick-item` property.

Extend `ri-pick-test-start-uses-display-buffer-child-frame-action` to inspect the captured child-frame parameters and require:

- `undecorated` is non-nil;
- all three native border widths are zero;
- the picker buffer has no header line.

Keep the existing cancellation test unchanged. Rendering changes must not alter the source frame, source window, source point, active Extend bounds, submode, or active edge.

Do not add screenshot fixtures or golden files. The box is deterministic text; display-width and marker-boundary assertions cover the contract without brittle terminal-specific snapshots.

## Verification

Run the picker tests:

```sh
emacs -Q --batch \
  -L . -L ri-pick -L ri-tabs -L semantic-regions -L mini-modal \
  -l ri-pick/ri-pick-test.el \
  -f ert-run-tests-batch-and-exit
```

Then verify the actual surface in `emacs -Q -nw` with `tty-child-frames` available:

1. open `Pick > File` with `SPC k d`;
2. confirm one rounded border surrounds the title, query, separator, results, and unused rows;
3. confirm there is no native title bar, second border, header line, fringe, scroll bar, or stale Keymap Legend;
4. type, delete, and yank query text; confirm the border never becomes editable and the cursor stays in the query;
5. move and page through results; confirm the selected background stays inside the side borders;
6. resize the terminal narrower and wider; confirm every border line remains aligned and the bottom border stays at the picker bottom;
7. test zero matches, provider loading, and provider error states inside the same frame;
8. accept and cancel; confirm cleanup removes the child frame and cancellation restores source point and Extend state exactly;
9. open Buffer, Document Symbol, and Workspace Symbol pickers and confirm the shared frame adapts to each title.

If a graphical Emacs frame is available, repeat the open/resize/cancel smoke check once to confirm that removing native decorations leaves the same single text border as the TTY path.

## Documentation

`PICK-LAYER-IMPLEMENTATION-PLAN.md` already specifies the rounded frame, and `README.md` already describes a centered child-frame picker. No documentation wording change is required unless implementation reveals a user-visible key or behavior change.

## Non-Goals

- Do not change picker geometry, fuzzy matching, candidate ordering, providers, or key bindings.
- Do not add a shared box-drawing package or export Keymap Legend internals.
- Do not special-case File rendering inside the shared picker engine.
- Do not add mouse selection, horizontal query scrolling, shadows, colors, animations, or configurable border glyphs.
- Do not change Keymap Legend rendering itself.
