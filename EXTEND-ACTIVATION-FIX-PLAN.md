# Extend Activation Fix Plan

## Problem

Pressing `f` in RI NORM no longer starts Extend. Emacs resolves the key to `ri-toggle-extend`, then rejects the target before its body runs:

```text
Wrong type argument: commandp, ri-toggle-extend
```

The selection engine itself still works when called as ordinary Lisp. With `sr-submode` set to `word` at the start of `alpha beta`, a direct call to `ri-toggle-extend` creates bounds `(1 . 6)`, sets the active edge to `end`, and leaves point at `5`, the last selected character.

## Root Cause

`ri-toggle-extend` in `ri-extend.el` has no `(interactive)` declaration. It is therefore a callable Lisp function but not an Emacs command:

- `(commandp #'ri-toggle-extend)` returns nil;
- `(call-interactively #'ri-toggle-extend)` raises the same `commandp` error as pressing `f`;
- `mini-modal-map` and `ri--normal-help-map` both expose `ri-toggle-extend` as an interactive action, so both dispatch paths require it to be a command.

The existing tests call Extend state helpers directly and verify selection behavior after state already exists. `ri-extend-test-registers-normal-navigation-bindings` checks several NORM bindings but does not check `f` or whether its target satisfies `commandp`. This allowed the invalid command registration to remain undetected.

This failure occurs before `ri--enter-extend`, `ri--selection-bounds`, highlighting, or navigation executes. It is not caused by selection-bound calculation, semantic-region parsing, the Pick transient maps, or KKP chord handling.

## Decision

Make `ri-toggle-extend` an interactive command by adding `(interactive)` immediately after its docstring.

Keep the existing state transition unchanged. The direct-call evidence shows that it already establishes the required initial Extend state:

- the selected bounds match the current semantic unit;
- the active edge is `end`;
- point is on the last selected character;
- no submode switch or navigation occurs during activation.

A wrapper command or a lambda in `mini-modal-map` would hide the malformed public command and leave the help-map path or future callers exposed. Declaring the function interactive fixes the source contract with no additional dispatch layer.

## Implementation

### 1. Restore the command contract

Update `ri-toggle-extend` in `ri-extend.el`:

- add `(interactive)` after the docstring and before the current `unless` form;
- retain the current behavior for initial activation, repeated `f`, SUBWORD no-op, NODE exit, highlighting, and mode-line refresh;
- do not change `ri--enter-extend`, `ri--select-all-in-extend`, or any selection-boundary logic.

The function must remain usable both through `call-interactively` and as a direct Lisp call.

### 2. Cover the real failure mode

Update `ri-extend-test.el` with a focused interactive activation test:

1. create a temporary buffer containing `alpha beta\n`;
2. place point at the first character and set `sr-submode` to `word`;
3. assert that `ri-toggle-extend` satisfies `commandp`;
4. invoke it with `call-interactively`, rather than calling its body directly;
5. assert that Extend is active;
6. assert exact bounds `(1 . 6)`;
7. assert active edge `end`;
8. assert point `5`, the last selected character.

These assertions protect both command dispatch and the repository invariant that point remains on the active selection edge.

Extend `ri-extend-test-registers-normal-navigation-bindings` to assert that the NORM `f` binding resolves to `ri-toggle-extend` and that the resolved binding is a command. This connects the interactive-command test to the user-facing key registration without duplicating the full `ri-enable` setup.

Do not replace the interactive test with only a direct `(ri-toggle-extend)` call. Direct Lisp invocation already succeeds and does not reproduce the regression.

### 3. Preserve existing Extend invariants

Run the existing submode-switch and navigation coverage unchanged. The fix must not alter:

- exact selection bounds when switching selection submodes during Extend;
- the active edge during submode switches or navigation;
- point placement on the first selected character for the `start` edge and the last selected character for the `end` edge;
- explicit cursor-swap behavior;
- repeated-`f` select-all behavior.

No compatibility alias, fallback binding, or special-case event handling is required.

## Verification

Set `KKP_DIR` to the installed directory containing `kkp.el`, then run the focused activation and invariant tests:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs -Q --batch \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L ri-tabs \
  -L ri-pick -L ri-mouse -L ri-pairs -L ri-surround -L kkp-chord \
  -l ri-extend-test.el \
  --eval '(ert-run-tests-batch-and-exit "ri-extend-test-\\(toggle-command-enters-extend-interactively\\|registers-normal-navigation-bindings\\|submode-switch-preserves-selection\\|paragraph-navigation-keeps-active-edge\\)")'
```

Then exercise the actual NORM key path in Emacs:

1. open a text buffer with RI enabled and select WORD mode;
2. place point inside a word and press `f`;
3. confirm the mode line shows `Extend`, the word is highlighted, and point is on its last character;
4. navigate in both directions and confirm point stays on the active edge after every movement;
5. switch through LINE, WORD, CHAR, PARAGRAPH, SUBWORD, and NODE where available and confirm the exact existing selection bounds do not change at the moment of each switch;
6. press `/` to swap the cursor, then navigate and confirm only the explicitly selected active edge moves;
7. repeat `f` in the submodes documented by `ri-toggle-extend` and confirm their existing select-all, no-op, or exit behavior remains unchanged.

A final batch probe should report `:commandp t` and no interactive error:

```elisp
(list :commandp (commandp #'ri-toggle-extend)
      :interactive-error
      (condition-case err
          (progn (call-interactively #'ri-toggle-extend) nil)
        (error (error-message-string err))))
```

## Documentation

`README.md` already documents `f` as “Start Extend; navigation then grows or shrinks the selection.” That contract is correct and requires no wording change.

## Non-Goals

- Do not redesign Extend selection state or boundary calculation.
- Do not change the `f` key assignment.
- Do not modify Pick transient-map behavior or KKP chord dispatch.
- Do not add a wrapper command, compatibility alias, or event replay.
- Do not fold unrelated `ri-tabs` or mouse-test failures into this focused repair.
