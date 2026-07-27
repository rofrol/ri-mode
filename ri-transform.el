;;; ri-transform.el --- Text transformations for ri-mode -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow

;;; Commentary:

;; Text transformations for `ri-mode': case conversions, wrap/unwrap,
;; and comment toggling, invoked via the `F` momentary layer.

;;; Code:

(require 'subr-x)
(require 'ri-extend)
(require 'ri-edit)

;; ── Word splitting ───────────────────────────────────────────────

(defun ri--split-into-words (text)
  "Split TEXT into word segments.
Recognises separators (space, hyphen, underscore), camelCase
and PascalCase boundaries, and uppercase-run transitions (XMLParser)."
  (let ((result nil)
        (word-start 0)
        (len (length text))
        (i 0))
    ;; Normalise separator runs to single spaces.
    (setq text (replace-regexp-in-string "[-_[:space:]]+" " " text))
    (setq len (length text))
    (while (< i len)
      (let ((ch (aref text i)))
        (cond
         ;; Space is always a word boundary.
         ((eq ch ?\s)
          (when (> i word-start)
            (push (substring text word-start i) result))
          (setq word-start (1+ i)))
         ;; Case boundaries (skip the first character).
         ((>= i 1)
          (let ((prev (aref text (1- i))))
            (when (or
                   ;; camelCase: lowercase → uppercase.
                   (and (>= prev ?a) (<= prev ?z)
                        (>= ch ?A) (<= ch ?Z))
                   ;; XMLParser: uppercase → uppercase, next is lowercase.
                   (and (>= prev ?A) (<= prev ?Z)
                        (>= ch ?A) (<= ch ?Z)
                        (< (1+ i) len)
                        (>= (aref text (1+ i)) ?a)
                        (<= (aref text (1+ i)) ?z)))
              (push (substring text word-start i) result)
              (setq word-start i))))))
      (setq i (1+ i)))
    (when (> len word-start)
      (push (substring text word-start len) result))
    (nreverse result)))

;; ── Core transform helper ────────────────────────────────────────

(defun ri--transform-case (transform-fn)
  "Replace the current selection text with the result of TRANSFORM-FN.
TRANSFORM-FN receives a list of word strings and returns the
transformed string.  Point is left at the start of the replaced text."
  (when-let* ((bounds (ri--selection-bounds))
              (text (ri--bounds-text bounds)))
    (let ((words (ri--split-into-words text)))
      (when words
        (ri--with-buffer-edit
          (ri--replace-text (car bounds) (cdr bounds)
                            (funcall transform-fn words)))
        (goto-char (car bounds))
        (ri--update-highlight)))))

;; ── Case conversions ─────────────────────────────────────────────

(defun ri-transform-upper ()
  "Transform the current selection to UPPER CASE."
  (interactive)
  (ri--transform-case
   (lambda (words) (upcase (mapconcat #'identity words " ")))))

(defun ri-transform-upper-snake ()
  "Transform the current selection to UPPER_SNAKE_CASE."
  (interactive)
  (ri--transform-case
   (lambda (words) (upcase (mapconcat #'identity words "_")))))

(defun ri-transform-pascal ()
  "Transform the current selection to PascalCase."
  (interactive)
  (ri--transform-case
   (lambda (words)
     (mapconcat #'capitalize words ""))))

(defun ri-transform-upper-kebab ()
  "Transform the current selection to Upper-Kebab-Case."
  (interactive)
  (ri--transform-case
   (lambda (words)
     (mapconcat #'capitalize words "-"))))

(defun ri-transform-title ()
  "Transform the current selection to Title Case."
  (interactive)
  (ri--transform-case
   (lambda (words)
     (mapconcat #'capitalize words " "))))

(defun ri-transform-lower ()
  "Transform the current selection to lower case."
  (interactive)
  (ri--transform-case
   (lambda (words) (downcase (mapconcat #'identity words " ")))))

(defun ri-transform-snake ()
  "Transform the current selection to snake_case."
  (interactive)
  (ri--transform-case
   (lambda (words) (downcase (mapconcat #'identity words "_")))))

(defun ri-transform-camel ()
  "Transform the current selection to camelCase."
  (interactive)
  (ri--transform-case
   (lambda (words)
     (concat (downcase (car words))
             (mapconcat #'capitalize (cdr words) "")))))

(defun ri-transform-kebab ()
  "Transform the current selection to kebab-case."
  (interactive)
  (ri--transform-case
   (lambda (words) (downcase (mapconcat #'identity words "-")))))

;; ── Wrap / Unwrap ────────────────────────────────────────────────

(defun ri-transform-wrap ()
  "Hard-wrap the current selection at `fill-column'."
  (interactive)
  (when-let* ((bounds (ri--selection-bounds)))
    (ri--with-buffer-edit
      (fill-region (car bounds) (cdr bounds)))
    (ri--update-highlight)))

(defun ri-transform-unwrap ()
  "Unwrap the current selection by joining lines with a single space."
  (interactive)
  (when-let* ((bounds (ri--selection-bounds)))
    (ri--with-buffer-edit
      (let ((text (ri--bounds-text bounds)))
        (setq text (replace-regexp-in-string "\\`\n+\\|\n+\\'" "" text))
        (setq text (replace-regexp-in-string "[ \t]*\n[ \t]*" " " text))
        (ri--replace-text (car bounds) (cdr bounds) text)))
    (ri--update-highlight)))

;; ── Comments ─────────────────────────────────────────────────────

(defun ri-transform-line-comment ()
  "Toggle line comments on the current selection."
  (interactive)
  (when-let* ((bounds (ri--selection-bounds)))
    (ri--with-buffer-edit
      (comment-or-uncomment-region (car bounds) (cdr bounds)))
    (ri--update-highlight)))

(defun ri-transform-block-comment ()
  "Toggle block comments on the current selection."
  (interactive)
  (when-let* ((bounds (ri--selection-bounds)))
    (let ((comment-style 'multi-line))
      (ri--with-buffer-edit
        (comment-or-uncomment-region (car bounds) (cdr bounds))))
    (ri--update-highlight)))

;; ── Momentary layer entry ────────────────────────────────────────

(defvar-keymap ri--transform-layer-map
  :doc "Transform momentary layer."
  "q" '(menu-item "UPPER CASE" ri-transform-upper)
  "w" '(menu-item "UPPER_SNAKE_CASE" ri-transform-upper-snake)
  "e" '(menu-item "PascalCase" ri-transform-pascal)
  "r" '(menu-item "Upper-Kebab" ri-transform-upper-kebab)
  "t" '(menu-item "Title Case" ri-transform-title)
  "a" '(menu-item "lower case" ri-transform-lower)
  "s" '(menu-item "snake_case" ri-transform-snake)
  "d" '(menu-item "camelCase" ri-transform-camel)
  "f" '(menu-item "kebab-case" ri-transform-kebab)
  "j" '(menu-item "Wrap" ri-transform-wrap)
  "h" '(menu-item "Unwrap" ri-transform-unwrap)
  "k" '(menu-item "Line Comment" ri-transform-line-comment)
  "l" '(menu-item "Block Comment" ri-transform-block-comment))

(provide 'ri-transform)
;;; ri-transform.el ends here
