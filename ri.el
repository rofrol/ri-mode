;;; ri.el --- Ri modal editing for Kitty terminal -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;;
;; Author: Roman Frołow
;; Maintainer: Roman Frołow
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (mini-modal "0.1") (kkp "0.1") (keymap-legend "0.1") (status-frame "0.1"))
;; Keywords: convenience, editing, terminals
;; URL: https://github.com/rofrol/ri-mode
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Ri-mode provides modal editing for the Kitty terminal via mini-modal.
;; Load and enable with:
;;
;;   (use-package ri
;;     :load-path "~/personal_projects/emacs/ri-mode"
;;     :config
;;     (ri-enable))

;;; Code:

(eval-and-compile
  (let ((dir (file-name-directory (or load-file-name buffer-file-name))))
    (when dir
      (dolist (sub '("mini-modal" "kkp-chord" "keymap-legend" "status-frame" "semantic-regions"))
        (add-to-list 'load-path (expand-file-name sub dir))))))

(require 'mini-modal)
(require 'kkp-chord)
(require 'keymap-legend)
(require 'status-frame)
(require 'semantic-regions)

;; Customized by `ri-enable'.
;; ---------------------------------------------------------------------------
;; Space menu
;; ---------------------------------------------------------------------------

(defun ri--show-frame (text)
  "Show the status frame with TEXT."
  (status-frame-show text))

(defun ri--update-frame (text)
  "Update the status frame text to TEXT."
  (status-frame-set-text text))

(defun ri--hide-frame ()
  "Hide the status frame."
  (status-frame-hide))

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

;; ── Keymaps ─────────────────────────────────────────────────────────────
(defvar ri--space-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" '(menu-item "Editor" ri-editor-menu))
    (define-key map "v" '(menu-item "Paste" ri-space-paste))
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Keymap for the Space menu.")

(defvar ri--editor-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "v" '(menu-item "Quit" ri--quit-with-check))
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Keymap for the Editor submenu.")
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
(defun ri-space-paste ()
  "Paste and exit the Space menu."
  (interactive)
  (set-transient-map nil)
  (ri--close-menu)
  (yank))

;; ── Quit with unsaved-file check ────────────────────────────────────────

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

;; ── v: paste momentary layer (tap-hold via KKP chord) ──────────────────

(defun ri-paste-before ()
  "Paste (yank) before the cursor."
  (interactive)
  (yank))

(defun ri-paste-after ()
  "Paste (yank) after the cursor."
  (interactive)
  (unless (eobp) (forward-char))
  (yank))

(defvar ri--paste-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "h" '(menu-item "< Paste" ri-paste-before))
    (define-key map ";" '(menu-item "Paste >" ri-paste-after))
    map)
  "Keymap for the paste momentary layer (v held).")

(defun ri--chord-when-p ()
  "Return non-nil when a KKP chord should be active.
Active only in NORM mode and when no transient menu is open."
  (and (bound-and-true-p mini-modal-mode)
       (null ri--menu-state)))

(defun ri-chord-setup ()
  "Register KKP chords for momentary layers."
  (kkp-chord-define ?v
    :tap #'yank
    :when #'ri--chord-when-p
    :on-press (lambda ()
                (keymap-legend-show
                 "Paste" ri--paste-layer-map
                 '(:title "Paste" :release "Paste")))
    :on-release #'keymap-legend-hide
    :map ri--paste-layer-map))
;; Keybindings and hooks are registered by `ri-enable'.
;; ── Mode line ────────────────────────────────────────────────────────────

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
  "Return the mode-line text with mode, submode, and help hint."
  (if (bound-and-true-p mini-modal-mode)
      (format " NORM[%s] [Press ? for help]" (ri--submode-name))
    " INST"))

;; Replaced by `ri-enable' — see `ri-enable' for the lighter setup.

;; ── Help keymap legend for NORM mode (?) ─────────────────────────────────

(defvar ri--normal-help-map
  (let ((map (make-sparse-keymap)))
    (define-key map "h" '(menu-item "Insert" mini-modal-insert))
    (define-key map "j" '(menu-item "← Left" sr-nav-left))
    (define-key map "l" '(menu-item "→ Right" sr-nav-right))
    (define-key map "i" '(menu-item "↑ Up" sr-nav-up))
    (define-key map "k" '(menu-item "↓ Down" sr-nav-down))
    (define-key map "u" '(menu-item "Prev" sr-nav-prev))
    (define-key map "o" '(menu-item "Next" sr-nav-next))
    (define-key map "y" '(menu-item "First" sr-nav-first))
    (define-key map "p" '(menu-item "Last" sr-nav-last))
    (define-key map "a" '(menu-item "LINE" sr-set-line-mode))
    (define-key map "A" '(menu-item "LINE*" sr-set-line-star-mode))
    (define-key map "W" '(menu-item "CHAR" sr-set-character-mode))
    (define-key map "v" '(menu-item "Paste" ri-space-paste))
    (define-key map (kbd "SPC") '(menu-item "Menu" ri-space-menu))
    (define-key map "?" '(menu-item "Help" ignore))
    (define-key map (kbd "<escape>") '(menu-item "Close" ignore))
    map)
  "Keymap documenting NORM mode bindings for the help legend.")

(defun ri--show-help ()
  "Show the NORM mode keymap legend, dismissed on next key press."
  (interactive)
  (keymap-legend-show "NORM" ri--normal-help-map '(:title "Normal Mode"))
  (set-transient-map (make-sparse-keymap) nil #'keymap-legend-hide))

(defun sr--maybe-enable ()
  "Enable `sr-mode' in text-editing buffers, skipping minibuffer and special-mode."
  (unless (or (minibufferp)
              (derived-mode-p 'special-mode))
    (sr-mode 1)))
;;;###autoload
(defun ri-enable ()
  "Enable `ri' globally."
  (interactive)
  (setq status-frame-height 6)
  (mini-modal-setup)
  (kkp-chord-mode 1)
  (global-kkp-mode 1)
  (add-hook 'kkp-chord-after-release-hook #'ri--restore-message-after-release)
  (ri-chord-setup)
  (define-key mini-modal-map (kbd "RET") 'undefined)
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
  ;; Semantic regions setup.
  (add-hook 'after-change-major-mode #'sr--maybe-enable)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (sr--maybe-enable)))
  (define-key mini-modal-map "j" #'sr-nav-left)
  (define-key mini-modal-map "l" #'sr-nav-right)
  (define-key mini-modal-map "i" #'sr-nav-up)
  (define-key mini-modal-map "k" #'sr-nav-down)
  (define-key mini-modal-map "u" #'sr-nav-prev)
  (define-key mini-modal-map "o" #'sr-nav-next)
  (define-key mini-modal-map "y" #'sr-nav-first)
  (define-key mini-modal-map "p" #'sr-nav-last)
  (define-key mini-modal-map "a" #'sr-set-line-mode)
  (define-key mini-modal-map "A" #'sr-set-line-star-mode)
  (define-key mini-modal-map "W" #'sr-set-character-mode)
  (define-key mini-modal-map (kbd "<up>") 'undefined)
  (define-key mini-modal-map (kbd "<down>") 'undefined)
  (define-key mini-modal-map (kbd "<left>") 'undefined)
  (define-key mini-modal-map (kbd "<right>") 'undefined))

(provide 'ri)
