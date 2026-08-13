;;; ri-pairs.el --- Smart pairs for RI insert state -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Buffer-local smart delimiter editing used by RI while it is in INST.
;; Pair insertion/overtype/deletion is delegated to Emacs' electric-pair
;; implementation.  This library adds a context-aware Return command which
;; expands an empty structural pair onto three properly indented lines.
;; Tree-sitter is used when a parser is already active, but is never required.

;;; Code:

(require 'cl-lib)
(require 'elec-pair)
(require 'treesit nil t)

(defgroup ri-pairs nil
  "Smart delimiter editing for RI insert state."
  :group 'editing)

(defcustom ri-pairs-tree-sitter-context-functions nil
  "Functions that may classify the tree-sitter context at point.
Each function is called with a tree-sitter NODE and should return one of
`code', `string', `comment', `argument-list', `parameter-list',
`type-context', `block', or nil.  The first non-nil result wins.
This is the extension point for language-specific node names."
  :type 'hook
  :group 'ri-pairs)

(defconst ri-pairs--open-to-close
  '((?\( . ?\))
    (?\{ . ?\}))
  "Delimiter pairs for RI smart Return.")

(defun ri-pairs--syntax-context ()
  "Return a basic context from Emacs syntax information at point."
  (let ((state (syntax-ppss)))
    (cond
     ((nth 3 state) 'string)
     ((nth 4 state) 'comment)
     (t 'code))))

(defun ri-pairs--node-type-category (node)
  "Return a generic RI context category for tree-sitter NODE, or nil."
  (let ((type (treesit-node-type node)))
    (cond
     ((string-match-p
       (rx (or "comment" "string" "string_literal" "raw_string"
               "quoted_string" "character_literal"))
       type)
      (if (string-match-p "comment" type) 'comment 'string))
     ((string-match-p
       (rx (or "type_argument" "type_arguments" "type_parameter"
               "type_parameters" "generic" "generic_type"
               "type_instantiation"))
       type)
      'type-context)
     ((string-match-p
       (rx (or "argument_list" "arguments" "call_arguments"))
       type)
      'argument-list)
     ((string-match-p
       (rx (or "parameter_list" "parameters" "formal_parameters"))
       type)
      'parameter-list)
     ((string-match-p
       (rx (or "block" "body" "compound_statement" "statement_block"))
       type)
      'block)
     (t nil))))

(defun ri-pairs--classify-node (node)
  "Classify NODE and its ancestors into a generic RI context."
  (let ((current node)
        category)
    (while (and current (not category))
      (setq category
            (or (run-hook-with-args-until-success
                 'ri-pairs-tree-sitter-context-functions current)
                (ri-pairs--node-type-category current)))
      (unless category
        (setq current (treesit-node-parent current))))
    category))

(defun ri-pairs--tree-sitter-context ()
  "Return context at point from an already-active tree-sitter parser.
Return nil when tree-sitter is unavailable or no parser is active.  Return
`ambiguous' when a parser exists but its node cannot be inspected safely."
  (when (and (featurep 'treesit)
             (treesit-available-p))
    (when-let* ((parsers (ignore-errors (treesit-parser-list)))
                (parser (car parsers)))
      (let* ((language (ignore-errors
                         (or (treesit-language-at (point))
                             (treesit-parser-language parser))))
             ;; At an insertion boundary, probing the character just before
             ;; point often gives a more useful containing node than probing
             ;; the closing punctuation immediately after point.
             (probe (if (> (point) (point-min)) (1- (point)) (point)))
             (node (and language
                        (ignore-errors (treesit-node-at probe language)))))
        (if node
            (or (ri-pairs--classify-node node) 'code)
          'ambiguous)))))

(defun ri-pairs-context-at-point ()
  "Return RI's generic syntactic context at point.
Tree-sitter has priority when an active parser can answer.  Emacs syntax
information is always used as a reliable string/comment guard and as the
fallback when tree-sitter is absent."
  (let ((syntax-context (ri-pairs--syntax-context)))
    ;; `syntax-ppss' is particularly reliable for string/comment state at an
    ;; insertion boundary, so never let a coarse tree node override it.
    (if (memq syntax-context '(string comment))
        syntax-context
      (or (ri-pairs--tree-sitter-context)
          syntax-context))))

(defun ri-pairs--empty-pair-at-point ()
  "Return (OPEN . CLOSE) when point is between a supported empty pair."
  (when (and (> (point) (point-min))
             (< (point) (point-max)))
    (let* ((open (char-before))
           (close (char-after))
           (expected (cdr (assq open ri-pairs--open-to-close))))
      (when (and expected (eq close expected))
        (cons open close)))))

(defun ri-pairs--smart-newline-allowed-p (pair context)
  "Return non-nil when PAIR may expand with smart Return in CONTEXT."
  (let ((open (car pair)))
    (pcase context
      ((or 'string 'comment 'type-context 'ambiguous) nil)
      ('argument-list (eq open ?\())
      ('parameter-list (eq open ?\())
      ('block (eq open ?\{))
      ('code (memq open '(?\( ?\{)))
      (_ nil))))

(defun ri-pairs--expand-empty-pair ()
  "Expand the empty pair around point and indent both new lines."
  (atomic-change-group
    (insert "\n\n")
    ;; Point is now immediately before the closing delimiter.  Indent that
    ;; line first, then return to and indent the newly-created inner line.
    (indent-according-to-mode)
    (forward-line -1)
    (indent-according-to-mode)))

(defun ri-pairs-return ()
  "Insert a context-aware newline in RI insert state.
Between an empty structural pair, expand it to three lines and delegate all
indentation decisions to the current major mode.  Else use ordinary
`newline-and-indent'."
  (interactive)
  (let ((pair (ri-pairs--empty-pair-at-point)))
    (if (and pair
             (ri-pairs--smart-newline-allowed-p
              pair (ri-pairs-context-at-point)))
        (ri-pairs--expand-empty-pair)
      (newline-and-indent))))

(defvar ri-pairs-insert-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ri-pairs-return)
    (define-key map (kbd "<return>") #'ri-pairs-return)
    map)
  "Keymap active only while RI is in insert state.")

(define-minor-mode ri-pairs-insert-mode
  "Enable RI smart pairs in the current buffer's insert state."
  :init-value nil
  :lighter ""
  :keymap ri-pairs-insert-mode-map
  ;; Pair insertion itself stays buffer-local and is installed by
  ;; `ri-pairs-enable-buffer'.  NORM suppresses self insertion anyway; this
  ;; mode only owns the insert-state Return binding.
  nil)

(defun ri-pairs--sync-insert-state ()
  "Synchronize pair support with `mini-modal-mode' in this buffer."
  (if (and (boundp 'mini-modal-mode)
           (not mini-modal-mode)
           (not (minibufferp))
           (not (derived-mode-p 'special-mode)))
      (ri-pairs-insert-mode 1)
    (ri-pairs-insert-mode -1)))

(defun ri-pairs-enable-buffer ()
  "Install RI pair-state synchronization in the current editing buffer."
  (unless (or (minibufferp)
              (derived-mode-p 'special-mode))
    (electric-pair-local-mode 1)
    (add-hook 'mini-modal-mode-hook #'ri-pairs--sync-insert-state nil t)
    (ri-pairs--sync-insert-state)))

(provide 'ri-pairs)
;;; ri-pairs.el ends here
