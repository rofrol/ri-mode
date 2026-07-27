;;; ri.el --- Ri modal editing via the Kitty Keyboard Protocol -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;;
;; Author: Roman Frołow
;; Maintainer: Roman Frołow
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (mini-modal "0.1") (kkp-chord "0.1") (keymap-legend "0.1") (status-frame "0.1") (semantic-regions "0.1") (modal-cursor "0.1"))
;; Keywords: convenience, editing, terminals
;; URL: https://github.com/rofrol/ri-mode
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Ri-mode provides modal editing for terminals supporting the Kitty Keyboard Protocol (Kitty, Ghostty, WezTerm).
;;
;; For local development with vendored dependencies, load via dev.el:
;;
;;     emacs -Q -l ./dev.el
;;
;; Or from your Emacs config:
;;
;;     (load "~/personal_projects/emacs/ri-mode/dev.el")

;;; Code:

;;;; Dependencies

(require 'mini-modal)
(require 'kkp-chord)
(require 'keymap-legend)
(require 'status-frame)
(require 'semantic-regions)
(require 'modal-cursor)
(require 'ri-extend)
(require 'ri-duplicate)
(require 'cl-lib)

;;;; Status frame

(defun ri--show-frame (text)
  "Show the status frame with TEXT."
  (status-frame-show text))

(defun ri--update-frame (text)
  "Update the status frame text to TEXT."
  (status-frame-set-text text))

(defun ri--hide-frame ()
  "Hide the status frame."
  (status-frame-hide))

;;;; Menu state

(defvar ri--menu-state nil
  "Current RI menu, or nil when no menu is active.")

(defvar ri--restore-message-after-release nil
  "Echo-area message to restore once after the next Kitty key release.")

(defun ri--restore-message-after-release ()
  "Restore a pending RI message after a swallowed Kitty key release."
  (when ri--restore-message-after-release
    (let ((text ri--restore-message-after-release))
      (setq ri--restore-message-after-release nil)
      (message "%s" text))))

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
    (define-key map "v" '(menu-item "≡ Paste" ri-space-paste))
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

;;;; Menu commands

(defun ri-space-menu ()
  "Show the Space menu via a transient keymap."
  (interactive)
  (setq ri--menu-state 'space)
  (keymap-legend-show "Space" ri--space-layer-map '(:title "Space"))
  (set-transient-map
   ri--space-layer-map t
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

(defun ri--finish-edit-command ()
  "Leave Extend after an edit command and refresh RI UI state."
  (ri--exit-extend)
  (ri--update-highlight)
  (force-mode-line-update))

(defun ri-space-paste ()
  "Paste, leave Extend, and exit the Space menu."
  (interactive)
  (set-transient-map nil)
  (ri--close-menu)
  (yank)
  (ri--finish-edit-command))

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
            (setq ri--restore-message-after-release text)
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

(defun ri-paste ()
  "Paste (yank) and leave Extend."
  (interactive)
  (yank)
  (ri--finish-edit-command))

(defun ri-paste-before ()
  "Paste (yank) before the cursor and leave Extend."
  (interactive)
  (yank)
  (ri--finish-edit-command))

(defun ri-paste-after ()
  "Paste (yank) after the cursor and leave Extend."
  (interactive)
  (unless (eobp) (forward-char))
  (yank)
  (ri--finish-edit-command))

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

(defvar ri--paste-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "h" '(menu-item "< Paste" ri-paste-before))
    (define-key map ";" '(menu-item "Paste >" ri-paste-after))
    map)
  "Keymap for the paste momentary layer (v held).")

;;;; Layer specs (single source of truth for labels and icons)

(defconst ri--layer-specs
  (list
   (list :key ?c
         :label "Copy/≡ Dup"
         :tap #'ri-copy-unit
         :map ri--copy-layer-map
         :release "Copy")
   (list :key ?v
         :label "≡ Paste"
         :tap #'ri-paste
         :map ri--paste-layer-map
         :release "Paste"))
  "Momentary layer specifications.
:key     -- KKP keycode for the chord modifier.
:label   -- Display label with icon (used in menus and legend titles).
:tap     -- Command called on tap (no sub-key pressed).
:map     -- Keymap for the momentary layer.
:release -- Label shown on release, or nil.")

(defun ri--layer-spec (keycode)
  "Return the layer spec for KEYCODE, or nil."
  (cl-find keycode ri--layer-specs
           :key (lambda (s) (plist-get s :key))
           :test #'eql))

(defun ri--chord-when-p ()
  "Return non-nil when a KKP chord should be active.
Active only in NORM mode and when no transient menu is open."
  (and (bound-and-true-p mini-modal-mode)
       (null ri--menu-state)))

(defun ri-chord-setup ()
  "Register KKP chords for momentary layers from `ri--layer-specs'."
  (dolist (spec ri--layer-specs)
    (let ((key (plist-get spec :key))
          (tap (plist-get spec :tap))
          (map (plist-get spec :map))
          (label (plist-get spec :label))
          (release (plist-get spec :release)))
      (kkp-chord-define key
        :tap tap
        :when #'ri--chord-when-p
        :on-press (lambda ()
                    (ri--hide-frame)
                    (keymap-legend-show label map
                      (list :title label :release release)))
        :on-release #'keymap-legend-hide
        :map map))))

;;;; Mode line

(defun ri--submode-name ()
  "Return the human-readable name for the current `sr-submode'."
  (if (boundp 'sr-submode)
      (pcase sr-submode
        ('line "LINE")
        ('line-star "LINE*")
        ('char "CHAR")
        ('word "WORD")
        ('word-plus "WORD+")
        ('word-star "WORD*")
        ('subword "SUBWORD")
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
    (define-key map "u" '(menu-item "<" ri-extend-nav-prev))
    (define-key map "o" '(menu-item ">" ri-extend-nav-next))
    (define-key map "y" '(menu-item "|<" ri-extend-nav-first))
    (define-key map "p" '(menu-item ">|" ri-extend-nav-last))
    (define-key map "a" '(menu-item "LINE" ri-extend-set-line-mode))
    (define-key map "A" '(menu-item "LINE*" ri-extend-set-line-star-mode))
    (define-key map "W" '(menu-item "CHAR" ri-extend-set-character-mode))
    (define-key map "s" '(menu-item "WORD" ri-extend-set-word-mode))
    (define-key map "S" '(menu-item "WORD*" ri-extend-set-word-star-mode))
    (define-key map (kbd "M-s") '(menu-item "WORD+" ri-extend-set-word-plus-mode))
    (define-key map "w" '(menu-item "SUBWORD" ri-extend-set-subword-mode))
    (define-key map "c" '(menu-item "Copy/≡ Dup" ri-copy-unit))
    (define-key map "v" '(menu-item "≡ Paste" ri-space-paste))
    (define-key map "f" '(menu-item "Extend" ri-toggle-extend))
    (define-key map (kbd "SPC") '(menu-item "Space" ri-space-menu))
    (define-key map "?" '(menu-item "Help" ignore))
    (define-key map (kbd "<escape>") '(menu-item "Close" ignore))
    map)
  "Keymap documenting NORM mode bindings for the help legend.")

(defun ri--show-help ()
  "Show the NORM mode keymap legend, dismissed on next key press."
  (interactive)
  (keymap-legend-show "NORM" ri--normal-help-map '(:title "Normal Mode"))
  (set-transient-map (make-sparse-keymap) nil #'keymap-legend-hide))

;;;; Semantic regions auto-enable

(defun sr--maybe-enable ()
  "Enable `sr-mode' in text-editing buffers, skipping minibuffer and special-mode."
  (unless (or (minibufferp)
              (derived-mode-p 'special-mode))
    (sr-mode 1)
    ;; Run after semantic-regions so Extend can widen its unit overlay.
    (add-hook 'post-command-hook #'ri--update-highlight t t)))

;;;; Global setup

;;;###autoload
(defun ri-enable ()
  "Enable `ri' globally."
  (interactive)
  (setq status-frame-height 6)
  (modal-cursor-mode 1)
  (mini-modal-setup)
  (kkp-chord-mode 1)
  (global-kkp-mode 1)
  (add-hook 'kkp-chord-after-release-hook #'ri--restore-message-after-release)
  (ri-chord-setup)
  (define-key mini-modal-map "h" #'ri-enter-insert-left)
  (define-key mini-modal-map ";" #'ri-enter-insert-right)
  (define-key mini-modal-map "c" #'ri-copy-unit)
  (define-key mini-modal-map "v" #'ri-space-paste)
  (define-key mini-modal-map (kbd "SPC") #'ri-space-menu)
  (let (to-remove)
    (dolist (entry minor-mode-alist)
      (when (equal entry '(t (:eval (if mini-modal-mode " NORM" " INST"))))
        (push entry to-remove)))
    (dolist (entry to-remove)
      (setq minor-mode-alist (delq entry minor-mode-alist))))
  (push '(t (:eval (ri--mode-line-text))) minor-mode-alist)
  (define-key mini-modal-map "?" #'ri--show-help)
  ;; Semantic regions setup.  Unit highlighting belongs to NORM only; in
  ;; INST the insertion bar is the sole cursor indication.
  (setq sr-highlight-predicate
        (lambda () (bound-and-true-p mini-modal-mode)))
  (add-hook 'find-file-hook #'sr--maybe-enable)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (sr--maybe-enable)))
  (define-key mini-modal-map "j" #'ri-extend-nav-left)
  (define-key mini-modal-map "l" #'ri-extend-nav-right)
  (define-key mini-modal-map "i" #'ri-extend-nav-up)
  (define-key mini-modal-map "k" #'ri-extend-nav-down)
  (define-key mini-modal-map "u" #'ri-extend-nav-prev)
  (define-key mini-modal-map "o" #'ri-extend-nav-next)
  (define-key mini-modal-map "y" #'ri-extend-nav-first)
  (define-key mini-modal-map "p" #'ri-extend-nav-last)
  (define-key mini-modal-map "a" #'ri-extend-set-line-mode)
  (define-key mini-modal-map "A" #'ri-extend-set-line-star-mode)
  (define-key mini-modal-map "W" #'ri-extend-set-character-mode)
  (define-key mini-modal-map "s" #'ri-extend-set-word-mode)
  (define-key mini-modal-map "S" #'ri-extend-set-word-star-mode)
  (define-key mini-modal-map (kbd "M-s") #'ri-extend-set-word-plus-mode)
  (define-key mini-modal-map "w" #'ri-extend-set-subword-mode)
  (define-key mini-modal-map "f" #'ri-toggle-extend)
  (define-key mini-modal-map (kbd "<up>") 'undefined)
  (define-key mini-modal-map (kbd "<down>") 'undefined)
  (define-key mini-modal-map (kbd "<left>") 'undefined)
  (define-key mini-modal-map (kbd "<escape>") #'ri-extend-escape)
  (define-key mini-modal-map (kbd "<right>") 'undefined))

(provide 'ri)
;;; ri.el ends here
