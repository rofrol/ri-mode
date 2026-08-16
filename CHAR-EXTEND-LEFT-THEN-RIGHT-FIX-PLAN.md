# Plan: Fix CHAR Extend Left Followed By Right Navigation

## Problem

When entering Extend in `CHAR` mode and navigating `Left`, subsequent `Right` navigation cannot expand the selection to the right after shrinking back to the initial character.

### Reproduction Steps

1. In a buffer containing `"abcdef"`, position point on `"c"` (buffer position 3, character range `(3 . 4)`).
2. Set submode to `CHAR` (`sr-submode = 'char'`) and enter Extend (`ri-toggle-extend` or `ri--enter-extend`).
3. Press `Left` (`ri-extend-nav-left`): the selection extends leftward to `"bc"` (`(2 . 4)`), `point` is on `"b"` (position 2), and `active-edge` is `'start'`.
4. Press `Right` (`ri-extend-nav-right`): the selection shrinks rightward back to `"c"` (`(3 . 4)`), `point` is on `"c"` (position 3), and `active-edge` remains `'start'` with `anchor` at position 4.
5. Press `Right` again (`ri-extend-nav-right`): point remains at position 3 and the selection remains `(3 . 4)`. Further `Right` navigation commands are completely ignored.

In contrast, if the user starts by navigating `Right` from the initial selection, they can extend right to `"cde"`, shrink left back to `"c"`, and then continue navigating `Left` to extend leftward to `"abc"`.

## Root Cause

The issue is an asymmetry in how `ri--extend-horizontal-move` handles boundary direction transitions for single-character `CHAR` selections.

1. **Initial Entry**: When `ri--enter-extend` initializes a selection on character `P` (`bounds = (P . P+1)`), it sets `anchor` to $P$, `initial-end` to $P+1$, `active-edge` to `'end'`, and `point` to $P$.
2. **Initial Left Move**: `ri--extend-horizontal-move` contains a special guard:
   ```elisp
   (if (and (eq sr-submode 'char)
            (ri--selection-state-initial-end state)
            (= base-pos anchor-pos)
            (= (marker-position (ri--selection-state-initial-end state))
               (1+ anchor-pos)))
       (when target
         (if (eq direction 'left)
             (progn
               (set-marker anchor
                           (marker-position
                            (ri--selection-state-initial-end state)))
               (setf (ri--selection-state-active-edge state) 'start)
               (goto-char (ri--point-at-unit-edge target 'start)))
           (goto-char (ri--point-at-unit-edge target 'end))))
     ...)
   ```
   On the first `Left` move, `base-pos` ($P$) equals `anchor-pos` ($P$), so the condition passes. The anchor is moved to $P+1$, `active-edge` becomes `'start'`, and point moves to $P-1$.
3. **Shrinking Back Right**: When navigating `Right` back to $P$, point moves to $P$, `anchor` remains $P+1$, and `active-edge` remains `'start'`. The selection is now the single character $P$ (`(P . P+1)`).
4. **Subsequent Right Move**:
   - `base-pos` is $P$, and `anchor-pos` is $P+1$.
   - The special guard above fails because `(= base-pos anchor-pos)` evaluates $(P = P+1)$, which is `nil`.
   - Execution falls through to the standard horizontal move logic:
     ```elisp
     (when (and target
                (or (not shrinking-p)
                    (not anchor-pos)
                    (if (eq edge 'end)
                        (> (cdr target) anchor-pos)
                      (< (car target) anchor-pos))
                    ...))
     ```
   - For `edge = 'start'` and `direction = 'right'`, `shrinking-p` is `t`.
   - The target character is `"d"` with bounds `(P+1 . P+2)`.
   - The boundary test evaluates `(< (car target) anchor-pos)` $\to$ `(< (P+1) (P+1))`, which is `nil`.
   - As a result, the command is discarded as an invalid shrink and does nothing.
5. **Coupling to `initial-end`**: Furthermore, relying on `ri--selection-state-initial-end` fails if the selection was established or modified through a submode switch or cursor swap (which clears `initial-end`).

## Decision

Make single-character `CHAR` selection direction transitions fully symmetric in `ri--extend-horizontal-move`:

1. **Detect 1-character CHAR selection expanding left**:
   When `sr-submode` is `'char'`, `edge` is `'end'`, `(= base-pos anchor-pos)`, and `direction` is `'left'`:
   - Set `anchor` to `(1+ anchor-pos)`.
   - Set `active-edge` to `'start'`.
   - Move point to `(ri--point-at-unit-edge target 'start)`.

2. **Detect 1-character CHAR selection expanding right**:
   When `sr-submode` is `'char'`, `edge` is `'start'`, `(= (1+ base-pos) anchor-pos)`, and `direction` is `'right'`:
   - Set `anchor` to `base-pos` (or `(1- anchor-pos)`).
   - Set `active-edge` to `'end'`.
   - Move point to `(ri--point-at-unit-edge target 'end)`.

3. **Standard navigation fallback**:
   All multi-character expansions and contractions continue to flow through the existing general shrink/expand logic.

4. **Invariants Preserved**:
   - Repository invariant: point remains on the active selection edge (first character when active edge is `start`, last character when active edge is `end`).
   - Reversible navigation: moving back and forth across the initial selection unit continuously expands and shrinks smoothly without getting trapped.

## Implementation

### 1. Update `ri--extend-horizontal-move` in `ri-extend.el`

Replace the asymmetric initial-entry check in `ri--extend-horizontal-move` with a symmetric `cond` structure:

```elisp
(defun ri--extend-horizontal-move (direction)
  "Move the active extend edge one content unit in DIRECTION.
When the active edge is `end', point stays on the last character of
the selected unit; moving back over prev expanded units shrinks
the selection.  In WORD, WORD*, and SUBWORD modes, crossing the
initial anchor keeps the cursor direction instead of swapping it."
  (when-let* ((state ri--selection))
    (let* ((edge (or (ri--selection-state-active-edge state) 'end))
           (base-pos (point))
           (target (pcase direction
                     ('left (ri--prev-unit-bounds base-pos sr-submode))
                     ('right (ri--next-unit-bounds base-pos sr-submode))))
           (anchor (ri--selection-state-anchor state))
           (anchor-pos (when anchor (marker-position anchor)))
           (shrinking-p (or (and (eq edge 'end)
                                 (eq direction 'left))
                            (and (eq edge 'start)
                                 (eq direction 'right)))))
      (cond
       ;; Single-character CHAR selection expanding left:
       ((and (eq sr-submode 'char)
             anchor-pos
             (eq edge 'end)
             (= base-pos anchor-pos)
             (eq direction 'left))
        (when target
          (set-marker anchor (1+ anchor-pos))
          (setf (ri--selection-state-active-edge state) 'start)
          (goto-char (ri--point-at-unit-edge target 'start))))
       ;; Single-character CHAR selection expanding right:
       ((and (eq sr-submode 'char)
             anchor-pos
             (eq edge 'start)
             (= (1+ base-pos) anchor-pos)
             (eq direction 'right))
        (when target
          (set-marker anchor base-pos)
          (setf (ri--selection-state-active-edge state) 'end)
          (goto-char (ri--point-at-unit-edge target 'end))))
       ;; Standard horizontal navigation:
       (t
        (when (and target
                   (or (not shrinking-p)
                       (not anchor-pos)
                       (if (eq edge 'end)
                           (> (cdr target) anchor-pos)
                         (< (car target) anchor-pos))
                       (and (eq edge 'end)
                            (eq direction 'left)
                            (ri--selection-state-initial-end state)
                            (sr--wordish-submode-p))))
          (setf (ri--selection-state-active-edge state) edge)
          (goto-char (ri--point-at-unit-edge target edge))))))))
```

### 2. Documentation and Comments

Ensure `ri--enter-extend` and `ri--extend-horizontal-move` comments and docstrings accurately reflect that CHAR extend selections can seamlessly transition expansion direction from any 1-character selection state.

## Regression Coverage

Add comprehensive test cases to `ri-extend-test.el`:

1. **`ri-extend-test-char-bidirectional-expansion`**:
   - In buffer `"abcdef"`, position on `"c"` (position 3).
   - Enter Extend in `CHAR` mode.
   - Navigate `Left`, `Left`: selection becomes `"abc"` (`(1 . 4)`), `point = 1`, `edge = 'start'`.
   - Navigate `Right`, `Right`: selection shrinks back to `"c"` (`(3 . 4)`), `point = 3`, `edge = 'start'`.
   - Navigate `Right`, `Right`: selection extends rightward to `"cde"` (`(3 . 6)`), `point = 5`, `edge = 'end'`.
   - Navigate `Left`, `Left`: selection shrinks back to `"c"` (`(3 . 4)`), `point = 3`, `edge = 'end'`.
   - Navigate `Left`: selection extends leftward to `"bc"` (`(2 . 4)`), `point = 2`, `edge = 'start'`.

2. **`ri-extend-test-char-undo-and-cursor-swap`**:
   - In buffer `"abcdef"`, position on `"c"`, enter Extend in `CHAR` mode.
   - Navigate `Left` to `"bc"` (`(2 . 4)`), then `ri-smart-undo` back to `"c"` (`(3 . 4)`).
   - Navigate `Right` to `"cd"` (`(3 . 5)`).
   - Call `ri-swap-cursor`: bounds remain `(3 . 5)`, `point` moves to 3, `edge` becomes `'start'`.
   - Navigate `Left`: selection extends leftward to `"bcd"` (`(2 . 5)`), `point = 2`, `edge = 'start'`.

3. **`ri-extend-test-char-left-from-initial-selection`** (existing test):
   - Verify that the existing single Left-then-Right regression test remains passing.

## Verification

### Automated Batch Tests

Run the focused CHAR Extend regression tests:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs -Q --batch \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L ri-tabs \
  -L ri-pick -L ri-mouse -L ri-pairs -L ri-surround -L kkp-chord \
  -l ri-extend-test.el \
  --eval '(ert-run-tests-batch-and-exit "ri-extend-test-char-")'
```

Run the complete Extend test suite:

```sh
emacs -Q --batch \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L ri-tabs \
  -L ri-pick -L ri-mouse -L ri-pairs -L ri-surround -L kkp-chord \
  -l ri-extend-test.el \
  -f ert-run-tests-batch-and-exit
```

### Manual TTY Verification

1. Launch Emacs in terminal mode: `emacs -nw -Q -L <paths> -l ri.el`.
2. In a scratch buffer, type `"abcdef"`.
3. Switch to `CHAR` mode and place cursor on `"c"`.
4. Press `v` (or Extend key) to enter Extend mode.
5. Press `h` (Left) twice to select `"abc"`.
6. Press `l` (Right) twice to shrink to `"c"`.
7. Press `l` (Right) twice more: verify that selection expands right to `"cde"` and point rests on `"e"`.
8. Press `h` (Left) twice to shrink back to `"c"`.
9. Press `h` (Left) once more: verify that selection expands left to `"bc"` and point rests on `"b"`.

## Non-Goals

- Do not alter WORD, WORD*, WORD+, SUBWORD, or NODE anchor-crossing behaviors.
- Do not introduce additional state fields to `ri--selection-state`.
- Do not change cursor swap (`ri-swap-cursor`) or submode switching preservation mechanics.

## Completion Criteria

1. Navigating `Left` then `Right` in `CHAR` Extend mode shrinks back to the initial character and then smoothly continues extending rightward.
2. Navigating `Right` then `Left` in `CHAR` Extend mode shrinks back to the initial character and then smoothly continues extending leftward.
3. In all `CHAR` Extend operations, point remains strictly on the active selection edge: position `start` when `active-edge` is `'start'`, and position `(1- end)` when `active-edge` is `'end'`.
4. Undo (`ri-smart-undo`) and cursor swap (`ri-swap-cursor`) remain fully operational across bidirectional CHAR expansions.
5. All 53+ ERT tests pass cleanly with zero regressions.
