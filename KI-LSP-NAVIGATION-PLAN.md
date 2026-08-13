# Ki LSP Navigation Layer — Implementation Plan

## Goal

Add the following Ki Editor actions to `ri-mode` directly in the Space layer, preserving Ki's key positions and labels:

| Key | Label | Meaning |
| --- | --- | --- |
| `Z` | `Out Calls` | Show callees of the symbol at point. |
| `z` | `In Calls` | Show callers of the symbol at point. |
| `x` | `Def` | Find definitions. |
| `X` | `Decl` | Find declarations. |
| `c` | `Type` | Find type definitions. |
| `V` | `Ref+` | Find references including the declaration. |
| `v` | `Ref-` | Find references excluding the declaration. |
| `b` | `Impl` | Find implementations. |

All eight actions must use Emacs's Eglot/LSP integration. They must not inspect tree-sitter nodes, derive locations from syntax trees, or silently fall back to tree-sitter when Eglot is unavailable.

## Verified source behavior

Ki defines these bindings in `vendor/ki-editor/src/keymap.rs` inside `secondary_selection_modes_keybindings`:

- `x` / `X`: definition / declaration;
- `b`: implementation;
- `v` / `V`: references without / with the declaration;
- `c`: type definition;
- `z` / `Z`: incoming / outgoing calls.

Ki opens its local secondary-selection menu with `n`, but chains the global secondary-selection bindings directly into the Space layer. These eight requested actions are therefore `SPC` bindings. Their LSP requests and result handling live in `vendor/ki-editor/src/app.rs`; call hierarchy uses `textDocument/prepareCallHierarchy` followed by `callHierarchy/incomingCalls` or `callHierarchy/outgoingCalls`.

Emacs 31's Eglot already supplies the relevant protocol integration and result UIs:

- `xref-find-definitions`, through Eglot's active Xref backend, uses `textDocument/definition`;
- `eglot-find-declaration` uses `textDocument/declaration`;
- `eglot-find-typeDefinition` uses `textDocument/typeDefinition`;
- `eglot-find-implementation` uses `textDocument/implementation`;
- `xref-find-references`, through Eglot's active Xref backend, requests references with `includeDeclaration` set to true;
- `eglot-show-call-hierarchy` uses Eglot's hierarchy buffer and LSP call-hierarchy methods.

Eglot does not expose a public command for references with `includeDeclaration` set to false. That is the only action requiring a narrow adapter around an Eglot internal helper.

## Scope and semantic decisions

### Use native Emacs result surfaces

Definitions, declarations, type definitions, references, and implementations should use Xref behavior: jump directly for one result and display the Xref results UI for multiple results. Incoming and outgoing calls should use Eglot's expandable hierarchy buffer.

Do not build a second Ri-owned location list, quickfix list, or multi-selection engine. Ki represents many of these results as secondary selections, but the requested Eglot-first implementation should retain Emacs's native navigation and history behavior rather than duplicating it.

### Operate on point, not on tree-sitter selection text

LSP position requests are made at point. In NORM, point already identifies the active semantic unit; in Extend, point is on the active selection edge by repository invariant. Do not search the selected text, snap to a syntax node, or attempt to infer a symbol from tree-sitter.

### End Extend before a successful navigation dispatch

An LSP result may move point within the current buffer. Leaving Extend active during that move would violate the invariant that point remains on its active selection edge after Extend navigation. Therefore the shared dispatch path must:

1. verify that the current buffer is managed by Eglot;
2. verify the required server capability;
3. only after those checks succeed, explicitly leave Extend and refresh Ri highlighting and the mode line;
4. invoke the Eglot/Xref command.

If Eglot is absent or the server lacks the requested capability, signal `user-error` before changing point or Extend state. No parser-based fallback is allowed.

### Preserve Ri menu and terminal behavior

The Space layer is a persistent prefix layer with a `Space` legend, matching Ki. Before invoking an LSP action, close the transient map and legend so the Xref or Eglot hierarchy UI becomes the only active result surface. Route `user-error` through the existing `ri--call-preserving-user-error` mechanism so a following Kitty key-release event cannot erase the useful error message.

## Proposed structure

### New `ri-lsp.el`

Keep Eglot-specific protocol adaptation out of the already large `ri.el` integration file.

Responsibilities:

1. Require `eglot`, `xref`, and `ri-extend`.
2. Provide one shared preflight/dispatch helper that:
   - obtains the current Eglot server with `eglot-current-server`;
   - reports a clear `user-error` when the buffer is unmanaged;
   - checks the action's provider capability with `eglot-server-capable-or-lose`;
   - exits Extend only after preflight succeeds;
   - refreshes semantic highlighting and the mode line;
   - invokes the requested operation.
3. Provide private operation functions for the eight actions.
4. Isolate the `Ref-` use of Eglot internals in one function. Do not spread private Eglot calls across the menu integration or tests.
5. Provide the `ri-lsp` feature.

Suggested private operations:

- `ri-lsp--find-outgoing-calls`
- `ri-lsp--find-incoming-calls`
- `ri-lsp--find-definition`
- `ri-lsp--find-declaration`
- `ri-lsp--find-type-definition`
- `ri-lsp--find-references-with-declaration`
- `ri-lsp--find-references-without-declaration`
- `ri-lsp--find-implementations`

Do not add generic protocol abstractions beyond the shared preflight helper. The eight operations differ enough in their public Emacs entry points that explicit functions are easier to review and test.

### `ri.el` integration

1. Require `ri-lsp` after `ri-extend`.
2. Add all eight exact Ki keys and labels to the existing `ri--space-layer-map`; retain its existing `Editor` submenu and `<escape>` binding.
3. Keep `ri-space-menu` as the `SPC` entry point, `Space` legend owner, and persistent transient map.
4. Add a small shared UI wrapper that:
   - clears the transient map;
   - closes the Space legend/menu state;
   - invokes the selected `ri-lsp--...` operation through `ri--call-preserving-user-error`.
5. Add eight explicit interactive `ri-find-...` commands which call that shared wrapper. Explicit commands keep `M-x`, help, tests, and stack traces meaningful; do not dispatch by inspecting `last-command-event`.
6. Do not add a separate `n` menu or change the existing direct NORM bindings.

Suggested public command names:

- `ri-find-outgoing-calls`
- `ri-find-incoming-calls`
- `ri-find-definition`
- `ri-find-declaration`
- `ri-find-type-definition`
- `ri-find-references-with-declaration`
- `ri-find-references-without-declaration`
- `ri-find-implementations`

## Eglot command mapping

### `Out Calls`

Call `eglot-show-call-hierarchy` with Eglot's outgoing-only direction value, `base`.

The name is unintuitive but is the value used by Emacs 31's call-hierarchy specification for `callHierarchy/outgoingCalls`. Keep it hidden behind `ri-lsp--find-outgoing-calls` and cover it with a test; do not expose `base` in labels or user documentation.

Required capability: `:callHierarchyProvider`.

### `In Calls`

Call `eglot-show-call-hierarchy` with direction `incoming`.

Required capability: `:callHierarchyProvider`.

### `Def`

After confirming an Eglot server and `:definitionProvider`, call `xref-find-definitions`. This deliberately uses the public Xref command because Eglot installs itself as the buffer's Xref backend.

Do not call a tags backend or implement a textual fallback when Eglot is absent.

### `Decl`

Call `eglot-find-declaration`.

Required capability: `:declarationProvider`.

### `Type`

Call the exact Emacs command name `eglot-find-typeDefinition`.

Required capability: `:typeDefinitionProvider`.

### `Ref+`

After confirming `:referencesProvider`, call `xref-find-references`. Eglot's Xref backend sends `textDocument/references` with `(:context (:includeDeclaration t))`.

### `Ref-`

Use Eglot's Xref-producing helper for `textDocument/references`, passing:

```elisp
(:context (:includeDeclaration :json-false))
```

The implementation should use the same Eglot/Xref result conversion as `Ref+`, not request raw JSON and maintain a second URI/range conversion path. On Emacs 31 this means a narrow call to `eglot--lsp-xref-helper` with `:extra-params`.

This private call is an accepted, contained compatibility risk. Keep the call in one function and add a focused test for its method and payload. Do not add a fake fallback which fetches `Ref+` results and tries to identify declarations heuristically; LSP servers, languages, and location shapes do not make that filtering reliable.

Required capability: `:referencesProvider`.

### `Impl`

Call `eglot-find-implementation`.

Required capability: `:implementationProvider`.

## Error and edge-case behavior

- **No Eglot server:** report that the current buffer is not managed by Eglot; keep point, current buffer, submode, and exact Extend bounds unchanged.
- **Unsupported server capability:** retain the capability-specific Eglot error and leave Extend unchanged.
- **No LSP results:** let Eglot/Xref report the empty result. Do not synthesize a tree-sitter or text-search result.
- **One result:** allow Xref/Eglot to jump normally and retain its standard marker-stack behavior.
- **Many results:** allow Xref or the Eglot hierarchy buffer to own display and navigation.
- **Remote/TRAMP buffers:** pass through Eglot's URI and workspace handling; do not normalize paths in Ri.
- **Server restart or request failure:** expose the Eglot/JSON-RPC error. Do not catch it and return success.
- **Extend active:** after successful provider preflight, explicitly exit Extend before the operation can move point. Do not preserve a stale selection whose active edge no longer contains point.
- **Non-Extend NORM:** do not change `sr-submode`; after a jump, normal semantic highlighting should retarget through the existing post-command path.

## Tests

Add `ri-lsp-test.el` rather than mixing protocol-navigation coverage into `ri-chord-test.el`.

### Keymap and menu contract

1. Assert all eight exact keys, labels, and public command bindings in `ri--space-layer-map`.
2. Assert lowercase/uppercase pairs are not reversed:
   - `z` is incoming and `Z` is outgoing;
   - `v` excludes and `V` includes declarations;
   - `x` is definition and `X` is declaration.
3. Assert `SPC` still opens `ri-space-menu` and that `n` remains unbound in NORM.
4. Invoke `ri-space-menu` with legend functions stubbed and verify the `Space` title, map, persistent transient behavior, and cleanup after an LSP command or `<escape>`.

### LSP dispatch contract

With Eglot public entry points stubbed at the boundary, assert:

1. outgoing calls pass `base` and incoming calls pass `incoming`;
2. definition and `Ref+` use the public Xref commands;
3. declaration, type definition, and implementation call the corresponding public Eglot commands;
4. `Ref-` passes `textDocument/references` and JSON false for `includeDeclaration`;
5. every command checks the correct provider capability before dispatch.

Tests should assert externally meaningful command/method selection and request parameters, not implementation source text.

### Extend invariants

1. Build an active Extend selection with known bounds and active edge.
2. Simulate an unmanaged buffer and an unsupported capability; assert exact bounds, point, active edge, and submode remain unchanged.
3. Simulate a supported operation whose stub moves point in the same buffer; assert Extend was exited before the move rather than left active with point detached from its edge.
4. Confirm that opening and cancelling the Space layer alone does not alter Extend bounds or point.

### Real Eglot smoke test

Use a small temporary project and an available language server to exercise the actual UI, not only stubs:

1. start Eglot in a source buffer containing a declaration/definition, a type, references, an implementation where the language supports one, and a caller/callee pair;
2. open the Space layer and invoke each supported entry through its real `SPC` key sequence;
3. verify single-location jumps, Xref multi-result display, the `Ref+` versus `Ref-` declaration difference, and direction-specific call hierarchy;
4. use Xref navigation to return to the source location;
5. repeat one same-buffer jump while Extend is active and confirm Ri exits Extend cleanly before moving.

Capability-dependent actions unsupported by the chosen server should be checked separately for the expected preflight error rather than treated as successful smoke coverage.

### Regression suite

Run the complete existing Ri ERT suite after the focused test. The new bindings must preserve the existing Space `Editor` submenu and must not change any tap-and-hold layer registration.

## Documentation

Update `README.md` after implementation:

- document the eight Eglot/LSP actions under the existing `SPC` command-menu entry;
- document the eight Ki-compatible subkeys;
- state that an active Eglot server and the corresponding server capability are required;
- state that these commands use Xref/Eglot and do not require tree-sitter;
- mention that `Ref+` includes and `Ref-` excludes the declaration.

Do not present the menu as a local-only selection mode: unlike Ki's local secondary-selection model, this implementation displays the locations returned by the language server through native Emacs result surfaces.

## Files to change during implementation

- new `ri-lsp.el` — Eglot preflight and eight protocol-backed operations;
- `ri.el` — module loading, Space-layer bindings, and public commands;
- new `ri-lsp-test.el` — keymap, dispatch, error, and Extend-invariant coverage;
- `README.md` — user-facing keymap and Eglot requirements.

Tree-sitter and semantic-unit files should remain unchanged unless implementation reveals an existing generic highlight-refresh defect. Do not add LSP location logic to `semantic-regions.el` or `ri-extend.el`.

## Recommended implementation order

1. Add focused failing tests for the exact Ki keymap and command-to-Eglot mapping.
2. Add `ri-lsp.el` with server/capability preflight and the eight explicit operations.
3. Implement and test the isolated `Ref-` false-parameter adapter.
4. Add the eight actions to the existing Space layer with public wrappers and error-preserving cleanup.
5. Add the Extend-state tests and make dispatch exit Extend only after successful preflight.
6. Run the focused ERT test.
7. Perform the real Eglot smoke test through the actual Space layer.
8. Update `README.md` from the verified behavior.
9. Run the complete Ri ERT suite.

## Definition of done

The work is complete when:

1. `SPC` in NORM opens the existing `Space` legend containing all eight LSP labels at the exact Ki keys.
2. Every entry uses Eglot/LSP and its native Xref or hierarchy UI; none uses tree-sitter or textual inference.
3. `Out Calls` shows callees and `In Calls` shows callers without prompting for the opposite direction.
4. `Def`, `Decl`, `Type`, and `Impl` dispatch distinct LSP methods.
5. `Ref+` includes the declaration and `Ref-` sends LSP JSON false for `includeDeclaration`.
6. Missing Eglot management or provider capability produces a visible `user-error` without changing point or Extend selection state.
7. A supported navigation invoked during Extend exits Extend before any jump, so point is never left detached from an active selection edge.
8. The menu closes before Xref/hierarchy results take over, and Kitty key release does not erase an error message.
9. The focused tests, real Eglot smoke scenario, and complete existing ERT suite pass.
10. `README.md` documents the final keys, requirements, and Eglot-first behavior.
