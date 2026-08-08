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
  preserved-boundary
  active-edge
  undo-stack)

(defvar-local ri--selection nil
  "The active `ri--selection-state', or nil outside extend mode.")

(defvar-local ri--dup-last-bounds nil
  "Temporary bounds of a just-created inline duplicate.")

(defun ri--selection-active-p ()
  "Return non-nil when the current buffer has an extended selection."
  (and (ri--selection-state-p ri--selection) t))

(cl-defstruct (ri--extend-entry
               (:constructor ri--extend-entry-create))
  "One selection-extension state for undo."
  point
  anchor
  active-edge
  preserved-boundary)

(defun ri--point-at-unit-edge (bounds edge)
  "Return cursor position for EDGE, keeping the end cursor inside BOUNDS."
  (if (and (eq edge 'end) (> (cdr bounds) (car bounds)))
      (1- (cdr bounds))
    (car bounds)))

(defun ri--set-preserved-boundary (state position)
  "Keep STATE's exact active boundary at POSITION."
  (let ((marker (ri--selection-state-preserved-boundary state)))
    (if (markerp marker)
        (set-marker marker position)
      (setf (ri--selection-state-preserved-boundary state)
            (copy-marker position)))))

(defun ri--clear-preserved-boundary (state)
  "Release STATE's exact active boundary override."
  (let ((marker (ri--selection-state-preserved-boundary state)))
    (when (markerp marker)
      (set-marker marker nil))
    (setf (ri--selection-state-preserved-boundary state) nil)))


(defun ri--next-unit-bounds (pos submode)
  "Return bounds of the unit after SUBMODE's unit at POS."
  (when-let* ((current (semantic-region-parse-at submode pos)))
    (let ((next (semantic-region-next current)))
      (while (and next
                  (eq submode 'line)
                  (semantic-region-empty-p next))
        (setq next (semantic-region-next next)))
      (when next
        (cons (semantic-region-beg next) (semantic-region-end next))))))

(defun ri--prev-unit-bounds (pos submode)
  "Return bounds of the unit before SUBMODE's unit at POS."
  (when-let* ((current (semantic-region-parse-at submode pos)))
    (let ((prev (semantic-region-prev current)))
      (while (and prev
                  (eq submode 'line)
                  (semantic-region-empty-p prev))
        (setq prev (semantic-region-prev prev)))
      (when prev
        (cons (semantic-region-beg prev) (semantic-region-end prev))))))

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
In extend mode, a submode change or cursor swap preserves the exact
selection already established until navigation moves the active edge.
Otherwise, horizontal unit modes keep selection boundaries exact;
WORD, WORD*, and SUBWORD keep the initial unit in the range while the
current unit crosses it, without changing cursor direction.  For line
modes, only the active edge snaps to a line boundary; the inactive
anchor remains at the exact boundary already established.
In normal mode: current unit bounds."
  (if-let* ((state ri--selection)
            (anchor (ri--selection-state-anchor state)))
      (let* ((anchor-pos (marker-position anchor))
             (preserved-pos
              (when-let* ((marker
                           (ri--selection-state-preserved-boundary state)))
                (marker-position marker)))
             (point-pos (point))
             (point-boundary (ri--extend-point-boundary))
             (raw-start (min anchor-pos point-pos))
             (raw-end (max anchor-pos point-pos))
             (active-edge
              (or (ri--selection-state-active-edge state)
                  (if (< anchor-pos point-pos) 'end 'start))))
        (cond
         ((integerp preserved-pos)
          (cons (min anchor-pos preserved-pos)
                (max anchor-pos preserved-pos)))
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

(defun ri--highlight-bounds ()
  "Return the model bounds RI requests for highlighting.
A temporary duplicate takes precedence over the active selection or
current semantic unit."
  (or ri--dup-last-bounds (ri--selection-bounds)))

(defun ri--exit-extend ()
  "Exit selection-extend mode and release its complete state."
  (when-let* ((state ri--selection))
    (dolist (marker (list (ri--selection-state-anchor state)
                          (ri--selection-state-initial-end state)
                          (ri--selection-state-preserved-boundary state)))
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
    (when-let* ((bounds
                 (sr--meaningful-unit-bounds-at (point) sr-submode)))
      (goto-char
       (if (and (not force-start)
                (ri--selection-active-p)
                (eq (ri--selection-state-active-edge ri--selection) 'end))
           (ri--point-at-unit-edge bounds 'end)
         (car bounds))))))

(defun ri--update-highlight ()
  "Refresh highlighting from RI's model through semantic-regions."
  (let ((sr-highlight-bounds-function #'ri--highlight-bounds))
    (sr--update-highlight)))

(defun ri--preserve-selection-for-submode-switch ()
  "Keep exact selection bounds while changing semantic submodes."
  (when-let* ((state ri--selection)
              (anchor (ri--selection-state-anchor state))
              (bounds (ri--selection-bounds)))
    (let* ((anchor-pos (marker-position anchor))
           (active-edge
            (or (ri--selection-state-active-edge state)
                (if (< anchor-pos (point)) 'end 'start))))
      (when-let* ((initial-end
                   (ri--selection-state-initial-end state)))
        (set-marker initial-end nil))
      (setf (ri--selection-state-initial-end state) nil
            (ri--selection-state-active-edge state) active-edge)
      (pcase active-edge
        ('end
         (set-marker anchor (car bounds))
         (goto-char (ri--point-at-unit-edge bounds 'end))
         (ri--set-preserved-boundary state (cdr bounds)))
        ('start
         (set-marker anchor (cdr bounds))
         (goto-char (car bounds))
         (ri--set-preserved-boundary state (car bounds)))))))

(defun ri--extend-record ()
  "Push the cursor-facing selection state onto the extension undo stack.
Do nothing outside extend mode."
  (when-let* ((state ri--selection))
    (push (ri--extend-entry-create
           :point (point)
           :anchor (when-let* ((anchor (ri--selection-state-anchor state)))
                     (marker-position anchor))
           :active-edge (ri--selection-state-active-edge state)
           :preserved-boundary
           (when-let* ((boundary
                        (ri--selection-state-preserved-boundary state)))
             (marker-position boundary)))
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
             (active-edge (ri--extend-entry-active-edge record))
             (preserved-boundary
              (ri--extend-entry-preserved-boundary record)))
        (goto-char point)
        (when (and (ri--selection-state-anchor state) anchor)
          (set-marker (ri--selection-state-anchor state) anchor))
        (setf (ri--selection-state-active-edge state) active-edge)
        (if preserved-boundary
            (ri--set-preserved-boundary state preserved-boundary)
          (ri--clear-preserved-boundary state))
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

(defun ri-swap-cursor ()
  "Move point to the opposite end of the current selection or unit.
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
                (setf (ri--selection-state-active-edge state) 'start)
                (ri--set-preserved-boundary state (car bounds)))
            (goto-char (if (> (cdr bounds) (car bounds))
                           (1- (cdr bounds))
                         (cdr bounds)))
            (set-marker anchor (car bounds))
            (setf (ri--selection-state-active-edge state) 'end)
            (ri--set-preserved-boundary state (cdr bounds)))))
    (when-let* ((bounds (sr--get-current-unit-bounds)))
      (if (= (point) (car bounds))
          (goto-char (if (> (cdr bounds) (car bounds))
                         (1- (cdr bounds))
                       (cdr bounds)))
        (goto-char (car bounds))))))

(defun ri--select-all-submode-p ()
  "Return non-nil when repeated Extend has a select-all behavior."
  (memq sr-submode '(line line-star char word word-plus word-star)))

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
      (ri--clear-preserved-boundary state)
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


(defun ri--finish-extend-navigation (origin)
  "Finish extension navigation that started at ORIGIN."
  (when (and ri--selection (/= origin (point)))
    (ri--clear-preserved-boundary ri--selection))
  (ri--update-highlight))

(defun ri--run-extend-navigation (movement)
  "Record the selection, run MOVEMENT, and refresh Extend state."
  (ri--extend-record)
  (let ((origin (point)))
    (funcall movement)
    (ri--finish-extend-navigation origin)))

(defun ri--run-extend-horizontal-navigation (direction fallback)
  "Extend in DIRECTION, or invoke FALLBACK outside horizontal Extend."
  (ri--extend-record)
  (let ((origin (point)))
    (if (and (ri--selection-active-p) (sr--horizontal-submode-p))
        (ri--extend-horizontal-move direction)
      (funcall fallback))
    (ri--finish-extend-navigation origin)))

(defun ri-extend-nav-left ()
  (interactive)
  (ri--run-extend-horizontal-navigation 'left #'sr-nav-left))
(defun ri-extend-nav-right ()
  (interactive)
  (ri--run-extend-horizontal-navigation 'right #'sr-nav-right))
(defun ri-extend-nav-up () (interactive) (ri--run-extend-navigation #'sr-nav-up))
(defun ri-extend-nav-down () (interactive) (ri--run-extend-navigation #'sr-nav-down))
(defun ri-extend-nav-prev () (interactive) (ri--run-extend-navigation #'sr-nav-prev))
(defun ri-extend-nav-next () (interactive) (ri--run-extend-navigation #'sr-nav-next))
(defun ri-extend-nav-first () (interactive) (ri--run-extend-navigation #'sr-nav-first))
(defun ri-extend-nav-last () (interactive) (ri--run-extend-navigation #'sr-nav-last))

(defun ri--set-submode-with-extend (setter)
  "Switch submodes with SETTER without changing an active selection.
Outside Extend, place point at the start of the first traversable unit
at or after its old position."
  (let ((extending (ri--selection-active-p)))
    (when extending
      (ri--preserve-selection-for-submode-switch))
    (funcall setter)
    (unless extending
      (ri--snap-to-unit-start))
    (ri--update-highlight)))
(defun ri-extend-set-line-mode () (interactive) (ri--set-submode-with-extend #'sr-set-line-mode))
(defun ri-extend-set-line-star-mode () (interactive) (ri--set-submode-with-extend #'sr-set-line-star-mode))
(defun ri-extend-set-character-mode () (interactive) (ri--set-submode-with-extend #'sr-set-character-mode))
(defun ri-extend-set-word-mode () (interactive) (ri--set-submode-with-extend #'sr-set-word-mode))
(defun ri-extend-set-word-star-mode () (interactive) (ri--set-submode-with-extend #'sr-set-word-star-mode))
(defun ri-extend-set-word-plus-mode () (interactive) (ri--set-submode-with-extend #'sr-set-word-plus-mode))
(defun ri-extend-set-subword-mode () (interactive) (ri--set-submode-with-extend #'sr-set-subword-mode))


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
