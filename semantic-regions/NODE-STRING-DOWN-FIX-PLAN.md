# NODE string `down` fix plan

## Goal

Make NODE-mode `down` descend from an Emacs Lisp string node such as:

```elisp
"melpa"
```

into the string contents `melpa`, while preserving the existing Ki-style NODE navigation semantics for lists, symbols, JSON, and other tree-sitter-backed modes.

## Current behavior and root cause

`sr-nav-down` ultimately calls `sr--node-target` with movement `down`.

The current implementation resolves `down` using:

```elisp
(treesit-node-child current 0 t)
```

The final `t` means "named children only". That works for structures whose meaningful first child is a named tree-sitter node, but it is not sufficient for Emacs Lisp strings. The text inside a string can be represented by an anonymous child/token rather than a named child. As a result, `down` can return no target instead of selecting the contents between the quotes.

This must be fixed at the semantic-regions NODE traversal layer, not by adding a special key binding or cursor hack in `ri.el`.

## Implementation plan

1. **Capture the exact Emacs Lisp tree shape for strings.**
   Add a focused ERT diagnostic/test fixture using `emacs-lisp-mode`, the `elisp` tree-sitter parser, and a buffer containing at least `"melpa"`. Assert the outer node bounds and inspect all direct children with both named-only and all-child traversal. The test should encode the actual node ranges rather than relying on an assumed grammar shape.

2. **Define the intended NODE `down` invariant.**
   `down` should select the first meaningful child with a strictly smaller source range than the current node. "Meaningful" must include anonymous content tokens when they contain user-editable semantic text, but must not make punctuation delimiters such as `(`, `)`, `"`, commas, or brackets become normal `down` destinations.

3. **Introduce one helper for vertical child selection.**
   Replace the inline `treesit-node-child current 0 t` lambda with a dedicated helper, for example `sr--node-down-child`. It should first preserve the current named-child behavior. If no suitable named child exists, it should inspect all direct children and choose a non-delimiter child whose bounds are strictly inside the parent. Keep `sr--node-with-different-range` in the path so wrapper nodes with identical ranges continue to be skipped.

4. **Do not solve the string case by trimming quotes from arbitrary node bounds.**
   NODE regions should continue to correspond to real tree-sitter nodes whenever possible. Avoid creating synthetic `(start+1 . end-1)` regions based only on the first/last character; that would break escaped/raw/multiline strings and would make `up`, sibling navigation, and `sr--node-current` inconsistent.

5. **Add a regression test for the reported case.**
   Starting on the outer string node for `"melpa"`, call `sr-nav-down` and assert that `semantic-region-string` is exactly `melpa` (without quotes). Also assert that `sr--node-current` corresponds to the selected tree-sitter child and that `sr-nav-up` returns to `"melpa"`.

6. **Add surrounding Emacs Lisp string cases.**
   Cover at minimum:
   - `"melpa"`;
   - a string used as an argument, e.g. `(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))`;
   - a string containing spaces;
   - a string containing an escape sequence;
   - an empty string, where `down` should be a no-op unless the grammar exposes a legitimate zero/non-delimiter child.

7. **Protect existing NODE semantics with regression tests.**
   Re-run/retain the existing tests that establish Ki-style behavior for JSON and Elisp forms. In particular, verify that descending into `(setq mouse-wheel-tilt-scroll t)` still lands on `mouse-wheel-tilt-scroll` as currently expected, and that punctuation does not become the target of normal left/right/down navigation.

8. **Test the public RI path, not only the helper.**
   Add or extend a test through `ri-extend-nav-down` / the NODE-mode command path so the test reproduces what the user actually invokes. This catches state/highlight synchronization problems that a direct `sr--node-target` unit test would miss.

9. **Verify selection/highlight state after descent.**
   Confirm that after `down`, point, `sr--node-current`, the semantic region bounds, and RI's NODE highlight all refer to `melpa`, not to the opening quote or to the original string node.

10. **Run the complete ERT suite with an Elisp tree-sitter grammar available.**
    The fix is complete only when the new string tests pass together with the existing `semantic-regions`, `ri-extend`, and relevant RI navigation tests. A skipped tree-sitter test is not sufficient validation for this bug.

## Acceptance criteria

Given an Emacs Lisp buffer containing:

```elisp
"melpa"
```

and NODE mode selecting `"melpa"`:

- one `down` selects `melpa` without the quotes;
- `up` returns to the complete `"melpa"` node;
- `down` does not select either quote delimiter;
- existing list/form and JSON NODE navigation remains unchanged;
- the behavior is covered by ERT through both `semantic-regions` and RI's user-facing navigation path.

## Likely files to change

- `semantic-regions/semantic-regions.el`
- `semantic-regions/semantic-regions-test.el`
- possibly `ri-extend-test.el` for a user-facing regression test

No change should be necessary in the NODE key bindings in `ri.el` unless testing reveals an independent dispatch/state bug.

## Implementation note

During implementation the grammar itself showed that the original plan's
anonymous-child assumption does not hold for Emacs Lisp strings.  In
`tree-sitter-elisp`, `STRING` is wrapped in `token(...)` and the public
`string` rule is `string: ($) => STRING`.  Consequently `"melpa"` is an
atomic tree-sitter node with no child for `melpa`.

The implementation therefore uses a narrowly-scoped virtual NODE child only
for a real tree-sitter node of type `string`.  Its bounds are the interior of
the verified quote-delimited string token.  This is not a generic node-bound
trimming fallback: other node types continue to use real tree-sitter
children.  `up` from the virtual child restores the original real string
node, and empty strings remain unchanged.
