;;; ri-extend.el --- Extend selection for ri -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow

;;; Commentary:

;; Selection state and highlighting for `ri-mode`.

;;; Code:

(require 'cl-lib)
(require 'semantic-regions)

(cl-defstruct (ri--selection-state
               (:constructor ri--selection-state-create))
  "Complete state of one active extended selection."
  anchor
  initial-end
  active-edge
  undo-stack)

(defvar-local ri--selection nil
  "The active `ri--selection-state', or nil outside extend mode.")

(defun ri--selection-active-p ()
  "Return non-nil when the current buffer has an extended selection."
  (and (ri--selection-state-p ri--selection) t))

(cl-defstruct (ri--extend-entry
               (:constructor ri--extend-entry-create))
  "One selection-extension state for undo."
  point
  anchor
  active-edge)

(defun ri--point-at-unit-edge (bounds edge)
  "Return cursor position for EDGE, keeping the end cursor inside BOUNDS."
  (if (and (eq edge 'end) (> (cdr bounds) (car bounds)))
      (1- (cdr bounds))
    (car bounds)))

(defun ri--unit-bounds-at-edge (pos edge submode)
  (sr--unit-bounds-at (if (eq edge 'end) (max (point-min) (1- pos)) pos) submode))

(defun ri--whitespace-bounds-p (bounds)
  (save-excursion (goto-char (car bounds))
    (skip-chars-forward " \t\n" (cdr bounds)) (= (point) (cdr bounds))))

(defun ri--separator-unit-p (bounds submode)
  (when bounds
    (pcase submode
      ('char nil) ('line-star nil) ('line (= (car bounds) (cdr bounds)))
      ('word (or (ri--whitespace-bounds-p bounds)
                 (and (= (1+ (car bounds)) (cdr bounds))
                      (not (string-match-p sr-word-chars (string (char-after (car bounds))))))))
      ('word-plus (ri--whitespace-bounds-p bounds))
      (_ (ri--whitespace-bounds-p bounds)))))

(defun ri--next-unit-bounds (pos submode)
  (when-let* ((cur (sr--unit-bounds-at pos submode)))
    (let ((b (unless (>= (cdr cur) (point-max)) (sr--unit-bounds-at (cdr cur) submode))))
      (while (and b (ri--separator-unit-p b submode) (< (cdr b) (point-max)))
        (setq b (sr--unit-bounds-at (cdr b) submode)))
      (when (and b (ri--separator-unit-p b submode) (>= (cdr b) (point-max))) (setq b nil)) b)))

(defun ri--prev-unit-bounds (pos submode)
  (when-let* ((cur (sr--unit-bounds-at pos submode)))
    (let ((cur-start (car cur)) (probe (1- (car cur))) b)
      (while (and (>= probe (point-min))
                  (or (null (setq b (sr--unit-bounds-at probe submode))) (>= (car b) cur-start)))
        (setq probe (1- (if b (min probe (car b)) probe))))
      (while (and b (ri--separator-unit-p b submode) (> (car b) (point-min)))
        (setq b (sr--unit-bounds-at (1- (car b)) submode)))
      (when (and b (ri--separator-unit-p b submode) (<= (car b) (point-min))) (setq b nil)) b)))

(defun ri--extend-point-boundary ()
  "Return the exact selection boundary represented by point."
  (if (eq (ri--selection-state-active-edge ri--selection) 'end)
      (min (point-max) (1+ (point)))
    (point)))

(defmacro ri--without-selection-context (&rest body)
  "Evaluate BODY while treating navigation as single-unit movement.
This prevents movement helpers from changing the active selection."
  (declare (indent 0) (debug t))
  `(let ((ri--selection nil))
     ,@body))

(defun ri--selection-bounds ()
  "Return (start . end) of the current selection.
In extend mode, horizontal unit modes keep selection boundaries exact;
WORD, WORD*, and SUBWORD keep the initial unit in the range while the
current unit crosses it, without changing cursor direction.
For line modes, only the active edge snaps to a line boundary; the
inactive anchor remains at the exact boundary already established.
In normal mode: current unit bounds."
  (if-let* ((state ri--selection)
            (anchor (ri--selection-state-anchor state)))
      (let* ((anchor-pos (marker-position anchor))
             (point-pos (point))
             (point-boundary (ri--extend-point-boundary))
             (raw-start (min anchor-pos point-pos))
             (raw-end (max anchor-pos point-pos))
             (active-edge
              (or (ri--selection-state-active-edge state)
                  (if (< anchor-pos point-pos) 'end 'start))))
        (cond
         ((and (= raw-start (point-min))
               (= point-boundary (point-max)))
          (cons raw-start point-boundary))
         ((and (sr--wordish-submode-p)
               (eq active-edge 'end)
               (ri--selection-state-initial-end state))
          (let ((current-bounds (sr--get-current-unit-bounds))
                (initial-end
                 (marker-position
                  (ri--selection-state-initial-end state))))
            (if current-bounds
                (cons (min anchor-pos (car current-bounds))
                      (max initial-end (cdr current-bounds)))
              (cons (min anchor-pos point-boundary)
                    (max initial-end point-boundary)))))
         ((sr--horizontal-submode-p)
          (cons (min anchor-pos point-boundary)
                (max anchor-pos point-boundary)))
         ((eq sr-submode 'line-star)
          (let ((start (if (eq active-edge 'start)
                           (save-excursion
                             (goto-char raw-start)
                             (line-beginning-position))
                         raw-start))
                (end (if (eq active-edge 'end)
                         (save-excursion
                           (goto-char raw-end)
                           (line-end-position))
                       raw-end)))
            (cons start end)))
         ((eq sr-submode 'line)
          (save-excursion
            (let ((start raw-start)
                  (end raw-end))
              (when (eq active-edge 'start)
                (goto-char raw-start)
                (setq start (line-beginning-position))
                (goto-char start)
                (skip-chars-forward " \t" (line-end-position))
                (setq start (point)))
              (when (eq active-edge 'end)
                (goto-char raw-end)
                (goto-char (line-end-position))
                (skip-chars-backward " \t" (line-beginning-position))
                (setq end (point)))
              (cons start end))))
         (t
          (cons raw-start raw-end))))
    (sr--get-current-unit-bounds)))

(defun ri--exit-extend ()
  "Exit selection-extend mode and release its complete state."
  (when-let* ((state ri--selection))
    (dolist (marker (list (ri--selection-state-anchor state)
                          (ri--selection-state-initial-end state)))
      (when (markerp marker)
        (set-marker marker nil))))
  (setq ri--selection nil))

(defun ri--enter-extend ()
  "Enter selection-extend mode around the current unit.
Return non-nil after establishing a complete selection state.  If the
current submode has no unit at point, leave extension mode inactive."
  (ri--exit-extend)
  (when-let* ((bounds (sr--get-current-unit-bounds)))
    (setq ri--selection
          (ri--selection-state-create
           :anchor (copy-marker (car bounds))
           :initial-end (copy-marker (cdr bounds))
           :active-edge 'end
           :undo-stack nil))
    (goto-char (ri--point-at-unit-edge bounds 'end))
    t))

(defun ri--snap-to-unit-start (&optional force-start)
  "Snap point to the current unit's active selection edge.
When FORCE-START is non-nil, keep point at the unit start even when
the active extend edge is `end'."
  (unless (eq sr-submode 'char)
    (when-let* ((bounds (sr--get-current-unit-bounds)))
      (goto-char
       (if (and (not force-start)
                (ri--selection-active-p)
                (eq (ri--selection-state-active-edge ri--selection) 'end))
           (ri--point-at-unit-edge bounds 'end)
         (car bounds))))))

(defun ri--update-highlight ()
  "Update semantic-regions overlay for the active extended selection."
  (if (ri--selection-active-p)
      (when-let* ((bounds (ri--selection-bounds)))
        (unless sr--highlight-overlay
          (setq sr--highlight-overlay (make-overlay (point) (point)))
          (overlay-put sr--highlight-overlay 'face 'sr-highlight-face)
          (overlay-put sr--highlight-overlay 'priority 100))
        (move-overlay sr--highlight-overlay (car bounds) (cdr bounds)))
    (sr--update-highlight)))

(defun ri--adjust-anchor-for-new-submode (new-submode)
  "Adjust extend boundaries after changing to NEW-SUBMODE.
The active edge is resnapped to the corresponding boundary in
NEW-SUBMODE.  The inactive boundary (the anchor) stays at the exact
selection boundary the user already established."
  (when-let* ((state ri--selection)
              (anchor (ri--selection-state-anchor state)))
    (let* ((old-bounds (ri--selection-bounds))
           (anchor-pos (marker-position anchor))
           (sel-start (car old-bounds))
           (sel-end (cdr old-bounds))
           (active-edge
            (or (ri--selection-state-active-edge state)
                (if (< anchor-pos (point)) 'end 'start))))
      (setf (ri--selection-state-active-edge state) active-edge)
      (pcase active-edge
        ('end
         (set-marker anchor sel-start)
         (when-let* ((point-bounds
                      (sr--unit-bounds-at-edge sel-end 'end new-submode)))
           (goto-char (ri--point-at-unit-edge point-bounds 'end))))
        ('start
         (set-marker anchor sel-end)
         (when-let* ((point-bounds
                      (sr--unit-bounds-at-edge sel-start 'start new-submode)))
           (goto-char (ri--point-at-unit-edge point-bounds 'start))))))))

(defun ri--extend-record ()
  "Push point, anchor, and active edge onto the selection undo stack.
Do nothing outside extend mode."
  (when-let* ((state ri--selection))
    (push (ri--extend-entry-create
           :point (point)
           :anchor (when-let* ((anchor (ri--selection-state-anchor state)))
                     (marker-position anchor))
           :active-edge (ri--selection-state-active-edge state))
          (ri--selection-state-undo-stack state))))

(defun ri--extend-undo ()
  "Contract the selection by one navigation step.
Restore the latest record from the active state's undo stack.  When
the stack is empty, exit extend mode gracefully."
  (interactive)
  (if (and ri--selection
           (ri--selection-state-undo-stack ri--selection))
      (let* ((state ri--selection)
             (record (pop (ri--selection-state-undo-stack state)))
             (point (ri--extend-entry-point record))
             (anchor (ri--extend-entry-anchor record))
             (active-edge (ri--extend-entry-active-edge record)))
        (goto-char point)
        (when (and (ri--selection-state-anchor state) anchor)
          (set-marker (ri--selection-state-anchor state) anchor))
        (setf (ri--selection-state-active-edge state) active-edge)
        (ri--update-highlight))
    (ri--exit-extend)
    (ri--update-highlight)))

(defun ri--undo-at-exhausted-redo-p ()
  "Return non-nil when `undo-only' reached an exhausted redo branch."
  (and (eq last-command 'undo)
       (not undo-in-region)
       (consp pending-undo-list)
       (eq (gethash pending-undo-list undo-equiv-table) t)
       (let ((undo-list buffer-undo-list))
         (while (and (consp undo-list)
                     (null (car undo-list)))
           (setq undo-list (cdr undo-list)))
         (gethash undo-list undo-equiv-table))))

(defun ri-smart-undo ()
  "Dispatch undo based on current mode context.
In extend mode: contract the selection by one unit (`ri--extend-undo').
Otherwise: run `undo-only', stopping at an exhausted redo branch."
  (interactive)
  (if (ri--selection-active-p)
      (ri--extend-undo)
    ;; `undo-only' skips list-valued redo equivalents, but an exhausted
    ;; branch maps to t and would otherwise replay the discarded edit.
    (when (ri--undo-at-exhausted-redo-p)
      (setq pending-undo-list t))
    (undo-only)))

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
        (goto-char (ri--point-at-unit-edge target edge))))))

(defun ri-flip-selection ()
  "Flip point to the opposite end of the current selection.
In extend mode: swap point and anchor marker while preserving the full
selection, including when a WORD edge has crossed its initial anchor.
In normal mode: jump to the opposite end of the current unit."
  (interactive)
  (if-let* ((state ri--selection)
            (anchor (ri--selection-state-anchor state)))
      (let* ((old-edge
              (or (ri--selection-state-active-edge state)
                  (if (< (marker-position anchor) (point))
                      'end
                    'start)))
             (bounds (ri--selection-bounds)))
        (when bounds
          (when-let* ((initial-end
                       (ri--selection-state-initial-end state)))
            (set-marker initial-end nil))
          (setf (ri--selection-state-initial-end state) nil)
          (if (eq old-edge 'end)
              (progn
                (goto-char (car bounds))
                (set-marker anchor (cdr bounds))
                (setf (ri--selection-state-active-edge state) 'start))
            (goto-char (if (> (cdr bounds) (car bounds))
                           (1- (cdr bounds))
                         (cdr bounds)))
            (set-marker anchor (car bounds))
            (setf (ri--selection-state-active-edge state) 'end))))
    (when-let* ((bounds (sr--get-current-unit-bounds)))
      (if (= (point) (car bounds))
          (goto-char (if (> (cdr bounds) (car bounds))
                         (1- (cdr bounds))
                       (cdr bounds)))
        (goto-char (car bounds))))))

(defun ri--select-all-in-extend ()
  "Select the whole buffer or current line according to `sr-submode`."
  (when-let* ((state ri--selection))
    (let ((active-edge 'end)
          (anchor (ri--selection-state-anchor state)))
      (pcase sr-submode
        ((or 'word 'word-plus 'word-star 'line 'line-star)
         (unless anchor
           (setq anchor (copy-marker (point-min)))
           (setf (ri--selection-state-anchor state) anchor))
         (set-marker anchor (point-min))
         (goto-char (point-max)))
        ('char
         (let ((start (line-beginning-position))
               (end (line-end-position)))
           (unless anchor
             (setq anchor (copy-marker start))
             (setf (ri--selection-state-anchor state) anchor))
           (set-marker anchor start)
           (if (> end start)
               (goto-char (1- end))
             (setq active-edge 'start)
             (goto-char start))))
        (_
         (setq active-edge nil)))
      (when-let* ((initial-end (ri--selection-state-initial-end state)))
        (set-marker initial-end nil))
      (setf (ri--selection-state-initial-end state) nil
            (ri--selection-state-active-edge state) active-edge
            (ri--selection-state-undo-stack state) nil))))

(defun ri-toggle-extend ()
  "Toggle selection-extend mode, or select all on repeated `f`.
When entering: select the current unit and put point on its last character.
In WORD, WORD*, LINE, and LINE* modes, repeated `f` selects the buffer;
in CHAR mode, it selects the current line.  In SUBWORD mode, repeated
`f` is a no-op."
  (interactive)
  (unless (and (ri--selection-active-p) (eq sr-submode 'subword))
    (if (ri--selection-active-p)
        (if (ri--select-all-submode-p)
            (ri--select-all-in-extend)
          (ri--exit-extend))
      (ri--enter-extend))
    (ri--update-highlight)
    (force-mode-line-update)))


(defun ri-extend-nav-left ()
  (interactive) (ri--extend-record)
  (if (and (ri--selection-active-p) (sr--horizontal-submode-p))
      (ri--extend-horizontal-move 'left) (sr-nav-left))
  (ri--update-highlight))
(defun ri-extend-nav-right ()
  (interactive) (ri--extend-record)
  (if (and (ri--selection-active-p) (sr--horizontal-submode-p))
      (ri--extend-horizontal-move 'right) (sr-nav-right))
  (ri--update-highlight))
(defun ri-extend-nav-up () (interactive) (ri--extend-record) (sr-nav-up) (ri--update-highlight))
(defun ri-extend-nav-down () (interactive) (ri--extend-record) (sr-nav-down) (ri--update-highlight))
(defun ri-extend-nav-prev () (interactive) (ri--extend-record) (sr-nav-prev) (ri--update-highlight))
(defun ri-extend-nav-next () (interactive) (ri--extend-record) (sr-nav-next) (ri--update-highlight))
(defun ri-extend-nav-first () (interactive) (ri--extend-record) (sr-nav-first) (ri--update-highlight))
(defun ri-extend-nav-last () (interactive) (ri--extend-record) (sr-nav-last) (ri--update-highlight))

(defun ri--set-submode-with-extend (submode setter)
  (when (ri--selection-active-p) (ri--adjust-anchor-for-new-submode submode))
  (funcall setter)
  (ri--update-highlight))
(defun ri-extend-set-line-mode () (interactive) (ri--set-submode-with-extend 'line #'sr-set-line-mode))
(defun ri-extend-set-line-star-mode () (interactive) (ri--set-submode-with-extend 'line-star #'sr-set-line-star-mode))
(defun ri-extend-set-character-mode () (interactive) (ri--set-submode-with-extend 'char #'sr-set-character-mode))
(defun ri-extend-set-word-mode () (interactive) (ri--set-submode-with-extend 'word #'sr-set-word-mode))
(defun ri-extend-set-word-star-mode () (interactive) (ri--set-submode-with-extend 'word-star #'sr-set-word-star-mode))
(defun ri-extend-set-word-plus-mode () (interactive) (ri--set-submode-with-extend 'word-plus #'sr-set-word-plus-mode))
(defun ri-extend-set-subword-mode () (interactive) (ri--set-submode-with-extend 'subword #'sr-set-subword-mode))


(defun ri-extend-escape ()
  "Exit selection-extend mode on Escape, or fall through to `mini-modal-normal'.
In NORM mode with an active extended selection: exit extend mode.
Otherwise: call `mini-modal-normal'."
  (interactive)
  (if (ri--selection-active-p)
      (progn
        (ri--exit-extend)
        (ri--update-highlight)
        (force-mode-line-update))
    (mini-modal-normal)))
(provide 'ri-extend)
;;; ri-extend.el ends here
