# Frame-Wide Native Tab Bar Plan

## Goal

Move the Ki-style file tabs from Emacs's window-local Tab Line to one native
Tab Bar spanning the top of each normal frame.

The change must preserve the existing file-tab contract:

- persistently marked file buffers are shown in stable path order;
- the selected window's current unmarked file is appended after marked files;
- markers, modified state, shortest unique path labels, persistence, restoration,
  and Buffer-layer navigation keep their current meaning;
- selecting a file tab changes only the buffer in the frame's selected window;
- closing a file tab kills its buffer without removing its persistent mark.

No window may retain an Ri-owned `tab-line-mode` row after the migration.

## Confirmed Emacs Model and Decision

Emacs exposes two different native tab interfaces:

1. `tab-line-mode` is a buffer/window-local row whose entries normally switch
   buffers in one window. This is what `ri-tabs` currently configures, so every
   split window receives its own row.
2. `tab-bar-mode` is one row at the top of a frame. Its built-in tab objects are
   persistent **window configurations**, not file buffers.

Do not create one built-in Tab Bar tab object per marked file. Selecting such an
object would restore a complete window configuration, closing one would close a
workspace, and a split layout would acquire independent state per file. Those
semantics conflict with the current Ri commands, which call `switch-to-buffer`
in the selected window and leave the rest of the frame unchanged.

Use the native Tab Bar as the frame-wide rendering surface instead:

- enable `tab-bar-mode`;
- install an Ri formatter through the documented `tab-bar-format` extension
  point;
- return native Tab Bar `menu-item` entries backed by Ri file buffers;
- leave the frame's built-in `tabs` parameter and `tab-bar-tabs-function`
  untouched.

In particular, do not replace `tab-bar-tabs-function`. Core commands such as
`tab-next`, `tab-bar-select-tab`, `tab-close`, tab dragging, and tab history use
that function as the source of real window-configuration objects. Supplying
buffer pseudo-tabs there would make those commands mutate or restore the wrong
state.

## Behavioral Contract

1. Each ordinary frame displays exactly one Ri file-tab row, regardless of how
   many windows the frame contains.
2. All live marked file buffers remain globally visible on every ordinary
   frame, matching the current global persistent mark store.
3. The active tab on a frame is the file shown by that frame's selected
   non-minibuffer window.
4. Selecting another window moves the active appearance to that window's file;
   it does not add another row or alter either window's buffer.
5. If that selected file is unmarked, it is appended once after all marked
   buffers. Other unmarked files displayed in non-selected windows are not
   added to the row.
6. If the selected window shows a non-file or hidden buffer, only marked file
   tabs are shown and no tab is active.
7. Clicking an inactive file tab displays its buffer in the selected ordinary
   window of the clicked frame. The split tree, all other window buffers,
   window selection, and native Tab Bar workspace data remain unchanged.
8. Middle-clicking or invoking the tab's close action kills that file buffer
   through normal `kill-buffer` behavior, including the normal modified-buffer
   query. It does not unmark the file.
9. Marked, unmarked, modified, and marked-modified indicators retain their
   current strings and meaning.
10. Shortest unique path suffixes are computed from the tabs rendered on that
    frame. A literal `%` in a file name is displayed once; unlike a mode-line
    format string, a Tab Bar menu label does not require doubling `%`.
11. Multiple normal frames get one bar each. Their marked set is the same, but
    their active/current-unmarked tab may differ because selection is
    frame-local.
12. Auxiliary child frames such as `status-frame` remain without menu, tool,
    tab, mode, and header lines.
13. Disabling `ri-tabs-mode` restores the exact Tab Bar visibility, format, and
    relevant input bindings that existed before Ri was enabled.
14. Existing user-owned `tab-line-mode` state is not changed. Ri stops enabling,
    configuring, disabling, or restoring Tab Line variables entirely.

## Tab Bar Ownership

While `ri-tabs-mode` is enabled, Ri owns the visible tab-list portion of the
native Tab Bar. Built-in window-configuration tabs remain stored by Emacs but
are not presented as file tabs and must never be mutated as a side effect of a
file-tab action.

Capture the pre-existing Tab Bar state before installation and restore it on
disable. The saved state must include:

- whether `tab-bar-mode` was enabled;
- the default values of `tab-bar-format` and `tab-bar-show`;
- every Tab Bar mouse/touch/wheel binding changed by Ri;
- the `tab-bar-lines` and `tab-bar-lines-keep-state` parameters of each live
  frame present at activation;
- the prior `tab-bar-lines` entry in `default-frame-alist`.

Install one predictable Ri format rather than mixing file tabs with the native
workspace tab renderer, add-workspace button, or workspace-history controls.
Unrelated native Tab Bar content can be supported later only with an explicit
composition contract; silently combining two kinds of tabs in one undelimited
row would make selection and close behavior ambiguous.

Installation and restoration must be idempotent. Save state only on the first
enable, restore only state owned by Ri, clear the snapshot after a successful
disable, and roll back a partial installation if enabling signals an error.

## Frame Context

Refactor rendering helpers so they do not infer the current file from an
ambient `(window-buffer)` call.

1. Add a helper that receives a frame and returns its selected ordinary window.
   During minibuffer activity, use the window that selected the minibuffer when
   it is live and belongs to that frame; never treat the minibuffer as the
   active file tab.
2. Make the display-list helper accept the selected buffer explicitly. It
   should return marked buffers followed by that buffer only when it is a live,
   visible, unmarked file buffer.
3. Pass the same selected buffer through label formatting and selected-face
   selection. This prevents redisplay of one frame from borrowing the selected
   buffer of another frame.
4. Make selection commands resolve the clicked frame's target window at action
   time. A stale or deleted window must fall back to that frame's current
   selected ordinary window, not to a window on another frame.
5. Before switching or killing, verify that the captured buffer is still live.
   A stale menu item should request a refresh and do nothing destructive.

The persistent mark list remains process-global. This migration changes only
where it is rendered and how the frame-specific active buffer is supplied.

## Native Renderer

In `ri-tabs/ri-tabs.el`:

1. Replace `(require 'tab-line)` with `(require 'tab-bar)`.
2. Keep the public Ri face names, but change their native inheritance:
   - `ri-tabs-tab` inherits `tab-bar-tab-inactive`;
   - `ri-tabs-current-tab` inherits `tab-bar-tab` while retaining the explicit
     black foreground, `#ffffff` background, bold weight, and no box;
   - `ri-tabs-highlight` inherits `tab-bar-tab-highlight`.
3. Split the current `ri-tabs--format-tab` responsibilities:
   - one helper creates the marker/name label and its face/help properties;
   - one frame-level formatter builds the complete list of Tab Bar
     `menu-item` entries.
4. Use `current-tab` and `tab-N` item keys, or add an Ri predicate to
   `tab-bar-auto-width-functions`, so native `tab-bar-auto-width` recognizes
   file items and keeps a long row on one physical line. Do not implement a
   second truncation or scrolling system beside Emacs's native one.
5. Give inactive items a command that switches the clicked frame's selected
   window to the captured live buffer. The current item is inert.
6. Preserve padded labels, marker selection, shortest unique suffixes,
   active/inactive faces, hover face, and full-path help text.
7. Do not attach `tab-line-tab-map`, `tab`, `selected`, or other Tab
   Line-specific text properties. A Tab Bar item is a menu item, not a
   mode-line string.
8. Remove `%` doubling from the Tab Bar label path and cover a literal `%`
   filename with a regression test.
9. Do not call private native tab selection/close functions for file items.
   They operate on window-configuration tabs, not buffers.

## Pointer, Touch, and Wheel Input

The global native `tab-bar-map` assumes every `tab-N` item identifies a real
window-configuration tab. Once the visible entries are file tabs, leaving that
map unchanged would make middle-click, dragging, the context menu, touch input,
and wheel input operate on hidden workspace tabs.

Install an Ri input layer for the duration of `ri-tabs-mode` and restore the
original bindings exactly on disable:

- primary click selects the file buffer associated with the rendered item;
- middle click closes that buffer;
- context menu actions operate on the file buffer only, at minimum Select,
  Mark/Unmark, and Close;
- touch selection and close mirror pointer behavior;
- wheel navigation delegates to the existing Ri buffer-navigation commands;
- drag and Shift-wheel reordering are ignored because marked tabs are sorted by
  path and have no user-defined order.

Keep a frame-local mapping from the currently rendered item keys to buffer
objects so event handlers act on the item the user actually saw. Rebuild that
mapping together with the menu items, reject dead buffers, and never decode a
buffer solely from a mutable buffer name. Isolate any unavoidable use of an
Emacs event-decoding helper behind one small function and test both graphical
and TTY event shapes; do not spread `tab-bar--*` calls through the package.

Native Tab Bar keyboard shortcuts that would select hidden workspace tabs must
not be advertised as file-tab navigation. Ri's existing Buffer-layer commands
remain authoritative. If activation changes a native shortcut, include that
binding in the saved/restored ownership state rather than changing a global
key permanently.

## Mode Lifecycle Refactor

Remove the window-local UI lifecycle:

- `ri-tabs--managed-variables`;
- `ri-tabs--saved-state`;
- `ri-tabs--tab-line-was-active`;
- `ri-tabs--capture-state`;
- `ri-tabs--set-local-configuration`;
- the Tab Line versions of `ri-tabs--install` and `ri-tabs--restore`;
- `ri-tabs--cache-key`.

Replace it with one global/frame lifecycle:

1. `ri-tabs--enable` installs hooks, captures the pre-existing native Tab Bar
   state, installs the Ri format/input layer, enables `tab-bar-mode`, and then
   runs the existing persistent activation.
2. Set `tab-bar-show` to `t`, the documented unconditional-visibility value,
   because Ri items are not counted as native window-configuration tabs.  A
   numeric value is a native-tab-count threshold and must not control Ri
   visibility.  Apply it before enabling the mode so all normal existing and
   future frames receive one line.  While Ri owns an ordinary frame, also pin
   `tab-bar-lines-keep-state` to `t` and `tab-bar-lines` to `1`; restore both
   captured values exactly on disable.
3. `ri-tabs--disable` removes hooks, restores native Tab Bar state, and clears
   only `ri-tabs--marked-p` and `ri-tabs--file-id` from live buffers. It must not
   touch any Tab Line variable or mode.
4. `find-file-hook` only restores the persistent mark/file identity and
   refreshes the frame bar. It no longer installs buffer-local UI.
5. `after-set-visited-file-name-hook` keeps its identity migration behavior but
   no longer installs or restores Tab Line state.
6. Remove `after-change-major-mode-hook`: it exists to reinstall buffer-local
   Tab Line configuration after a major-mode reset and is unnecessary for a
   frame-global bar.
7. Retain kill, first-change, save, and revert refresh hooks because liveness
   and marker state still affect labels.
8. Add default `window-selection-change-functions` and
   `window-buffer-change-functions` handlers so focus changes and buffer
   switches update the active tab without requiring an Ri navigation command.
9. Preserve the existing activation batching flags. During restoration,
   refresh requests remain deferred and one final frame-wide refresh is issued.

Use `force-mode-line-update` with the all-windows/all-frames argument as the
public invalidation mechanism. `tab-line-force-update` and the per-window
`tab-line-cache` no longer apply. Do not clear private Tab Bar caches: native
auto-width keys already include the rendered labels, faces, and selected frame.

## Auxiliary Frames

`status-frame/status-frame.el` already creates its child frame with
`(tab-bar-lines . 0)`. Add `(tab-bar-lines-keep-state . t)` to that frame's
parameters so global `tab-bar-mode` updates cannot turn the auxiliary status
frame into a second tab bar. Keep its existing `after-make-frame-functions`
isolation and all zero-line buffer/window settings.

Apply the same structural eligibility rule to any Ri frame hook: normal
top-level frames receive the bar; child, tooltip, no-focus, and minibuffer-only
frames do not.  A pre-existing `tab-bar-lines-keep-state` on an otherwise
ordinary frame is user state to save and restore, not an opt-out from Ri while
Ri owns the frame-wide row.  Auxiliary frames such as `status-frame` combine
structural ineligibility with `tab-bar-lines-keep-state` so native Tab Bar
updates cannot turn their zero-line setting back on.  Do not identify the
status frame by its display name when structural frame parameters can express
the rule.

## Files to Change During Implementation

### `ri-tabs/ri-tabs.el`

- migrate the dependency, faces, renderer, actions, event bindings, refresh
  path, and mode lifecycle described above;
- keep persistence, file identity, restoration, marker mutation, suffix naming,
  and navigation algorithms unchanged unless an explicit frame argument is
  required;
- update package commentary and docstrings from “tab line above file windows”
  to “one file tab bar per frame.”

### `ri-tabs/ri-tabs-test.el`

- replace Tab Line installation/format/cache assertions with native Tab Bar
  assertions;
- preserve all persistence, restoration, rename, failure, and navigation tests;
- make the fixture snapshot and restore global Tab Bar state even when a test
  fails, so tests remain full-suite safe.

### `ri-extend-test.el`

Update `ri-extend-test-ri-enable-shows-tabs-for-new-file` to prove that
`ri-enable` installs the frame-wide formatter, renders the current file once,
and does not enable `tab-line-mode` in the file buffer.

### `status-frame/status-frame.el`

Protect the child frame's zero Tab Bar line with
`tab-bar-lines-keep-state`.

### `README.md`

State that file tabs occupy one native Tab Bar per frame, selection targets the
selected window, and splitting a frame does not duplicate the row. Keep the
persistent mark/close explanation unchanged.

Historical `*-PLAN.md` files describe the changes they planned at that time and
do not need retroactive terminology edits.

## Regression Coverage

Add or update tests for these observable contracts:

1. **Explicit frame current buffer**
   The display list accepts an explicit selected buffer and returns marked tabs
   plus only that unmarked current file.
2. **Native menu structure**
   The renderer returns Tab Bar `menu-item` entries with stable item keys,
   labels, help, commands, and current/inactive faces; it returns no Tab Line
   keymap or cache properties.
3. **Literal percent label**
   A file named `100%.el` renders as `100%.el`, not `100%%.el`.
4. **One bar across a split**
   With two windows showing different files, the frame has one Tab Bar line,
   neither buffer gains Ri-owned `tab-line-mode`, and selecting the other window
   changes only the active rendered item.
5. **Selection preserves layout**
   Invoke an inactive rendered item's action and assert that the selected
   window changes buffer while the window count, window tree, other window's
   buffer, and native frame `tabs` parameter stay unchanged.
6. **Close preserves the mark**
   Invoke the file-tab close path, assert the buffer is killed, and assert its
   canonical identity remains in persistent state.
7. **Dead rendered item is harmless**
   Kill a captured buffer before invoking its action; the command must not
   select or kill an unrelated buffer.
8. **Focus and minibuffer routing**
   Window selection changes move the active face, while minibuffer activation
   keeps the originating file active.
9. **Multiple-frame context**
   When the test environment supports additional frames, two frames can render
   different active files from the same marked set without leaking selection
   between them. Otherwise cover this in the required manual smoke test rather
   than treating a skipped batch test as proof.
10. **Exact mode restoration**
    Cover both initially disabled and initially enabled/customized Tab Bar
    states. Disable must restore format, visibility, frame parameters, input
    bindings, and `default-frame-alist` exactly.
11. **Existing Tab Line ownership**
    A buffer with pre-existing user-local Tab Line settings is byte-for-byte
    unchanged across Ri enable/disable.
12. **New and auxiliary frames**
    A normal frame created after activation receives one row; the status child
    frame remains at zero rows.
13. **Refresh batching**
    Replace the `tab-line-force-update` mock in the restoration test with the
    frame-wide invalidation path and continue requiring one final Ri refresh.
14. **Integration through `ri-enable`**
    The existing integration test renders the new file in the frame bar and
    proves that no per-window row was installed.

## Verification

1. Run the complete `ri-tabs` ERT suite:

   ```sh
   emacs --batch -Q -L ri-tabs -l ri-tabs/ri-tabs-test.el \
     -f ert-run-tests-batch-and-exit
   ```

2. Run the Ri integration suite with all local package directories on the load
   path:

   ```sh
   emacs --batch -Q \
     -L . -L ri-tabs -L keymap-legend -L kkp-chord -L mini-modal \
     -L modal-cursor -L semantic-regions -L status-frame \
     -l ri-extend-test.el -f ert-run-tests-batch-and-exit
   ```

3. In graphical `emacs -Q`, enable `ri-tabs-mode`, open and mark at least three
   files, split the frame horizontally and vertically, and verify:
   - one row spans the frame above all windows;
   - no window has its own Ri Tab Line;
   - selecting each window moves the active tab to that window's file;
   - clicking a tab changes only the selected window;
   - middle-click closes the file buffer without removing its mark;
   - long labels stay on one native Tab Bar line.
4. Repeat the split-window smoke test in `emacs -Q -nw` to cover the terminal
   Tab Bar and TTY mouse/event representation.
5. Create a second normal frame after activation. Select different files in the
   two frames and verify that each frame highlights its own active file while
   showing the same marked set.
6. Show the TTY status child frame and verify that it remains line-free and its
   geometry is unchanged.
7. Start with a customized, already-enabled native Tab Bar, record its format
   and frame visibility, enable then disable `ri-tabs-mode`, and verify exact
   restoration.
8. Exercise mark, unmark, save, rename, close, restart restoration, and all
   Buffer-layer navigation commands once to confirm the renderer migration did
   not change the persistence model.

## Completion Criteria

The migration is complete when:

- every normal frame has one native frame-wide Ri file-tab row and split windows
  have no Ri-owned Tab Lines;
- tab selection and close actions operate on file buffers in the selected
  window without changing the window layout or native workspace tabs;
- active state is correct across window focus, minibuffer use, and multiple
  frames;
- marks, modified indicators, labels, persistence, restoration, and navigation
  retain their existing behavior;
- auxiliary frames remain free of tab bars;
- disabling the mode restores all pre-existing Tab Bar and Tab Line state;
- both ERT suites pass and the graphical and TTY smoke scenarios above are
  observed successfully.
