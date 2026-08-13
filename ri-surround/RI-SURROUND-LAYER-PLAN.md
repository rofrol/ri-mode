# Ki-Style Surround Layer Plan for ri-mode

## Goal

Add a **Surround** interface to `ri-mode` that follows Ki Editor's key
layout and interaction model as closely as possible.

The Surround interface should be entered with `,` in NORM mode and
should support:

-   Surround
-   Delete Surround
-   Change Surround
-   Select Inside
-   Select Around

The delimiter-selection layout should match Ki Editor.

## Key Design Decision

Do **not** implement `,` as another hold/momentary `kkp-chord` layer
like the existing Copy, Paste, Open, or similar layers.

Instead, `,` should open a normal prefix/menu.

This is necessary because Ki's enclosure layout itself uses `,` to
select square brackets:

``` text
m  →  ( )
,  →  [ ]
.  →  { }
/  →  < >

j  →  ' '
k  →  " "
l  →  ` `
```

With a hold-based `,` layer, the sequence `, ,` would be awkward or
impossible to reproduce cleanly.

Therefore:

``` text
,  → enter Surround menu
```

and subsequent keys select the operation and enclosure type.

## Main Surround Menu

The main menu should match Ki:

``` text
,  → Surround menu

d  → Select Inside
e  → Select Around
f  → Change Surround
r  → Delete Surround
s  → Surround
```

Examples:

``` text
, s m    → surround with ( )
, s ,    → surround with [ ]
, s .    → surround with { }
, r k    → delete surrounding " "
, d m    → select inside ( )
, e .    → select around { }
, f m .  → change ( ) to { }
```

## Enclosure Layout

All operations that require selecting an enclosure should use one shared
layout:

``` text
                 m  ( )
                 ,  [ ]
                 .  { }
                 /  < >

                 j  ' '
                 k  " "
                 l  ` `
```

For the normal Surround operation, also support:

``` text
;  → XML/HTML-style enclosure
```

The basic delimiter support should be implemented first. XML/HTML
support can be added after the core functionality is stable.

## Architecture

Create a new module:

``` text
ri-surround.el
```

Keep the actual surround algorithms there.

`ri.el` should contain only the integration with:

-   NORM mode
-   keymaps
-   help/legend
-   Extend selection
-   mode-line state

Suggested responsibility split:

``` text
ri.el
    keymaps
    prefix/menu integration
    NORM integration
    Extend integration
    help legend

ri-surround.el
    enclosure definitions
    pair lookup
    surround operation
    delete operation
    change operation
    selection bounds
```

## Enclosure Representation

Define the supported enclosure types in one place.

Conceptually:

``` elisp
'((paren   "(" ")")
  (bracket "[" "]")
  (brace   "{" "}")
  (angle   "<" ">")
  (single  "'" "'")
  (double  "\"" "\"")
  (backtick "`" "`"))
```

The exact representation can be chosen to fit the existing ri-mode
style.

Avoid duplicating delimiter definitions across individual commands.

## Shared Enclosure Keymap Generator

Do not manually create five nearly identical keymaps.

Create one helper such as:

``` elisp
(ri-surround-make-enclosure-map function &optional xml)
```

It should generate:

``` text
m → ()
, → []
. → {}
/ → <>
j → ''
k → ""
l → ``
```

This map can then be reused by:

-   Surround
-   Delete Surround
-   Select Inside
-   Select Around
-   Change Surround From
-   Change Surround To

This mirrors Ki's approach of generating enclosure keymaps from one
common definition.

## Main Keymap

Create a Surround prefix map, conceptually:

``` elisp
ri--surround-menu-map
```

with:

``` text
r → Delete Surround submenu
s → Surround submenu
f → Change Surround submenu
d → Select Inside submenu
e → Select Around submenu
```

Bind the prefix to `,` in NORM.

Also expose it in the NORM help/legend.

Do not add `,` to `ri--layer-specs` if that structure continues to
represent momentary tap-and-hold layers.

## Pair Detection

The central primitive should be something like:

``` elisp
(ri-surround--find-pair position open close)
```

returning:

``` elisp
(OPEN-POS . CLOSE-POS)
```

It should locate the matching enclosure surrounding the current point or
selection.

### Asymmetric delimiters

For:

``` text
()
[]
{}
<>
```

pair detection must understand nesting.

For example:

``` text
(a (b) c)
```

The implementation must not simply find the nearest `(` to the left and
`)` to the right.

It should maintain nesting depth while searching so that matching pairs
are selected correctly.

### Symmetric delimiters

For:

``` text
''
""
``
```

the opening and closing characters are identical, so they require
separate handling.

At minimum, the implementation should use Emacs syntax information where
possible, for example:

``` elisp
syntax-ppss
```

Escaped quotes must not be blindly interpreted as enclosure boundaries.

The implementation should initially favor predictable behavior over
trying to support every language-specific quoting rule.

## Surround Operation

Command flow:

``` text
, s <enclosure>
```

Examples:

``` text
, s m  → (selection)
, s ,  → [selection]
, s .  → {selection}
, s /  → <selection>
, s j  → 'selection'
, s k  → "selection"
, s l  → `selection`
```

The operation should use the current ri-mode selection bounds.

If Extend is active, surround the current Extend selection.

If Extend is not active, surround the current semantic unit according to
the existing ri-mode selection model.

After editing:

``` text
perform edit
→ leave Extend if active
→ refresh highlight
→ remain in NORM
```

Reuse the existing edit-finalization mechanism, preferably
`ri--finish-edit-command` or its equivalent, rather than introducing
another lifecycle.

## Delete Surround

Command flow:

``` text
, r <enclosure>
```

Example:

``` text
(foo)
  ^
```

then:

``` text
, r m
```

produces:

``` text
foo
```

Only the enclosure delimiters should be removed.

The enclosed text must remain unchanged.

The operation should locate the relevant surrounding pair using the
common pair-detection implementation.

## Change Surround

Change Surround is a two-stage operation.

Example:

``` text
(foo)
```

then:

``` text
, f m .
```

produces:

``` text
{foo}
```

Interaction:

``` text
, f
    ↓
choose existing enclosure
    ↓
choose replacement enclosure
```

Conceptually:

``` text
ri--change-surround-from-map
    ↓
ri--change-surround-to-map
```

The first choice determines which surrounding enclosure should be found.

The second choice determines the replacement delimiters.

Do not implement Change as Delete followed by a completely independent
Surround command because the pair positions are already known after the
first step.

Replace both delimiters as one logical editing operation so that Undo
restores the previous enclosure in one step.

## Select Inside

Command flow:

``` text
, d <enclosure>
```

For:

``` text
(foo)
```

Select Inside should select:

``` text
foo
```

but not the parentheses.

The result should become a normal ri-mode Extend selection rather than
an Emacs region managed independently from ri-mode.

Set the existing ri-mode selection state directly and then call the
existing highlight/update mechanisms.

Conceptually:

``` text
find pair
→ calculate inner bounds
→ update ri--selection
→ ri--update-highlight
→ force-mode-line-update
```

After the command, the user should be able to continue extending or
manipulating the selection using normal ri-mode commands.

## Select Around

Command flow:

``` text
, e <enclosure>
```

For:

``` text
(foo)
```

Select Around should select:

``` text
(foo)
```

including both delimiters.

As with Select Inside, the result should use the existing ri-mode Extend
selection machinery.

## Extend Integration

Do not introduce a second selection abstraction.

Reuse the current:

``` text
ri--selection
```

including its existing fields such as:

``` text
anchor
initial-end
active-edge
```

After Select Inside or Select Around:

``` elisp
(ri--update-highlight)
(force-mode-line-update)
```

should be enough to synchronize the visual selection and mode-line
state, with any additional existing ri-mode helper used where
appropriate.

Editing operations:

-   Surround
-   Delete Surround
-   Change Surround

should finish consistently with other editing commands:

``` text
edit
→ exit Extend
→ update highlight
→ NORM
```

Selection operations:

-   Select Inside
-   Select Around

should instead leave the user in Extend.

## Undo Semantics

Each surround mutation should be one logical undo operation.

For example:

``` text
(foo)
```

followed by:

``` text
, f m .
```

should produce:

``` text
{foo}
```

A single Undo should restore:

``` text
(foo)
```

The same principle applies to Surround and Delete Surround.

## Help / Keymap Legend

The NORM help should show:

``` text
,  Surround
```

Entering the Surround menu should expose:

``` text
d  Select Inside
e  Select Around
f  Change Surround
r  Delete Surround
s  Surround
```

Enclosure submenus should display the Ki layout spatially where the
current help infrastructure permits it:

``` text
m ()
, []
. {}
/ <>

j ''
k ""
l ``
```

The goal is for users familiar with Ki to transfer the key positions
directly to ri-mode.

## Tests

Add ERT tests for the core behavior.

### Surround

Test all basic enclosure types:

``` text
()
[]
{}
<>
''
""
``
```

Test:

-   normal selection
-   Extend selection
-   empty selection if supported
-   multiline selection

### Delete Surround

Test:

``` text
(foo)     → foo
[foo]     → foo
{foo}     → foo
"foo"     → foo
```

### Nested pairs

Test cases such as:

``` text
(a (b) c)
```

with the cursor in different positions.

Verify that the correct matching pair is selected.

Also test mixed nesting:

``` text
foo({bar[baz]})
```

### Change Surround

Test:

``` text
(foo) → {foo}
[foo] → (foo)
"foo" → 'foo'
```

Verify that each change is one undo step.

### Select Inside

For:

``` text
(foo)
```

verify that the resulting ri-mode selection bounds correspond exactly
to:

``` text
foo
```

### Select Around

For:

``` text
(foo)
```

verify that the resulting selection includes:

``` text
(foo)
```

### Quotes

Test at least:

``` text
"foo"
"foo \"bar\" baz"
'foo'
`foo`
```

Ensure escaped quotes do not cause obvious incorrect pair detection.

### State transitions

Verify:

``` text
Surround       → NORM
Delete         → NORM
Change         → NORM
Select Inside  → Extend
Select Around  → Extend
```

Also verify that highlight and mode-line state remain synchronized.

## Implementation Order

1.  Add `ri-surround.el`.
2.  Define the enclosure types and shared key layout.
3.  Implement `ri-surround--find-pair`.
4.  Add tests for nested pair detection.
5.  Implement Surround.
6.  Implement Delete Surround.
7.  Implement Select Inside.
8.  Implement Select Around.
9.  Integrate selections with `ri--selection` and Extend.
10. Implement the two-stage Change Surround operation.
11. Add the shared enclosure keymap generator.
12. Add the main Surround prefix map.
13. Bind `,` in NORM.
14. Add Surround to the help/keymap legend.
15. Add undo/state-transition tests.
16. Add quote-specific edge-case tests.
17. Add XML/HTML `;` support after the basic implementation is stable.

## Target Interaction

The finished feature should make these sequences work naturally:

``` text
, s m     → surround with ()
, s ,     → surround with []
, s .     → surround with {}
, s /     → surround with <>
, s j     → surround with ''
, s k     → surround with ""
, s l     → surround with ``

, r m     → delete surrounding ()
, r k     → delete surrounding ""

, d m     → select inside ()
, e .     → select around {}

, f m .   → change () to {}
, f , m   → change [] to ()
, f k j   → change "" to ''
```

The central design requirement is that the **key positions and
interaction model remain recognizable to a Ki Editor user**, while the
implementation itself uses ri-mode's existing NORM, Extend, selection,
highlighting, and editing infrastructure.
