;;; ri-duplicate.el --- Copy and duplicate operations -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow

;;; Commentary:

;; Copy and duplicate operations for `ri-mode'.

;;; Code:

(require 'subr-x)
(require 'semantic-regions)
(require 'ri-extend)

(defvar-local ri--dup-last-bounds nil
  "Temporary bounds used to highlight a newly duplicated inline unit.")

(defmacro ri--with-buffer-edit (&rest body)
  "Run BODY as one complete buffer undo unit."
  (declare (indent 0) (debug t))
  `(progn
     (undo-boundary)
     (unwind-protect
         (progn ,@body)
       (undo-boundary))))

(defun ri--bounds-text (bounds)
  "Return buffer text in BOUNDS without text properties."
  (when bounds
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(defun ri--current-unit-text ()
  "Return text of the current selection, or the current unit."
  (ri--bounds-text (ri--selection-bounds)))

(defun ri--highlight-bounds ()
  "Return current RI/semantic-regions highlight bounds, or nil."
  (when (and sr--highlight-overlay
             (overlay-buffer sr--highlight-overlay))
    (cons (overlay-start sr--highlight-overlay)
          (overlay-end sr--highlight-overlay))))

(defun ri--dup-target-bounds (direction bounds)
  "Return bounds of the unit reached from BOUNDS in DIRECTION."
  (save-excursion
    (let ((ri--selection nil))
      (goto-char (if (memq direction '(:left :prev))
                     (car bounds)
                   (max (car bounds) (1- (cdr bounds)))))
      (condition-case nil
          (progn
            (pcase direction
              (:left (sr-nav-left))
              (:right (sr-nav-right))
              (:prev (sr-nav-prev))
              (:next (sr-nav-next)))
            (sr--get-current-unit-bounds))
        ((beginning-of-buffer end-of-buffer) nil)))))

(defun ri--compute-gap (direction &optional current-bounds)
  "Compute gap text between CURRENT-BOUNDS and a neighboring unit."
  (let* ((bounds (or current-bounds (ri--selection-bounds)))
         (neighbor (and bounds (ri--dup-target-bounds direction bounds)))
         (before-p (memq direction '(:left :prev))))
    (if (not (and bounds neighbor))
        ""
      (let ((start (if before-p (cdr neighbor) (cdr bounds)))
            (end (if before-p (car bounds) (car neighbor))))
        (if (< start end)
            (buffer-substring-no-properties start end)
          "")))))

(defun ri--dup-reset ()
  "Clear the pending duplicate highlight."
  (setq ri--dup-last-bounds nil)
  (remove-hook 'pre-command-hook #'ri--dup-pre-command-hook t))

(defun ri--copy-dup-finish ()
  "Leave Extend after Copy/Dup and refresh highlighting and mode line."
  (ri--exit-extend)
  (ri--update-highlight)
  (force-mode-line-update))

(defun ri-copy-unit ()
  "Copy the current selection or unit to the kill ring, then leave Extend."
  (interactive)
  (when-let* ((text (ri--current-unit-text)))
    (kill-new text))
  (ri--copy-dup-finish))

(defun ri-dup-above ()
  "Duplicate the current selection or unit on a new line above."
  (interactive)
  (when-let* ((bounds (ri--selection-bounds))
              (text (ri--bounds-text bounds)))
    (let ((col (current-column)))
      (ri--with-buffer-edit
        (atomic-change-group
          (goto-char (car bounds))
          (let ((indent (current-indentation))
                (trimmed (string-trim-right text "[\n\r]+")))
            (beginning-of-line)
            (insert trimmed "\n")
            (indent-to indent)
            (forward-line -1)
            (beginning-of-line)
            (indent-to indent)
            (move-to-column col))))
      (ri--update-highlight)))
  (ri--copy-dup-finish))

(defun ri-dup-below ()
  "Duplicate the current selection or unit on a new line below."
  (interactive)
  (when-let* ((bounds (ri--selection-bounds))
              (text (ri--bounds-text bounds)))
    (let* ((col (current-column))
           (indent (save-excursion
                     (goto-char (max (car bounds) (1- (cdr bounds))))
                     (current-indentation)))
           (target-col (if (memq sr-submode '(word word-plus)) indent col))
           (ins-start (save-excursion
                        (goto-char (max (car bounds) (1- (cdr bounds))))
                        (min (1+ (line-end-position)) (point-max)))))
      (ri--with-buffer-edit
        (atomic-change-group
          (let ((trimmed (string-trim-right text "[\n\r]+")))
            (goto-char ins-start)
            (insert trimmed "\n")
            (indent-to indent)
            (forward-line -1)
            (indent-to indent)
            (move-to-column target-col))))
      (ri--update-highlight)))
  (ri--copy-dup-finish))

(defun ri--dup-inline (pos-side)
  "Duplicate the selection inline at its POS-SIDE boundary."
  (let* ((orig-bounds (or (ri--highlight-bounds)
                          (ri--selection-bounds)))
         (text (ri--bounds-text orig-bounds)))
    (when text
      (let ((ins-start (funcall pos-side orig-bounds)))
        (ri--with-buffer-edit
          (goto-char ins-start)
          (insert text)
          (goto-char ins-start))
        (ri--set-dup-highlight
         (cons ins-start (+ ins-start (length text))))))))

(defun ri-dup-before ()
  "Duplicate current unit inline, before itself, then leave Extend."
  (interactive)
  (ri--dup-inline 'car)
  (ri--copy-dup-finish))

(defun ri-dup-after ()
  "Duplicate current unit inline, after itself, then leave Extend."
  (interactive)
  (ri--dup-inline 'cdr)
  (ri--copy-dup-finish))

(defun ri--dup-with-gap (direction pos-side)
  "Duplicate current selection/unit with neighboring gap."
  (when-let* ((bounds (ri--selection-bounds))
              (text (ri--bounds-text bounds)))
    (let ((gap (ri--compute-gap direction bounds))
          (ins-start (funcall pos-side bounds)))
      (ri--with-buffer-edit
        (goto-char ins-start)
        (if (eq pos-side 'car)
            (insert text gap)
          (insert gap text)
          (goto-char (+ ins-start (length gap)))))
      (ri--update-highlight))))

(defun ri-dup-before-gap () (interactive) (ri--dup-with-gap :left 'car) (ri--copy-dup-finish))
(defun ri-dup-after-gap () (interactive) (ri--dup-with-gap :right 'cdr) (ri--copy-dup-finish))
(defun ri-dup-before-prev-gap () (interactive) (ri--dup-with-gap :prev 'car) (ri--copy-dup-finish))
(defun ri-dup-after-next-gap () (interactive) (ri--dup-with-gap :next 'cdr) (ri--copy-dup-finish))

(defun ri--dup-pre-command-hook ()
  "Clear cached inline duplicate bounds before the next command."
  (setq ri--dup-last-bounds nil)
  (remove-hook 'pre-command-hook #'ri--dup-pre-command-hook t))

(defun ri--set-dup-highlight (bounds)
  "Highlight duplicate BOUNDS until the next command starts."
  (setq ri--dup-last-bounds bounds)
  (add-hook 'pre-command-hook #'ri--dup-pre-command-hook nil t)
  (ri--update-highlight))

(defmacro ri--define-dup-chord-command (name fn)
  "Define a named duplicate command for KKP chord dispatch."
  `(defun ,name ()
     (interactive)
     (ri--dup-reset)
     (,fn)))

(ri--define-dup-chord-command ri--dup-chord-above ri-dup-above)
(ri--define-dup-chord-command ri--dup-chord-below ri-dup-below)
(ri--define-dup-chord-command ri--dup-chord-before-gap ri-dup-before-gap)
(ri--define-dup-chord-command ri--dup-chord-after-gap ri-dup-after-gap)
(ri--define-dup-chord-command ri--dup-chord-before-prev-gap ri-dup-before-prev-gap)
(ri--define-dup-chord-command ri--dup-chord-after-next-gap ri-dup-after-next-gap)
(ri--define-dup-chord-command ri--dup-chord-before ri-dup-before)
(ri--define-dup-chord-command ri--dup-chord-after ri-dup-after)

(provide 'ri-duplicate)
;;; ri-duplicate.el ends here
