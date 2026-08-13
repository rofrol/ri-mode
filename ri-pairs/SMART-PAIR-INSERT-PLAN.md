# Smart pair insertion and newline plan

## Goal

Add Ki-style smart delimiter editing to RI's **INST** state, with the initial target being Odin code.

The required behavior is:

```odin
main :: proc () {
```

When the user types an opening delimiter:

```text
(
{
```

RI should insert the matching closing delimiter immediately after point:

```text
(|)
{|}
```

where `|` is point.

If point is immediately before an automatically paired closing delimiter and the user types that same closing delimiter, RI must move point across the existing delimiter instead of inserting a duplicate:

```text
(foo|)
     ↓ type )
(foo)|
```

When point is between an empty pair and the user presses Return, the pair must expand into an indented block. For example:

```odin
main :: proc () {|}
```

becomes conceptually:

```odin
main :: proc () {
    |
}
```

The same behavior is required for parentheses:

```text
(|)
```

becomes:

```text
(
    |
)
```

The indentation must come from the active major mode / Emacs indentation machinery rather than from a hard-coded number of spaces.

## Architectural direction

Do not implement delimiter parsing manually in `ri.el`.

RI's current modal architecture already gives a clean separation:

- **NORM**: `mini-modal-mode` is enabled and RI owns navigation/edit commands.
- **INST**: `mini-modal-mode` is disabled and normal Emacs insertion behavior is active.

Smart pairing therefore belongs to an insert-state editing component that cooperates with Emacs's existing syntax table, major-mode indentation, and pair-editing facilities.

The preferred implementation should build on Emacs's built-in electric-pair behavior where possible, adding only the RI-specific newline behavior that is missing or insufficient. This avoids maintaining an Odin-specific parser for delimiters and lets the feature work naturally in other programming modes as well.

Tree-sitter should be used as an **optional semantic/context layer** when the active major mode provides a tree-sitter parser. It must not be a hard dependency for basic pairing. The core behavior must continue to work in traditional major modes that expose only syntax tables and indentation functions.

## Implementation plan

1. **Create a dedicated RI insert-pair module.**

   Add a small library, preferably:

   ```text
   ri-pairs/ri-pairs.el
   ```

   Keep pairing/newline logic out of `ri.el`. `ri.el` should only load and enable the component.

2. **Use Emacs syntax information as the source of truth.**

   Opening and closing delimiters must be recognized through the active buffer's syntax table or the standard electric-pair machinery, not by assuming that every buffer uses the same delimiter rules.

   At minimum, Odin must support:

   ```text
   ( )
   { }
   ```

   The design should naturally permit standard pairs such as `[]` in modes whose syntax tables define them.

3. **Enable automatic closing-delimiter insertion in INST.**

   Typing `(` in normal code should produce:

   ```text
   (|)
   ```

   Typing `{` should produce:

   ```text
   {|}
   ```

   Prefer `electric-pair-mode` / `electric-pair-local-mode` rather than reimplementing self-insert commands.

4. **Preserve closing-delimiter overtyping.**

   When point is directly before the matching closing delimiter, typing that delimiter must advance point across it instead of creating another one.

   Example:

   ```text
   proc(|)
   ```

   followed by `)` must become:

   ```text
   proc()|
   ```

   Add regression coverage because this is one of the explicitly required user-facing behaviors.

5. **Add a smart Return command for an empty pair.**

   Introduce an insert-state command, for example:

   ```elisp
   ri-pairs-newline
   ```

   It should detect the narrow case where point is immediately between a matching opening and closing delimiter.

   In that case it should create two logical newlines:

   ```text
   {|}
   ```

   →

   ```text
   {
   |
   }
   ```

   and leave point on the inner line.

6. **Delegate indentation to the major mode.**

   After expanding the pair, call the normal indentation API (`indent-according-to-mode`, `newline-and-indent`, or an equivalent major-mode-aware operation) for both the inner line and the closing-delimiter line as appropriate.

   Do **not** insert four spaces directly. Odin indentation settings may change, and other major modes may use a different indentation policy.

   For Odin, the expected result is typically:

   ```odin
   main :: proc () {
       |
   }
   ```

   when the active Odin mode uses four-column indentation.

7. **Fall back to ordinary Return outside an empty pair.**

   The smart Return command must not globally change newline semantics.

   If point is not between a matching empty pair, it should invoke the normal newline/indent behavior expected in the current major mode.

   Examples that must remain ordinary edits:

   ```text
   foo(|bar)
   foo()|
   foo | bar
   ```

8. **Bind Return only for RI insert-state editing.**

   RI currently uses `<return>` for `save-buffer` in NORM through `mini-modal-map`.

   Preserve that behavior:

   - NORM + Return → `save-buffer`
   - INST + Return → smart newline / normal newline-and-indent

   The implementation must not replace the NORM binding.

   Prefer a small RI insert-state minor-mode/keymap, or another buffer-local mechanism whose keymap is active only while RI is in INST. Avoid a global `<return>` rebinding.

9. **Tie activation to RI rather than enabling a global editor policy accidentally.**

   `ri-enable` should arrange for the pair component to be enabled in the same text-editing buffers in which RI operates.

   It must skip minibuffers and `special-mode` buffers consistently with the existing RI setup.

   If built-in `electric-pair-mode` is used, prefer buffer-local activation where practical so RI does not unexpectedly alter unrelated buffers or users who disable RI.

10. **Add a syntax-context guard, using tree-sitter when available.**

    Before applying RI-specific smart transformations, determine the syntactic context at point. The goal is to avoid structural edits in contexts where the same delimiter characters are merely text or have a different grammatical meaning.

    When the current major mode has an active tree-sitter parser, query the syntax tree first. The context layer should be able to classify point broadly as:

    ```text
    code
    string
    comment
    argument-list / parameter-list
    type / generic-type syntax
    other language-specific syntax
    ```

    Do not hard-code Odin node names directly into the generic pair engine. Introduce a small adapter/predicate layer so language-specific tree-sitter node names can be mapped to generic RI context categories when needed.

11. **Define conservative behavior for strings and comments.**

    RI-specific pair expansion must not blindly transform delimiters inside strings or comments.

    For example, pressing Return in:

    ```text
    "{|}"
    // {|}
    ```

    must not invoke block-style smart expansion merely because point happens to be between `{` and `}` characters.

    Prefer the existing major-mode / electric-pair behavior in these contexts. RI should only add structural behavior when the context predicate says the delimiters represent code structure.

    If tree-sitter is unavailable, fall back to Emacs syntax information such as `syntax-ppss` rather than regex-based quote/comment detection.

12. **Make argument lists and type/generic contexts explicit policy points.**

    Do not assume that every matching pair should receive identical Return behavior. For example:

    ```text
    foo(|)
    SomeType[|]
    map[string]Thing
    ```

    may require different behavior from a statement/block body:

    ```text
    if condition {|}
    ```

    The first implementation may keep newline expansion enabled for ordinary `()` when that matches the current editor policy, but the decision must go through the context layer so it can later distinguish argument lists, parameter lists, generic/type argument lists, array/index syntax, and block bodies without rewriting the pair engine.

    In tree-sitter modes, use the containing node type to make this distinction. In non-tree-sitter modes, use a conservative fallback: if the structural context cannot be determined reliably, prefer normal newline/indent behavior rather than guessing.

13. **Keep tree-sitter optional and fail safely.**

    The context API should conceptually behave like:

    ```elisp
    (ri-pairs-context-at-point)
    ;; => 'code | 'string | 'comment | 'argument-list | 'type-context | ...
    ```

    Resolution order should be:

    1. tree-sitter context, when a parser is active and usable;
    2. `syntax-ppss` / syntax-table information for strings and comments;
    3. generic delimiter logic for ordinary code;
    4. conservative fallback when context is ambiguous.

    Absence of tree-sitter must never disable basic `()`, `{}`, closer overtyping, or major-mode indentation.

14. **Handle pair deletion consistently where supported by the underlying mechanism.**

    Verify the standard useful case:

    ```text
    (|)
    ```

    followed by Backspace should not leave surprising delimiter state. If built-in electric pairing already gives the desired behavior, retain it rather than adding RI-specific deletion code.

    This is secondary to the three required behaviors: insert pair, overtype closer, and smart Return.

15. **Add focused ERT tests for the pair component.**

    Tests should cover at least:

    - typing `(` inserts `)` and leaves point between them;
    - typing `{` inserts `}` and leaves point between them;
    - typing `)` before an existing paired `)` skips over it;
    - typing `}` before an existing paired `}` skips over it;
    - Return inside `{}` produces three lines with point on the inner line;
    - Return inside `()` produces three lines with point on the inner line;
    - Return outside an empty pair behaves like the normal newline command;
    - `{|}` inside a string does not trigger structural block expansion;
    - `{|}` inside a comment does not trigger structural block expansion;
    - tree-sitter context classification is used when an active parser is available;
    - the non-tree-sitter fallback still detects strings/comments via `syntax-ppss`;
    - argument-list and type/generic contexts follow the explicit context policy;
    - ambiguous structural contexts fail conservatively to normal newline/indent behavior;
    - pairing is active in INST;
    - the existing NORM `<return> -> save-buffer` binding remains unchanged.

16. **Add an Odin-specific integration test when Odin mode is available.**

    Use a buffer containing:

    ```odin
    main :: proc () {}
    ```

    Put point between `{}` and invoke the same command that INST Return uses.

    Assert that:

    - the closing `}` moves to its own line;
    - the inner line is indented according to Odin mode;
    - point remains at the indentation position on the inner line.

    If the Odin major mode is not available in the test environment, keep the core tests mode-independent and make the Odin integration test conditional rather than making the whole suite depend on an external package.

17. **Test interaction with modal transitions.**

    Verify the complete RI path:

    1. start in NORM;
    2. enter INST using `h` or `;`;
    3. type an opening delimiter;
    4. use smart Return;
    5. type the closing delimiter where applicable;
    6. press Escape to return to NORM.

    Pair handling must not interfere with `mini-modal-normal`, cursor positioning, semantic-region highlighting, or RI's undo behavior.

18. **Verify undo granularity.**

    Check that automatic pair insertion and smart pair expansion undo sensibly with RI's existing fine-grained undo/redo logic.

    In particular, smart Return should behave as one coherent editing operation rather than leaving the buffer in a half-expanded state after a single undo whenever possible.

19. **Run the relevant regression suites.**

    Run the new pair tests together with the existing RI tests, especially:

    ```text
    ri-extend-test.el
    ri-chord-test.el
    ```

    because INST/NORM transitions and undo handling already interact with those areas.

## Recommended module boundary

The intended structure is:

```text
ri-mode/
├── ri.el
├── ri-pairs/
│   ├── ri-pairs.el
│   └── ri-pairs-test.el
└── ...
```

`ri-pairs.el` should own:

- enabling/disabling insert-state pair support;
- matching-pair detection needed by smart Return;
- the INST Return command;
- generic syntax-context classification;
- optional tree-sitter context lookup with a non-tree-sitter fallback;
- policy predicates deciding whether a transformation is allowed in the current context;
- any narrowly required electric-pair configuration.

`ri.el` should only:

- add `ri-pairs/` to `load-path`;
- `(require 'ri-pairs)`;
- initialize the component from `ri-enable`;
- connect it to RI's NORM/INST lifecycle if a dedicated insert-state minor mode is required.

## Acceptance criteria

In an Odin buffer with RI enabled:

```text
main :: proc |
```

Typing `(` produces:

```text
main :: proc (|)
```

Typing `)` then produces:

```text
main :: proc ()|
```

Typing ` {` produces:

```text
main :: proc () {|}
```

Pressing Return produces:

```odin
main :: proc () {
    |
}
```

Additionally:

- indentation is supplied by Odin mode, not hard-coded by RI;
- NORM Return still saves the buffer;
- ordinary Return behavior remains intact when point is not between an empty pair;
- tree-sitter is used for richer context awareness when available, but is not a hard dependency;
- strings and comments do not receive accidental code-structure transformations;
- argument-list and type/generic contexts can be distinguished from block contexts through the context-policy layer;
- existing RI navigation, Extend state, cursor behavior, and undo/redo tests continue to pass.

## Likely files to change during implementation

- `ri.el`
- new `ri-pairs/ri-pairs.el`
- new `ri-pairs/ri-pairs-test.el`
- possibly an existing RI integration test file for the NORM/INST transition regression

No change should be required in `semantic-regions` or `ri-surround`: this feature concerns text insertion in INST, not semantic selection or explicit surround operations in NORM.
