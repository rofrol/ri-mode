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
      (dolist (sub '("mini-modal" "kkp-chord" "status-frame"))
        (add-to-list 'load-path (expand-file-name sub dir))))))

(require 'mini-modal)
(require 'kkp-chord)
(require 'status-frame)

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

;; ── ESC handler shared by both menus ────────────────────────────────────

(defun ri--exit-menu ()
  "Exit the current menu, hide the frame, and return to NORM mode."
  (interactive)
  (ri--hide-frame)
  (set-transient-map nil)
  (mini-modal-normal))

;; ── Keymaps ─────────────────────────────────────────────────────────────

(defvar ri--space-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" #'ri-editor-menu)
    (define-key map "v" #'ri-space-paste)
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Keymap for the Space menu.")

(defvar ri--editor-layer-map
  (let ((map (make-sparse-keymap)))
    (define-key map "v" #'ri--quit-with-check)
    (define-key map (kbd "<escape>") #'ri--exit-menu)
    map)
  "Keymap for the Editor submenu.")

;; ── Commands ────────────────────────────────────────────────────────────

(defun ri-space-menu ()
  "Show the Space menu via a transient keymap."
  (interactive)
  (ri--show-frame "j - Editor, v - Paste")
  (set-transient-map ri--space-layer-map t #'ri--hide-frame))

(defun ri-editor-menu ()
  "Enter the Editor submenu."
  (interactive)
  (ri--update-frame "v - Quit")
  (set-transient-map ri--editor-layer-map t #'ri--hide-frame)
  ;; The old transient-map cleanup may have hidden the frame; re-show.
  (ri--show-frame "v - Quit"))

(defun ri-space-paste ()
  "Paste and exit the Space menu."
  (interactive)
  (ri--hide-frame)
  (set-transient-map nil)
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
Unsaved files are reported in the echo area."
  (interactive)
  (let ((unsaved (ri--unsaved-files)))
    (if unsaved
        (message "Cannot quit with unsaved files: %s"
                 (format "[%s]" (mapconcat (lambda (f) (format "\"%s\"" f))
                                            unsaved ", ")))
      (ri--hide-frame)
      (set-transient-map nil)
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
    (define-key map "h" #'ri-paste-before)
    (define-key map ";" #'ri-paste-after)
    map)
  "Keymap for the paste momentary layer (v held).")

(defun ri--chord-when-p ()
  "Return non-nil when a KKP chord should be active.
Active only in NORM mode and when no transient menu is open."
  (and (bound-and-true-p mini-modal-mode)
       (null overriding-terminal-local-map)))

(defun ri-chord-setup ()
  "Register KKP chords for momentary layers."
  (kkp-chord-define ?v
    :tap #'yank
    :when #'ri--chord-when-p
    :on-press (lambda () (ri--show-frame "h - Paste <, ; - Paste >"))
    :on-release #'ri--hide-frame
    :map ri--paste-layer-map))

;; Keybindings and hooks are registered by `ri-enable'.

;;;###autoload
(defun ri-enable ()
  "Enable `ri' globally."
  (interactive)
  (setq status-frame-height 6)
  (ri-chord-setup)
  (define-key mini-modal-map (kbd "RET") 'undefined)
  (define-key mini-modal-map "v" #'ri-space-paste)
  (define-key mini-modal-map (kbd "SPC") #'ri-space-menu))

(provide 'ri)

