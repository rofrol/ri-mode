# Space LSP Transient-Map Fix Plan

## Problem

In an Odin buffer, `SPC x` successfully follows the definition through Eglot/Xref and opens the destination file. The first subsequent `k` should run normal downward navigation through `ri-extend-nav-down`, but it instead resolves through the old Space layer and opens the `Pick` submenu.

Pressing `a` first appears to repair the problem: `a` switches the semantic unit to `LINE`, and the following `k` navigates normally. The defect is not Odin-, Eglot-, Xref-, or selection-unit-specific. It is a stale transient keymap left above the destination buffer's normal keymaps.

## Root Cause

The current command lifecycle in `ri.el` is:

1. `ri-space-menu` installs `ri--space-layer-map` with `KEEP-PRED` equal to `t`.
2. `x` resolves to `ri-find-definition` through that map.
3. Because `x` is a Space-map binding and `KEEP-PRED` is `t`, Emacs retains the Space transient map for another command.
4. `ri--run-space-lsp-command` calls `(set-transient-map nil)` before dispatching to `ri-lsp--find-definition`.
5. That call does not deactivate the retained map. The supported deactivation mechanism is the exit function returned by the original `set-transient-map` call; installing a new nil map can still fall through to the retained Space map.
6. Xref changes the selected buffer, but `overriding-terminal-local-map` is terminal-local rather than buffer-local, so the retained Space map remains above the destination buffer's normal map.
7. The next `k` therefore resolves to `ri-pick-menu`, because `k` is `Pick` in `ri--space-layer-map`.

`a` masks the problem because it is not bound in `ri--space-layer-map`. It falls through to `mini-modal-map`, runs `ri-extend-set-line-mode`, and gives Emacs a command-loop transition that deactivates the stale Space map. The following `k` can then reach `ri-extend-nav-down`.

A batch command-loop reproduction with the real `set-transient-map` implementation produced `menu=pick` after `x k`. Replacing the Space map's `KEEP-PRED` with nil in the same reproduction produced `menu=nil` and dispatched `k` to the destination buffer.

## Decision

Make the Space menu one-shot.

Pass nil as `KEEP-PRED` when `ri-space-menu` installs `ri--space-layer-map`. The map still owns the next key lookup, so `SPC x`, every other LSP binding, `SPC k`, `SPC j`, and `Esc` keep their existing key sequences. Emacs then deactivates the Space map and runs its exit callback before executing the selected command.

Remove the invalid `(set-transient-map nil)` call from `ri--run-space-lsp-command`. Keep `ri--close-menu` there as idempotent UI cleanup for direct invocation and error paths, and keep `ri--call-preserving-user-error` unchanged so Eglot capability errors survive the following Kitty release event.

This is smaller and safer than storing a new global exit-function variable:

- the Space UI selects exactly one action;
- submenu commands already install their own transient maps;
- `ri-pick-menu` and `ri-transform-menu` already demonstrate the repository's one-shot transient-map pattern;
- no new lifecycle state, advice, buffer hook, or destination-buffer special case is required.

## Implementation

### 1. Make `ri-space-menu` one-shot

Update `ri-space-menu` in `ri.el`:

- change the second `set-transient-map` argument from `t` to `nil`;
- retain `ri--space-layer-map`, all current labels and bindings, and the `Space` legend;
- retain the on-exit callback guarded by `(eq ri--menu-state 'space)`;
- do not mutate `overriding-terminal-local-map` directly.

Expected ordering for `SPC x`:

1. `x` resolves through `ri--space-layer-map`;
2. Emacs deactivates that one-shot map;
3. the existing on-exit callback closes the Space legend and menu state;
4. `ri-find-definition` dispatches through Eglot/Xref;
5. the first key in the destination buffer resolves through its normal active keymaps.

Expected ordering for `SPC k` and `SPC j`:

1. the submenu key resolves through `ri--space-layer-map`;
2. the Space map exits and closes its UI;
3. `ri-pick-menu` or `ri-editor-menu` installs the submenu's own map and legend.

No key assignment or user-visible menu label changes.

### 2. Remove the false clear from LSP dispatch

Update `ri--run-space-lsp-command` in `ri.el`:

- remove `(set-transient-map nil)`;
- keep `ri--close-menu` before the LSP call;
- keep `ri--call-preserving-user-error` around the supplied function;
- adjust the docstring if needed so it describes Space UI cleanup rather than claiming to cancel a transient map itself.

All eight public LSP commands already share this wrapper, so this single change covers Definition, Declaration, Type Definition, References, Implementations, and both call-hierarchy directions. Do not add per-command cleanup.

### 3. Correct the LSP navigation design document

Update `KI-LSP-NAVIGATION-PLAN.md` where it currently describes the Space layer as persistent and the wrapper as clearing the transient map:

- describe the Space map as one-shot;
- state that Emacs owns map deactivation through `set-transient-map` lifecycle;
- state that the shared wrapper performs idempotent menu-surface cleanup and error-preserving LSP dispatch;
- change the menu test expectation from persistent to one-shot behavior.

`README.md` needs no change: the user-facing keys and navigation semantics remain the same.

## Regression Coverage

### `ri-lsp-test.el`

Update `ri-lsp-test-space-opens-ki-layer-with-legend` to require:

- `ri--space-layer-map` is installed;
- `KEEP-PRED` is nil;
- the on-exit callback remains present;
- the title, legend map, LSP bindings, Pick binding, and `Esc` binding remain unchanged.

Add one command-loop regression test using the real `set-transient-map` implementation rather than mocking it:

1. create source and destination buffers;
2. bind `k` in the destination buffer to a small sentinel navigation command;
3. stub only `ri-lsp--find-definition` so it switches to the destination buffer;
4. open `ri-space-menu` and execute `x k` as keyboard input;
5. assert that Definition dispatch selected the destination buffer;
6. assert that the destination `k` command ran;
7. assert that `ri-pick-menu` did not run and `ri--menu-state` is nil;
8. clean up transient exit functions and temporary buffers with `unwind-protect`.

The test must exercise command lookup. A unit test that directly calls `ri-find-definition`, or a test that mocks `set-transient-map`, cannot reproduce the precedence bug.

Keep the existing `ri-lsp-test-picker-first-query-keys-bypass-menu-maps` test. Its real `SPC k d ...` sequence covers the parent-Space-to-Pick handoff and guards against breaking submenu entry when the parent map becomes one-shot.

Keep the existing Extend tests. This fix changes only menu-map lifetime: it must not reinterpret a selection, alter its bounds, move its active edge, or change the existing rule that successful LSP navigation exits Extend only after provider preflight succeeds.

## Verification

Run the focused integration suite with the external `kkp.el` directory available:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs --batch -Q -L "$KKP_DIR" -L . \
  -l ri-lsp-test.el \
  -f ert-run-tests-batch-and-exit
```

Then verify the real UI in an Eglot-managed Odin project:

1. From an Odin symbol, press `SPC x` and confirm that its definition opens.
2. Immediately press `k`; confirm normal downward navigation and confirm that no `Pick` legend opens.
3. Repeat the jump and press `i`, `j`, and `l`; confirm each reaches normal navigation without a sacrificial `a` command.
4. Confirm `SPC k d` still opens the file picker and accepts its first query key.
5. Confirm `SPC j` still opens the Editor submenu.
6. Trigger `SPC x` in an unmanaged buffer; confirm the Eglot error remains visible and the Space legend/map is gone.
7. Repeat from an active Extend selection: failed preflight must preserve exact bounds, submode, active edge, and point; successful navigation must exit Extend before the jump.

## Non-Goals

- Do not change `ri-lsp.el`, Odin language-server configuration, Xref display behavior, or semantic-region navigation.
- Do not remap `k`, special-case Odin buffers, replay key events, or suppress `ri-pick-menu` after a definition jump.
- Do not add a general transient-menu registry or refactor unrelated Editor, Surround, Transform, or chord layers as part of this focused fix.
- Do not change selection bounds or snap the destination to a different semantic unit.
