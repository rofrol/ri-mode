;;; ri.el --- Ri modal editing via the Kitty Keyboard Protocol -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;;
;; Author: Roman Frołow
;; Maintainer: Roman Frołow
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1") (kkp "0.1"))
;; Keywords: convenience, editing, terminals
;; URL: https://github.com/rofrol/ri-mode
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Ri-mode provides modal editing for terminals supporting the Kitty Keyboard Protocol (Kitty, Ghostty, WezTerm).
;;
;; For local development from the repository checkout:
;;
;;     emacs -Q -l ./ri.el
;;
;; Or from your Emacs config:
;;
;;     (load "~/personal_projects/emacs/ri-mode/ri.el")

;;; Code:

;;;; Dependencies

;; The Ri-specific libraries are bundled in sibling directories when the
;; package is built.  `package.el' adds only the package root to `load-path',
;; so expose those directories before requiring the bundled libraries.
(let ((ri-root (file-name-directory (or load-file-name buffer-file-name))))
  (when ri-root
    (add-to-list 'load-path ri-root)
    (dolist (dir '("mini-modal"
                   "kkp-chord"
                   "keymap-legend"
                   "status-frame"
                   "semantic-regions"
                   "modal-cursor"
                   "ri-tabs"
                   "ri-pick"
                   "ri-surround"
                   "ri-pairs"
                   "ri-mouse"))
      (let ((path (expand-file-name dir ri-root)))
        (when (file-directory-p path)
          (add-to-list 'load-path path))))))

(require 'mini-modal)
(require 'kkp-chord)
(require 'keymap-legend)
(require 'status-frame)
(require 'semantic-regions)
(require 'modal-cursor)
(require 'ri-tabs)
(require 'ri-extend)
(require 'ri-pick)
(require 'ri-duplicate)
(require 'ri-edit)
(require 'ri-transform)
(require 'ri-surround)
(require 'ri-pairs)
(require 'ri-mouse)
(require 'cl-lib)
(require 'face-remap)

(declare-function ri-lsp-pick-document-symbols "ri-lsp")
(declare-function ri-lsp-pick-workspace-symbols "ri-lsp")
(declare-function ri-lsp--find-outgoing-calls "ri-lsp")
(declare-function ri-lsp--find-incoming-calls "ri-lsp")
(declare-function ri-lsp--find-definition "ri-lsp")
(declare-function ri-lsp--find-declaration "ri-lsp")
(declare-function ri-lsp--find-type-definition "ri-lsp")
(declare-function ri-lsp--find-references-with-declaration "ri-lsp")
(declare-function ri-lsp--find-references-without-declaration "ri-lsp")
(declare-function ri-lsp--find-implementations "ri-lsp")

;;;; Mode-line styling

(defface ri-mode-line
  '((t (:foreground "#ffffff" :background "#3478c6")))
  "Face used for the `ri' status line."
  :group 'ri)

(defvar-local ri--mode-line-face-remappings nil
  "Face remapping cookies for the `ri' status line.")

(defun ri--mode-line-enable ()
  "Apply the classic blue RI styling to the current buffer's mode line,
including Eglot's project label."
  (unless ri--mode-line-face-remappings
    (setq ri--mode-line-face-remappings
          (mapcar (lambda (face)
                    (face-remap-add-relative face 'ri-mode-line))
                  '(mode-line-active mode-line-inactive mode-line
                    eglot-mode-line)))))

;;;; Status frame

(defun ri--hide-frame ()
  "Hide the status frame."
  (status-frame-hide))

;;;; Menu state

(defvar ri--menu-state nil
  "Current RI menu, or nil when no menu is active.")

(defvar-local ri--help-prefix-active nil
  "Non-nil while RI's default `C-h' help prefix is active.")

(defvar ri--restore-message-after-release nil
  "Echo-area message to restore after a swallowed Kitty key release.")

(defvar ri--restore-message-until-command-end nil
  "Non-nil means restore the pending message after every key release.")

(defun ri--restore-message-after-release ()
  "Restore a pending RI message after a swallowed Kitty key release."
  (when ri--restore-message-after-release
    (let ((text ri--restore-message-after-release))
      (unless ri--restore-message-until-command-end
        (setq ri--restore-message-after-release nil))
      (message "%s" text))))

(defun ri--clear-message-restoration ()
  "Stop restoring a message after the current command finishes."
  (setq ri--restore-message-after-release nil
        ri--restore-message-until-command-end nil)
  (remove-hook 'post-command-hook #'ri--clear-message-restoration))

(defun ri--call-preserving-user-error (function)
  "Call FUNCTION and preserve its user error across the next key release."
  (condition-case err
      (funcall function)
    (user-error
     (setq ri--restore-message-after-release (error-message-string err)
           ri--restore-message-until-command-end nil)
     (signal (car err) (cdr err)))))

(defun ri-set-node-mode ()
  "Switch to NODE, keeping a missing-parser error visible after key-up."
  (interactive)
  (ri--call-preserving-user-error #'ri-extend-set-node-mode))

(defun ri-parent-line ()
  "Move to the nearest tree-sitter parent line above point."
  (interactive)
  (ri--call-preserving-user-error #'ri-extend-nav-parent-line))

(defun ri-toggle-buffer-mark ()
  "Toggle the current buffer mark and preserve any user error after key-up."
  (interactive)
  (ri--call-preserving-user-error #'ri-tabs-toggle-buffer-mark))


(defun ri--close-menu ()
  "Hide any active menu and restore the status frame."
  (setq ri--menu-state nil)
  (keymap-legend-hide)
  (ri--hide-frame))

(defun ri--exit-menu ()
  "Exit the current menu, hide the frame, and return to NORM mode."
  (interactive)
  (set-transient-map nil)
  (ri--close-menu)
  (mini-modal-normal))

;;;; Keymaps

(defvar ri--space-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "Editor" ri-editor-menu))
    (define-key map "k" '(menu-item "Pick" ri-pick-menu))
    (define-key map "Z" '(menu-item "Out Calls" ri-find-outgoing-calls))
    (define-key map "z" '(menu-item "In Calls" ri-find-incoming-calls))
    (define-key map "x" '(menu-item "Def" ri-find-definition))
    (define-key map "X" '(menu-item "Decl" ri-find-declaration))
    (define-key map "c" '(menu-item "Type" ri-find-type-definition))
    (define-key map "V"
                '(menu-item "Ref+" ri-find-references-with-declaration))
    (define-key map "v"
                '(menu-item "Ref-" ri-find-references-without-declaration))
    (define-key map "b" '(menu-item "Impl" ri-find-implementations))
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Keymap for the Space menu.")

(defvar ri--editor-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "v" '(menu-item "Quit" ri--quit-with-check))
    (define-key map "q" '(menu-item "Quit No Save" ri--force-quit))
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Keymap for the Editor submenu.")

(defvar ri--pick-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "f" '(menu-item "Buffer" ri-pick-buffer))
    (define-key map "d" '(menu-item "File" ri-pick-file))
    (define-key map "s"
                '(menu-item "Symbol (Document)"
                            ri-pick-document-symbol))
    (define-key map "S"
                '(menu-item "Symbol (Workspace)"
                            ri-pick-workspace-symbol))
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Keymap for the Pick submenu.")


;;;; Menu commands

(defun ri-space-menu ()
  "Show the Space menu via a transient keymap."
  (interactive)
  (setq ri--menu-state 'space)
  (keymap-legend-show "Space" ri--space-layer-map '(:title "Space"))
  (set-transient-map
   ri--space-layer-map nil
   (lambda ()
     ;; Do not close a submenu that replaced this menu.
     (when (eq ri--menu-state 'space)
       (ri--close-menu)))))

(defun ri-editor-menu ()
  "Enter the Editor submenu."
  (interactive)
  (setq ri--menu-state 'editor)
  (keymap-legend-show "Editor" ri--editor-layer-map '(:title "Editor"))
  (set-transient-map
   ri--editor-layer-map t
   (lambda ()
     (when (eq ri--menu-state 'editor)
       (ri--close-menu)))))

(defun ri-pick-menu ()
  "Enter the Ki-compatible Pick submenu."
  (interactive)
  (setq ri--menu-state 'pick)
  (keymap-legend-show "Pick" ri--pick-layer-map '(:title "Pick"))
  (set-transient-map
   ri--pick-layer-map nil
   (lambda ()
     (when (eq ri--menu-state 'pick)
       (ri--close-menu)))))

(defun ri--picker-closed (&optional _accepted)
  "Clear RI menu state after a picker closes."
  (setq ri--menu-state nil)
  (ri--hide-frame))

(defun ri--open-picker (function)
  "Replace the Pick submenu with the picker opened by FUNCTION."
  (setq ri--menu-state 'picker)
  (keymap-legend-hide)
  (ri--hide-frame)
  (condition-case error
      (ri--call-preserving-user-error
       (lambda () (funcall function #'ri--picker-closed)))
    (error
     (setq ri--menu-state nil)
     (signal (car error) (cdr error)))))

(defun ri--open-lsp-picker (function)
  "Load Ri's LSP support and open the picker provided by FUNCTION."
  (require 'ri-lsp)
  (ri--open-picker function))

(defun ri-pick-buffer ()
  "Pick one of the open file buffers."
  (interactive)
  (ri--open-picker #'ri-pick-open-buffers))

(defun ri-pick-file ()
  "Pick a file from the current project."
  (interactive)
  (ri--open-picker #'ri-pick-open-files))

(defun ri-pick-document-symbol ()
  "Pick an Eglot symbol from the current document."
  (interactive)
  (ri--open-lsp-picker #'ri-lsp-pick-document-symbols))

(defun ri-pick-workspace-symbol ()
  "Pick an Eglot symbol from the current workspace."
  (interactive)
  (ri--open-lsp-picker #'ri-lsp-pick-workspace-symbols))

(defun ri-transform-menu ()
  "Show the Transform menu until a transformation is chosen."
  (interactive)
  (setq ri--menu-state 'transform)
  (keymap-legend-show
   "Transform" ri--transform-menu-map '(:title "Transform"))
  (set-transient-map
   ri--transform-menu-map nil
   (lambda ()
     (when (eq ri--menu-state 'transform)
       (ri--close-menu)))))


(defun ri--run-space-lsp-command (function)
  "Close the Space menu UI and call Eglot-backed FUNCTION."
  (require 'ri-lsp)
  (ri--close-menu)
  (ri--call-preserving-user-error function))

(defun ri-find-outgoing-calls ()
  "Show callees of the symbol at point."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-outgoing-calls))

(defun ri-find-incoming-calls ()
  "Show callers of the symbol at point."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-incoming-calls))

(defun ri-find-definition ()
  "Find definitions of the symbol at point."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-definition))

(defun ri-find-declaration ()
  "Find declarations of the symbol at point."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-declaration))

(defun ri-find-type-definition ()
  "Find type definitions of the symbol at point."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-type-definition))

(defun ri-find-references-with-declaration ()
  "Find references including the declaration."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-references-with-declaration))

(defun ri-find-references-without-declaration ()
  "Find references excluding the declaration."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-references-without-declaration))

(defun ri-find-implementations ()
  "Find implementations of the symbol at point."
  (interactive)
  (ri--run-space-lsp-command #'ri-lsp--find-implementations))

(defun ri--finish-edit-command ()
  "Leave Extend after an edit command and refresh RI UI state."
  (ri--exit-extend)
  (ri--update-highlight)
  (force-mode-line-update))



;;;; Surround menu

(defvar ri--surround-change-from nil
  "Enclosure kind selected as the source of Change Surround.")

(defun ri--surround-close-menu ()
  "Close the active Surround menu without changing modal state."
  (set-transient-map nil)
  (ri--close-menu))

(defun ri--surround-run (function kind)
  "Close Surround UI and call FUNCTION with enclosure KIND."
  (ri--surround-close-menu)
  (funcall function kind))

(defun ri--surround-add-command (kind)
  (ri--surround-run #'ri-surround-add kind))
(defun ri--surround-delete-command (kind)
  (ri--surround-run #'ri-surround-delete kind))
(defun ri--surround-select-inside-command (kind)
  (ri--surround-run #'ri-surround-select-inside kind))
(defun ri--surround-select-around-command (kind)
  (ri--surround-run #'ri-surround-select-around kind))

(defun ri--surround-command-symbol (prefix kind)
  "Return/intern command symbol for PREFIX and KIND."
  (intern (format "ri--surround-%s-%s" prefix kind)))

(defun ri--surround-define-command (prefix function kind)
  "Define a small interactive surround command for FUNCTION and KIND."
  (let ((symbol (ri--surround-command-symbol prefix kind)))
    (unless (fboundp symbol)
      (fset symbol
            `(lambda ()
               (interactive)
               (ri--surround-run #',function ',kind))))
    symbol))

(defun ri--surround-enclosure-map (prefix function)
  "Build a Ki-layout enclosure map for PREFIX calling FUNCTION."
  (let ((map (make-sparse-keymap)))
    (dolist (spec ri-surround-enclosures)
      (let* ((kind (car spec))
             (props (cdr spec))
             (key (plist-get props :key))
             (label (plist-get props :label))
             (command (ri--surround-define-command prefix function kind)))
        (define-key map key (list 'menu-item label command))))
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map))

(defvar ri--surround-add-map
  (let ((map (ri--surround-enclosure-map "add" #'ri-surround-add)))
    (define-key map ";" '(menu-item "<></>" ri-surround-add-tag-menu-command))
    map))
(defvar ri--surround-delete-map
  (ri--surround-enclosure-map "delete" #'ri-surround-delete))
(defvar ri--surround-select-inside-map
  (ri--surround-enclosure-map "inside" #'ri-surround-select-inside))
(defvar ri--surround-select-around-map
  (ri--surround-enclosure-map "around" #'ri-surround-select-around))

(defun ri--surround-show-submenu (state title map)
  "Show Surround submenu STATE with TITLE and MAP."
  (setq ri--menu-state state)
  (keymap-legend-show title map (list :title title))
  (set-transient-map map t
                     (lambda ()
                       (when (eq ri--menu-state state)
                         (ri--close-menu)))))

(defun ri-surround-add-tag-menu-command ()
  "Close Surround UI, prompt for a tag, and surround with it."
  (interactive)
  (ri--surround-close-menu)
  (call-interactively #'ri-surround-add-tag))

(defun ri-surround-add-menu ()
  (interactive)
  (ri--surround-show-submenu 'surround-add "Surround" ri--surround-add-map))
(defun ri-surround-delete-menu ()
  (interactive)
  (ri--surround-show-submenu 'surround-delete "Delete Surround" ri--surround-delete-map))
(defun ri-surround-select-inside-menu ()
  (interactive)
  (ri--surround-show-submenu 'surround-inside "Select Inside" ri--surround-select-inside-map))
(defun ri-surround-select-around-menu ()
  (interactive)
  (ri--surround-show-submenu 'surround-around "Select Around" ri--surround-select-around-map))

(defun ri--surround-change-to-command (kind)
  "Complete Change Surround using KIND as the replacement."
  (let ((from ri--surround-change-from))
    (setq ri--surround-change-from nil)
    (ri--surround-close-menu)
    (ri-surround-change from kind)))

(defun ri--surround-change-from-command (kind)
  "Remember source KIND and show the replacement enclosure map."
  (setq ri--surround-change-from kind)
  (ri--surround-show-submenu
   'surround-change-to "Change Surround To" ri--surround-change-to-map))

(defvar ri--surround-change-from-map
  (ri--surround-enclosure-map "change-from" #'ri--surround-change-from-command))
(defvar ri--surround-change-to-map
  (ri--surround-enclosure-map "change-to" #'ri--surround-change-to-command))

(defvar ri--surround-menu-map
  (let ((map (make-sparse-keymap)))
    (define-key map "d" '(menu-item "Select Inside" ri-surround-select-inside-menu))
    (define-key map "e" '(menu-item "Select Around" ri-surround-select-around-menu))
    (define-key map "f" '(menu-item "Change Surround" ri-surround-change-menu))
    (define-key map "r" '(menu-item "Delete Surround" ri-surround-delete-menu))
    (define-key map "s" '(menu-item "Surround" ri-surround-add-menu))
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Ki-style Surround operation menu.")

(defun ri-surround-change-menu ()
  (interactive)
  (setq ri--surround-change-from nil)
  (ri--surround-show-submenu
   'surround-change-from "Change Surround From" ri--surround-change-from-map))

(defun ri-surround-menu ()
  "Open the Ki-style Surround menu."
  (interactive)
  (ri--surround-show-submenu 'surround "Surround" ri--surround-menu-map))

;;;; Quit with unsaved-file check

(defun ri--unsaved-files ()
  "Return a list of unsaved file names.
Files under a git root are displayed relative to that root;
otherwise just the base name is shown."
  (let (result)
    (dolist (buf (buffer-list))
      (when (and (buffer-file-name buf)
                 (buffer-modified-p buf))
        (let* ((file (buffer-file-name buf))
               (git-root (locate-dominating-file file ".git"))
               (display-name (if git-root
                                 (file-relative-name file git-root)
                               (file-name-nondirectory file))))
          (push display-name result))))
    (nreverse result)))

(defun ri--quit-with-check ()
  "Quit Emacs, unless there are unsaved files.
Unsaved files are reported in the echo area and the menu is dismissed."
  (interactive)
  (let ((unsaved (ri--unsaved-files)))
    (if unsaved
        (progn
          (set-transient-map nil)
          (ri--close-menu)
          (let ((text
                 (format "Cannot quit with unsaved files: [%s]"
                         (mapconcat (lambda (f) (format "\"%s\"" f))
                                    unsaved ", "))))
            ;; The physical release of `v' is a KKP input event.  Emacs can
            ;; clear the echo area when that event arrives even though
            ;; kkp-chord swallows it.  Remember this message and replay it
            ;; from `kkp-chord-after-release-hook'.
            (setq ri--restore-message-after-release text
                  ri--restore-message-until-command-end nil)
            (message "%s" text)))
      (set-transient-map nil)
      (ri--close-menu)
      (save-buffers-kill-terminal))))

;;;; Force quit (no save)

(defun ri--force-quit ()
  "Force quit Emacs immediately without saving changes."
  (interactive)
  (set-transient-map nil)
  (ri--close-menu)
  (kill-emacs))

;;;; Paste momentary layer (v: tap-hold via KKP chord)

(defun ri--paste-at (position &optional prefix suffix)
  "Paste the latest kill-ring entry at POSITION.
Insert PREFIX before and SUFFIX after the pasted text when supplied."
  (ri--with-buffer-edit
    (goto-char position)
    (when prefix
      (insert prefix))
    (let ((paste-start (point)))
      (yank)
      (when suffix
        (insert suffix))
      (goto-char paste-start)))
  (ri--finish-edit-command))

(defun ri-paste-selection ()
  "Replace the current selection/unit with the latest kill-ring entry."
  (interactive)
  (let* ((bounds (ri--selection-bounds))
         (start (if bounds (car bounds) (point))))
    (ri--with-buffer-edit
      (when bounds
        (delete-region (car bounds) (cdr bounds)))
      (goto-char start)
      (yank)
      (goto-char start))
    (ri--finish-edit-command)))

(defun ri--paste-inline (pos-side)
  "Paste the latest kill-ring entry at POS-SIDE of the selection."
  (when-let* ((bounds (ri--selection-bounds)))
    (ri--paste-at (funcall pos-side bounds))))

(defun ri-paste-before ()
  "Paste the latest kill-ring entry before the current selection."
  (interactive)
  (ri--paste-inline 'car))

(defun ri-paste-after ()
  "Paste the latest kill-ring entry after the current selection."
  (interactive)
  (ri--paste-inline 'cdr))

(defun ri--paste-with-gap (direction pos-side)
  "Paste with the gap from DIRECTION at POS-SIDE of the selection."
  (when-let* ((bounds (ri--selection-bounds))
              (gap (ri--compute-gap direction bounds)))
    (ri--paste-at (funcall pos-side bounds)
                  (when (eq pos-side 'car) gap)
                  (when (eq pos-side 'cdr) gap))))

(defun ri-paste-before-gap ()
  "Paste before the current selection with the gap on its left."
  (interactive)
  (ri--paste-with-gap :left 'car))

(defun ri-paste-after-gap ()
  "Paste after the current selection with the gap on its right."
  (interactive)
  (ri--paste-with-gap :right 'cdr))

(defun ri-paste-before-prev-gap ()
  "Paste before the current selection with the prev-unit gap."
  (interactive)
  (ri--paste-with-gap :prev 'car))

(defun ri-paste-after-next-gap ()
  "Paste after the current selection with the next-unit gap."
  (interactive)
  (ri--paste-with-gap :next 'cdr))

(defun ri--paste-vertically (below)
  "Paste on a new line BELOW when BELOW is non-nil, otherwise above."
  (let* ((line-start (line-beginning-position))
         (line-end (line-end-position))
         (indent (buffer-substring-no-properties
                  line-start
                  (save-excursion
                    (goto-char line-start)
                    (back-to-indentation)
                    (point)))))
    (if below
        (ri--paste-at line-end (concat "\n" indent))
      (ri--paste-at line-start indent "\n"))))

(defun ri-paste-above ()
  "Paste the latest kill-ring entry on an indented line above."
  (interactive)
  (ri--paste-vertically nil))

(defun ri-paste-below ()
  "Paste the latest kill-ring entry on an indented line below."
  (interactive)
  (ri--paste-vertically t))

(defun ri-enter-insert-left ()
  "Move to the start of the current unit and enter insert mode."
  (interactive)
  (when-let* ((bounds (sr--get-current-unit-bounds)))
    (goto-char (car bounds)))
  (ri--exit-extend)
  (ri--update-highlight)
  (mini-modal-insert))

(defun ri-enter-insert-right ()
  "Move to the end of the current unit and enter insert mode."
  (interactive)
  (when-let* ((bounds (sr--get-current-unit-bounds)))
    (goto-char (cdr bounds)))
  (ri--exit-extend)
  (ri--update-highlight)
  (mini-modal-insert))

(defvar ri--copy-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "<< Gap Dup" ri--dup-chord-before-gap))
    (define-key map "l" '(menu-item "Gap Dup >>" ri--dup-chord-after-gap))
    (define-key map "o" '(menu-item "Gap Dup >" ri--dup-chord-after-next-gap))
    (define-key map "u" '(menu-item "< Gap Dup" ri--dup-chord-before-prev-gap))
    (define-key map ";" '(menu-item "Dup >" ri--dup-chord-after))
    (define-key map "h" '(menu-item "< Dup" ri--dup-chord-before))
    (define-key map "i" '(menu-item "Dup ^" ri--dup-chord-above))
    (define-key map "k" '(menu-item "Dup v" ri--dup-chord-below))
    map)
  "Keymap for the Copy/Dup momentary layer (c held).")

(defvar ri--eat-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "<< Eat" ri-eat-left))
    (define-key map "l" '(menu-item "Eat >>" ri-eat-right))
    (define-key map "u" '(menu-item "< Eat" ri-eat-prev))
    (define-key map "o" '(menu-item "Eat >" ri-eat-next))
    (define-key map "y" '(menu-item "|< Eat" ri-eat-first))
    (define-key map "p" '(menu-item "Eat >|" ri-eat-last)) map))

(defvar ri--buffer-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j"
                '(menu-item "<< Marked File"
                            ri-tabs-switch-to-left-marked-buffer))
    (define-key map "l"
                '(menu-item "Marked File >>"
                            ri-tabs-switch-to-right-marked-buffer))
    (define-key map "y"
                '(menu-item "|< Marked File"
                            ri-tabs-switch-to-first-marked-buffer))
    (define-key map "p"
                '(menu-item "Marked File >|"
                            ri-tabs-switch-to-last-marked-buffer))
    (define-key map "u"
                '(menu-item "Marked File >"
                            ri-tabs-switch-to-previous-buffer))
    (define-key map "o"
                '(menu-item "< Marked File"
                            ri-tabs-switch-to-next-buffer))
    (define-key map "k"
                '(menu-item "Mark File" ri-toggle-buffer-mark))
    (define-key map "n" '(menu-item "Close" kill-current-buffer))
    (define-key map "i"
                '(menu-item "Unmark Others"
                            ri-tabs-unmark-other-buffers))
    (define-key map "m"
                '(menu-item "Alternate"
                            ri-tabs-switch-to-alternate-buffer))
    map)
  "Keymap for the Buffer momentary layer (e held).")

(defvar ri--open-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "<< Open" ri-open-left))
    (define-key map "l" '(menu-item "Open >>" ri-open-right))
    (define-key map "u" '(menu-item "< Open" ri-open-prev))
    (define-key map "o" '(menu-item "Open >" ri-open-next))
    (define-key map "h" '(menu-item "< Insert" ri-enter-insert-left))
    (define-key map ";" '(menu-item "Insert >" ri-enter-insert-right))
    (define-key map "i" '(menu-item "Open ^" ri-open-above))
    (define-key map "k" '(menu-item "Open v" ri-open-below)) map))

(defvar ri--swap-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "i" '(menu-item "Swap ^" ri-swap-up))
    (define-key map "j" '(menu-item "<< Swap" ri-swap-left))
    (define-key map "l" '(menu-item "Swap >>" ri-swap-right))
    (define-key map "k" '(menu-item "Swap v" ri-swap-down))
    (define-key map "u" '(menu-item "< Swap" ri-swap-prev))
    (define-key map "y" '(menu-item "|< Swap" ri-swap-first))
    (define-key map "p" '(menu-item "Swap >|" ri-swap-last))
    (define-key map "o" '(menu-item "Swap >" ri-swap-next)) map))

(defvar ri--paste-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "<< Gap Paste" ri-paste-before-gap))
    (define-key map "l" '(menu-item "Gap Paste >>" ri-paste-after-gap))
    (define-key map "u" '(menu-item "< Gap Paste" ri-paste-before-prev-gap))
    (define-key map "o" '(menu-item "Gap Paste >" ri-paste-after-next-gap))
    (define-key map "h" '(menu-item "< Paste" ri-paste-before))
    (define-key map ";" '(menu-item "Paste >" ri-paste-after))
    (define-key map "i" '(menu-item "Paste ^" ri-paste-above))
    (define-key map "k" '(menu-item "Paste v" ri-paste-below))
    map)
  "Keymap for the paste momentary layer (v held).")
(defvar ri--cut-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "<< Cut" ri-cut-left))
    (define-key map "l" '(menu-item "Cut >>" ri-cut-right))
    (define-key map "u" '(menu-item "< Cut" ri-cut-prev))
    (define-key map "o" '(menu-item "Cut >" ri-cut-next))
    (define-key map "y" '(menu-item "|< Cut" ri-cut-first))
    (define-key map "p" '(menu-item "Cut >|" ri-cut-last))
    map)
  "Keymap for the Cut momentary layer (x held).")

(defvar ri--undo-redo-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "Coarse Undo" ri-smart-undo))
    (define-key map "l" '(menu-item "Coarse Redo" ri-smart-redo))
    (define-key map "u" '(menu-item "Fine Undo" ri-fine-undo))
    (define-key map "o" '(menu-item "Fine Redo" ri-fine-redo))
    map)
  "Keymap for the Undo/Redo momentary layer (z held).")

(defvar ri--char-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "i" '(menu-item "CHAR ^" ri-momentary-char-up))
    (define-key map "j" '(menu-item "< CHAR" ri-momentary-char-left))
    (define-key map "k" '(menu-item "CHAR v" ri-momentary-char-down))
    (define-key map "l" '(menu-item "CHAR >" ri-momentary-char-right))
    map)
  "Keymap for momentary CHAR navigation (a held).")

(defvar ri--word-plus-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "i" '(menu-item "WORD+ ^" ri-momentary-word-plus-up))
    (define-key map "j" '(menu-item "< WORD+" ri-momentary-word-plus-left))
    (define-key map "k" '(menu-item "WORD+ v" ri-momentary-word-plus-down))
    (define-key map "l" '(menu-item "WORD+ >" ri-momentary-word-plus-right))
    map)
  "Keymap for momentary WORD+ navigation (s held).")


;;;; Layer specs (single source of truth for labels and icons)

(defconst ri--layer-specs
  (list
   (list :key ?a
         :label "CHAR"
         :tap #'ri-extend-set-character-mode
         :activate-on-press t
         :map ri--char-layer-map
         :release "CHAR")
   (list :key ?s
         :label "WORD+"
         :tap #'ri-extend-set-word-plus-mode
         :activate-on-press t
         :map ri--word-plus-layer-map
         :release "WORD+")
   (list :key ?c
         :label "Copy/≡ Dup"
         :tap #'ri-copy-unit
         :map ri--copy-layer-map
         :release "Copy")
   (list :key ?r :label "≡ Delete" :tap #'ri-delete-selection :map ri--eat-layer-map :release "Delete")
   (list :key ?e
         :label "≡ Buffer"
         :tap nil
         :map ri--buffer-layer-map
         :release nil)
   (list :key ?g :label "≡ Open" :tap #'ri-change-selection :map ri--open-layer-map :release "Change")
   (list :key ?t :label "≡ Swap" :tap nil :map ri--swap-layer-map :release nil)
   (list :key ?v
         :label "≡ Paste"
         :tap #'ri-paste-selection
         :map ri--paste-layer-map
         :release "Paste")
   (list :key ?x
         :label "≡ Cut"
         :tap #'ri-cut-selection
         :map ri--cut-layer-map
         :release "Cut")
   (list :key ?z
         :label "≡ Undo/Redo"
         :tap #'ri-undo-only
         :map ri--undo-redo-layer-map
         :release "Undo"))
  "Momentary layer specifications.
:key     -- KKP keycode for the chord modifier.
:label   -- Display label with icon (used in menus and legend titles).
:tap               -- Primary command called when the layer is tapped.
:activate-on-press -- Non-nil also runs :tap when the layer opens.
:map               -- Keymap for the momentary layer.
:release           -- Label shown on release, or nil.")

(defun ri--layer-spec (keycode)
  "Return the layer spec for KEYCODE, or nil."
  (cl-find keycode ri--layer-specs
           :key (lambda (s) (plist-get s :key))
           :test #'eql))

(defun ri--layer-context-p ()
  "Return non-nil when a RI momentary layer may be entered."
  (and (bound-and-true-p mini-modal-mode)
       (null ri--menu-state)
       (null ri--help-prefix-active)))

(defun ri--chord-when-p ()
  "Return non-nil when a KKP chord should be active.
Active only in NORM mode, when no transient menu is open, and when
Emacs is not reading a prefix key sequence."
  (and (ri--layer-context-p)
       ;; Let Emacs' prefix maps, including `C-h', own the following key.
       ;; KKP calls this predicate before the current event is added to
       ;; `this-command-keys-vector', so an empty vector means a standalone
       ;; key and a non-empty vector means that a prefix is in progress.
       (zerop (length (this-command-keys-vector)))))

(defun ri--press-layer ()
  "Enter the momentary layer bound to `last-command-event'.
This handles terminals that encode an ordinary key press as one byte
and its release as a KKP CSI-u event."
  (interactive)
  (let* ((keycode (event-basic-type last-command-event))
         (spec (and (characterp keycode) (ri--layer-spec keycode))))
    (unless spec
      (user-error "No RI layer bound to %s"
                  (single-key-description last-command-event)))
    (if (ri--layer-context-p)
        (progn
          (kkp-chord-press keycode)
          ;; Opening UI is not an editing command and must not break a
          ;; consecutive undo sequence before the held sub-key arrives.
          (setq this-command last-command))
      (when-let* ((tap (plist-get spec :tap)))
        (funcall tap)))))

(defun ri-chord-setup ()
  "Register KKP chords and plain-press fallbacks from `ri--layer-specs'."
  (dolist (spec ri--layer-specs)
    (let ((key (plist-get spec :key))
          (tap (plist-get spec :tap))
          (activate-on-press (plist-get spec :activate-on-press))
          (map (plist-get spec :map))
          (label (plist-get spec :label))
          (release (plist-get spec :release)))
      (kkp-chord-define key
        :tap tap
        :when #'ri--chord-when-p
        :on-press (lambda ()
                    (when activate-on-press
                      (funcall tap))
                    (ri--hide-frame)
                    (keymap-legend-show label map
                      (list :title label :release release))
                    ;; Showing the momentary legend creates/updates a window,
                    ;; which can make a TTY re-emit its default cursor shape.
                    ;; The modal state did not change, so explicitly restore
                    ;; the cursor that belongs to NORM.
                    (modal-cursor-refresh))
        :on-release #'keymap-legend-hide
        :map map)
      (define-key mini-modal-map (string key) #'ri--press-layer))))

;; Registration only populates KKP dispatch tables.  Do it while loading so
;; evaluating this file refreshes newly added layers in an active RI session.
(ri-chord-setup)
(when kkp-chord-mode
  (kkp-chord-mode 1))

;;;; Mode line

(defun ri--submode-name ()
  "Return the human-readable name for the current `sr-submode'."
  (if (boundp 'sr-submode)
      (pcase sr-submode
        ('line "LINE")
        ('line-star "LINE*")
        ('paragraph "PARAGRAPH")
        ('char "CHAR")
        ('word "WORD")
        ('word-plus "WORD+")
        ('word-star "WORD*")
        ('subword "SUBWORD")
        ('node "NODE")
        (_ "?"))
    "?"))

(defun ri--mode-line-text ()
  "Return the mode-line text with mode, submode, Extend, and help hint."
  (if (bound-and-true-p mini-modal-mode)
      (format " NORM[%s]%s [Press ? for help]"
              (ri--submode-name)
              (if (ri--selection-active-p) " Extend" ""))
    " INST"))

;;;; Help keymap legend

(defvar ri--normal-help-map
  (let ((map (make-sparse-keymap)))
    (define-key map "h" '(menu-item "← Insert" ri-enter-insert-left))
    (define-key map ";" '(menu-item "Insert →" ri-enter-insert-right))
    (define-key map "j" '(menu-item "<<" ri-extend-nav-left))
    (define-key map "l" '(menu-item ">>" ri-extend-nav-right))
    (define-key map "i" '(menu-item "^" ri-extend-nav-up))
    (define-key map "k" '(menu-item "v" ri-extend-nav-down))
    (define-key map "I" '(menu-item "Join Lines" ri-join-lines))
    (define-key map "J" '(menu-item "Dedent" ri-dedent))
    (define-key map "L" '(menu-item "Indent" ri-indent))
    (define-key map "u" '(menu-item "<" ri-extend-nav-prev))
    (define-key map "o" '(menu-item ">" ri-extend-nav-next))
    (define-key map "y" '(menu-item "|<" ri-extend-nav-first))
    (define-key map "p" '(menu-item ">|" ri-extend-nav-last))
    (define-key map "." '(menu-item "Parent Line" ri-parent-line))
    (define-key map "a" '(menu-item "≡ CHAR" ri-extend-set-character-mode))
    (define-key map "A" '(menu-item "LINE*" ri-extend-set-line-star-mode))
    (define-key map "W" '(menu-item "CHAR" ri-extend-set-character-mode))
    (define-key map "E" '(menu-item "PARAGRAPH" ri-extend-set-paragraph-mode))
    (define-key map "s" '(menu-item "≡ WORD+" ri-extend-set-word-plus-mode))
    (define-key map "S" '(menu-item "WORD*" ri-extend-set-word-star-mode))
    (define-key map (kbd "M-s") '(menu-item "WORD+" ri-extend-set-word-plus-mode))
    (define-key map "w" '(menu-item "SUBWORD" ri-extend-set-subword-mode))
    (define-key map "d" '(menu-item "NODE" ri-set-node-mode))
    (define-key map "c" '(menu-item "Copy/≡ Dup" ri-copy-unit))
    (define-key map "r" '(menu-item "≡ Delete" ri-delete-selection))
    (define-key map "e" '(menu-item "≡ Buffer" ignore))
    (define-key map "g" '(menu-item "≡ Open" ri-change-selection))
    (define-key map "t" '(menu-item "≡ Swap" ignore))
    (define-key map "F" '(menu-item "⌨︎ Transform" ri-transform-menu))
    (define-key map "," '(menu-item "Surround" ri-surround-menu))
    (define-key map "v" '(menu-item "≡ Paste" ri-paste-selection))
    (define-key map "x" '(menu-item "≡ Cut" ri-cut-selection))
    (define-key map "f" '(menu-item "Extend" ri-toggle-extend))
    (define-key map "z" '(menu-item "≡ Undo/Redo" ri-undo-only))
    (define-key map "Z" '(menu-item "Coarse Redo" ri-smart-redo))
    (define-key map (kbd "SPC") '(menu-item "Space" ri-space-menu))
    (define-key map (kbd "<return>") '(menu-item "Save" save-buffer))
    (define-key map "/" '(menu-item "⇋ Curs" ri-swap-cursor))
    (define-key map "?" '(menu-item "Help" ignore))
    (define-key map (kbd "C-h") '(menu-item "Help" help-command))

    (define-key map (kbd "<escape>") '(menu-item "Close" ignore))
    map)
  "Keymap documenting NORM mode bindings for the help legend.")

(defun ri--show-help ()
  "Show the NORM mode keymap legend, dismissed on next key press."
  (interactive)
  (keymap-legend-show "NORM" ri--normal-help-map '(:title "Normal Mode"))
  (set-transient-map (make-sparse-keymap) nil #'keymap-legend-hide))

(defvar ri--help-prefix-map
  (let ((map (make-sparse-keymap)))
    ;; `help-for-help' rejects an otherwise unbound ESC before KKP's
    ;; input decoder can finish reading a Kitty CSI-u release sequence.
    (define-key map (kbd "ESC") (make-sparse-keymap))
    (define-key map "?" #'ri--help-for-help)
    map)
  "RI overlay on Emacs' default `C-h' prefix map.")

(defun ri--help-prefix-map-for (binding)
  "Return RI's help overlay inheriting from prefix BINDING."
  (let ((parent (if (keymapp binding)
                    binding
                  (symbol-function binding))))
    (unless (keymapp parent)
      (error "Not a prefix keymap: %S" binding))
    (set-keymap-parent ri--help-prefix-map parent)
    ri--help-prefix-map))

(defun ri--help-for-help ()
  "Show Emacs' help screen without mistaking KKP releases for input.
`help-for-help' installs a catch-all map while it reads its next key.
Keeping ESC as a prefix lets `input-decode-map' finish each Kitty CSI-u
release sequence, which `kkp-chord' then swallows."
  (interactive)
  (let ((help-map (ri--help-prefix-map-for 'help-command)))
    (help-for-help)))
(defun ri--exit-help-prefix ()
  "Hide the C-h help legend before its next command.
Preserve the prompt used by `Info-goto-emacs-key-command-node' across
the physical release of the key that invoked it."
  (when (eq this-command #'Info-goto-emacs-key-command-node)
    (setq ri--restore-message-after-release
          (propertize "Find documentation for key: "
                      'face 'minibuffer-prompt)
          ri--restore-message-until-command-end t)
    (add-hook 'post-command-hook #'ri--clear-message-restoration))
  (remove-hook 'pre-command-hook #'ri--exit-help-prefix t)
  (setq ri--help-prefix-active nil)
  (keymap-legend-hide))

(defconst ri--help-prefix-labels
  '((help-quit . "Quit Help")
    (describe-command . "Desc Cmd")
    (where-is . "Find Key")
    (describe-variable . "Desc Var")
    (help-with-tutorial . "Tutorial")
    (describe-syntax . "Desc Syn")
    (info-display-manual . "Info Man")
    (info-emacs-manual . "Emacs Man")
    (describe-package . "Desc Pkg")
    (finder-by-keyword . "Find Pkg")
    (view-emacs-news . "News")
    (describe-symbol . "Desc Sym")
    (describe-mode . "Desc Mode")
    (view-lossage . "Lossage")
    (describe-key . "Desc Key")
    (info . "Info")
    (apropos . "Apro")
    (apropos-user-option . "Apro Opt")
    (view-hello-file . "Hello")
    (describe-gnu-project . "Desc GNU")
    (describe-function . "Desc Fn")
    (view-echo-area-messages . "Echo Msg")
    (apropos-documentation . "Apro Docs")
    (describe-key-briefly . "Key Brief")
    (describe-bindings . "Desc Binds")
    (apropos-command . "Apro Cmd")
    (info-lookup-symbol . "Info Sym")
    (describe-language-environment . "Desc Lang")
    (Info-goto-emacs-key-command-node . "Key Node")
    (describe-input-method . "Desc Input")
    (Info-goto-emacs-command-node . "Cmd Node")
    (describe-coding-system . "Desc Code")
    (describe-no-warranty . "Warranty")
    (view-emacs-todo . "Todo")
    (search-forward-help-for-help . "Find Help")
    (help-quick-toggle . "Quick Help")
    (view-emacs-problems . "Problems")
    (describe-distribution . "Desc Dist")
    (view-order-manuals . "Order Man")
    (view-emacs-FAQ . "FAQ")
    (view-external-packages . "Ext Pkgs")
    (view-emacs-debugging . "Debug")
    (describe-copying . "Desc Copy")
    (about-emacs . "About")
    (help-for-help . "Help")
    (display-local-help . "Local Help"))
  "Concise labels for commands displayed by the C-h legend.")

(defun ri--help-prefix-label (command)
  "Return the concise C-h legend label for COMMAND."
  (or (cdr (assq command ri--help-prefix-labels))
      (keymap-legend--command-description command)))

(defun ri--help-prefix-legend-map ()
  "Return printable bindings from Emacs' `C-h' prefix map."
  (let ((map (make-sparse-keymap)))
    (map-keymap
     (lambda (event binding)
       (let ((modifiers (event-modifiers event))
             (basic (event-basic-type event)))
         (when (and (characterp event)
                    (characterp basic)
                    (<= ?\s basic)
                    (<= basic ?~)
                    (or (null modifiers)
                        (equal modifiers '(shift)))
                    (not (keymapp binding)))
           (define-key map (vector event)
             (list 'menu-item
                   (ri--help-prefix-label binding)
                   binding)))))
     (ri--help-prefix-map-for 'help-command))
    map))

(defun ri--show-help-prefix ()
  "Show printable bindings from Emacs' default C-h help map."
  (keymap-legend-show
   "C-h Help" (ri--help-prefix-legend-map) '(:title "C-h Help")))

(defun ri--help-prefix-filter (binding)
  "Show the C-h legend and overlay the initial prefix BINDING.
Only the initial one-event `C-h' lookup is real prefix input; later
keymap lookups during that command must keep their resolved binding."
  (if (or (eq binding 'help-command)
          (eq binding (symbol-function 'help-command)))
      (let ((map (ri--help-prefix-map-for binding)))
        (when (and (not ri--help-prefix-active)
                   (= (length (this-command-keys-vector)) 1))
          (ri--show-help-prefix)
          (setq ri--help-prefix-active t)
          (add-hook 'pre-command-hook #'ri--exit-help-prefix nil t))
        map)
    binding))


;;;; Semantic regions auto-enable

(defun ri--maybe-enable-semantic-regions ()
  "Enable RI-backed semantic highlighting in text-editing buffers."
  (unless (or (minibufferp)
              (derived-mode-p 'special-mode))
    (setq-local sr-highlight-bounds-function #'ri--highlight-bounds)
    (sr-mode 1)
    (ri-pairs-enable-buffer)
    (ri--mode-line-enable)))

;;;; Global setup

;;;###autoload
(defun ri-enable ()
  (interactive)
  (setq status-frame-height 6)
  (modal-cursor-mode 1)
  (ri-tabs-mode 1)
  (mini-modal-setup)
  (kkp-chord-mode 1)
  (ri-chord-setup)
  (global-kkp-mode 1)
  (add-hook 'kkp-chord-after-release-hook #'ri--restore-message-after-release)
  (define-key mini-modal-map
              (kbd "C-h")
              '(menu-item "Help" help-command :filter ri--help-prefix-filter))
  (define-key mini-modal-map "h" #'ri-enter-insert-left)
  (define-key mini-modal-map ";" #'ri-enter-insert-right)
  (define-key mini-modal-map "F" #'ri-transform-menu)
  (define-key mini-modal-map "," #'ri-surround-menu)
  (define-key mini-modal-map (kbd "SPC") #'ri-space-menu)
  (let (to-remove)
    (dolist (entry minor-mode-alist)
      (when (equal entry '(t (:eval (if mini-modal-mode " NORM" " INST"))))
        (push entry to-remove)))
    (dolist (entry to-remove)
      (setq minor-mode-alist (delq entry minor-mode-alist))))
  (push '(t (:eval (ri--mode-line-text))) minor-mode-alist)
  (define-key mini-modal-map "/" #'ri-swap-cursor)
  (define-key mini-modal-map "?" #'ri--show-help)
  ;; `mini-modal-map' suppresses ordinary self-insert in NORM.  Give the
  ;; primary click an explicit RI path without taking over drags, wheels,
  ;; mode-line clicks, or other mouse gestures.
  (ri-mouse-setup)
  ;; Semantic regions setup.  Unit highlighting belongs to NORM only; in
  ;; INST the insertion bar is the sole cursor indication.
  (setq sr-highlight-predicate
        (lambda () (bound-and-true-p mini-modal-mode)))
  (add-hook 'find-file-hook #'ri--maybe-enable-semantic-regions)
  (add-hook 'after-change-major-mode-hook #'ri-pairs-enable-buffer)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (ri--maybe-enable-semantic-regions)))
  (define-key mini-modal-map "j" #'ri-extend-nav-left)
  (define-key mini-modal-map "l" #'ri-extend-nav-right)
  (define-key mini-modal-map "i" #'ri-extend-nav-up)
  (define-key mini-modal-map "I" #'ri-join-lines)
  (define-key mini-modal-map "J" #'ri-dedent)
  (define-key mini-modal-map "L" #'ri-indent)
  (define-key mini-modal-map "k" #'ri-extend-nav-down)
  (define-key mini-modal-map "u" #'ri-extend-nav-prev)
  (define-key mini-modal-map "o" #'ri-extend-nav-next)
  (define-key mini-modal-map "y" #'ri-extend-nav-first)
  (define-key mini-modal-map "p" #'ri-extend-nav-last)
  (define-key mini-modal-map "." #'ri-parent-line)
  (define-key mini-modal-map "a" #'ri--press-layer)
  (define-key mini-modal-map "A" #'ri-extend-set-line-star-mode)
  (define-key mini-modal-map "W" #'ri-extend-set-character-mode)
  (define-key mini-modal-map "E" #'ri-extend-set-paragraph-mode)
  (define-key mini-modal-map "s" #'ri--press-layer)
  (define-key mini-modal-map "S" #'ri-extend-set-word-star-mode)
  (define-key mini-modal-map (kbd "M-s") #'ri-extend-set-word-plus-mode)
  (define-key mini-modal-map "w" #'ri-extend-set-subword-mode)
  (define-key mini-modal-map "d" #'ri-set-node-mode)
  (define-key mini-modal-map "f" #'ri-toggle-extend)
  (define-key mini-modal-map "Z" #'ri-smart-redo)
  (define-key mini-modal-map (kbd "<return>") #'save-buffer)
  (define-key mini-modal-map (kbd "<escape>") #'ri-extend-escape)
  )

(provide 'ri)
;;; ri.el ends here
