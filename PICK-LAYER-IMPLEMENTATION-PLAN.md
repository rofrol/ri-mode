# Pick Layer implementation plan

## Goal

Add Ki-compatible `Pick` under `SPC k` with four complete pickers:

| Key | Picker |
| --- | --- |
| `f` | Buffer |
| `d` | File |
| `s` | Symbol (Document) |
| `S` | Symbol (Workspace) |

The picker must be a centered floating surface after the `Pick` menu legend closes. Opening, filtering, and cancelling a picker must preserve the exact source point and any active Extend bounds and active edge.

## UI decision

Use Emacs' buffer-display primitives for both menu legends and pickers.

- `keymap-legend` displays its owned buffer with `display-buffer-in-side-window`.
- `ri-pick` displays its owned buffer with `display-buffer-in-child-frame`.
- Both surfaces are represented by the `window` returned by `display-buffer`.
- `ri-pick` must not call `make-frame` directly or introduce a second low-level frame manager.
- Cleanup uses the window's `quit-restore` data through `quit-window`; child-frame creation and deletion remain implementation details of `display-buffer`.


## Picker surface

Use one buffer and one child-frame window:

```text
╭─ File ───────────────────────────────────────╮
│ query                                        │
├──────────────────────────────────────────────┤
│ src/ri.el                                    │
│ src/ri-lsp.el                                │
│ ri-pick/ri-pick.el                           │
╰──────────────────────────────────────────────╯
```

The first buffer line is editable query text. Remaining lines are read-only rendered results. Point stays in the query; selection movement changes an index rather than moving point into the result list.

Default geometry is configurable and centered in the parent frame's usable rectangle. The usable bottom edge is the frame edge above its live minibuffer. Geometry is recomputed whenever the parent frame changes size. The child frame is clamped on small terminals.

## Shared picker engine

Create `ri-pick/ri-pick.el` with:

- a single active session containing source frame/window/buffer/point, item collection, filtered results, selected index, display window, debounce timer, request cancellation function, accept callback, and close callback;
- an `ri-pick-item` record with label, annotation, search text, and target;
- stable case-insensitive fuzzy filtering supporting duplicate labels;
- a custom major mode that explicitly disables Ri modal editing and binds text entry, deletion, `C-j`/`C-k`, arrows, paging, `RET`, `Esc`, and `C-g`;
- idempotent cleanup for accept, cancel, external buffer/frame deletion, and provider errors;
- a dynamic provider contract for workspace symbols with debounce, cancellation, and stale-response rejection.

The picker-specific keymap remains active only for input and navigation. It is not passed to `keymap-legend-show`; the picker owns only its child-frame surface.

## Sources

### Buffer

Expose Ri Tabs' existing open-file definition as `ri-tabs-file-buffer-list` and migrate all internal callers and tests. Build candidates from those live file buffers, using paths relative to the current project where possible. Accept with `switch-to-buffer` in the original source window.

### File

Use `project-current`, `project-root`, and `project-files`; this preserves project backend ignore semantics and remote-project support without a new `fd`/`rg` dependency. If there is no project, enumerate regular files below `default-directory`. Display relative paths and retain absolute paths as targets. Accept with `find-file` in the original source window.

### Symbol (Document)

In `ri-lsp.el`, preflight the active Eglot server and `:documentSymbolProvider` without leaving Extend. Obtain the hierarchical index through public `eglot-imenu`, flatten it with container names and symbol kinds, and store buffer positions as targets. Only accepting a result exits Extend and navigates.

### Symbol (Workspace)

In `ri-lsp.el`, preflight `:workspaceSymbolProvider`, then open the picker immediately. Debounced query changes send asynchronous `workspace/symbol` requests through Eglot/JSON-RPC. Normalize `SymbolInformation` and `WorkspaceSymbol` responses into `ri-pick-item` values. Cancel superseded work and ignore every response whose picker session or generation is stale. Accept through Xref-compatible navigation, exiting Extend only after a valid choice.

## Space Layer integration

Add `ri--pick-layer-map` and bind `k` in `ri--space-layer-map` to `ri-pick-menu`. Each picker wrapper changes `ri--menu-state` from `pick` to `picker` before clearing the transient map so the submenu exit callback cannot perform competing cleanup, then hides the menu legend before opening the picker. Picker cleanup returns the menu state to nil.

Add `SPC k` to the normal help map and document the four sequences in `README.md`.

## Invariants

- Opening and filtering never changes the source buffer's point or selection.
- Cancelling restores the original frame, window, buffer, point, Extend bounds, and active edge exactly.
- Buffer and File selection do not destroy buffer-local Extend state left in another buffer.
- Document and Workspace symbol selection exit Extend only immediately before the accepted jump.
- Unsupported or unmanaged Eglot buffers fail before opening the picker and preserve Extend exactly.
- A stale asynchronous response cannot update a newer or closed picker.
- Cleanup leaves no child frame, picker buffer, timer, request, hook, or menu state behind; picker startup and cleanup never own a keymap legend.

## Files

### Add

- `ri-pick/ri-pick.el`
- `ri-pick/ri-pick-test.el`

### Modify

- `keymap-legend/keymap-legend.el`
- `keymap-legend/keymap-legend-test.el`
- `ri-tabs/ri-tabs.el`
- `ri-tabs/ri-tabs-test.el`
- `ri-lsp.el`
- `ri-lsp-test.el`
- `ri.el`
- `README.md`

## Implementation order

1. Add the public Ri Tabs buffer query and establish the menu-to-picker legend handoff.
2. Implement the one-window picker engine and display-buffer lifecycle.
3. Add Buffer and File providers.
4. Add document and asynchronous workspace symbol providers.
5. Wire the exact Ki Space/Pick keymaps and menu lifecycle.
6. Add behavioral ERT coverage and update user documentation.
7. Run targeted suites, then byte-compile/load checks, then exercise the real TTY UI with all four picker paths and terminal resize.

## Verification

ERT coverage must defend:

- exact `SPC k f/d/s/S` bindings and menu labels;
- the `Pick` side-window legend closing before the child-frame picker display action;
- cancel preserving exact Extend bounds, point, submode, and active edge;
- accepted document/workspace jumps leaving Extend before movement;
- file target identity despite duplicate display names;
- buffer candidate filtering and switching;
- workspace debounce, cancellation, stale responses, errors, and cleanup;
- geometry that uses the full parent area above the live minibuffer;
- external picker buffer/frame deletion and repeated cleanup.

The final smoke check must run `emacs -Q -nw` with `tty-child-frames`, invoke the four pickers through real key sequences, confirm that no legend remains below the floating picker, select and cancel candidates, and resize the terminal while the picker is open.
