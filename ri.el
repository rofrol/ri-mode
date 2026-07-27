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
      (dolist (sub '("mini-modal"))
        (add-to-list 'load-path (expand-file-name sub dir))))))

(require 'mini-modal)

;; Customized by `ri-enable'.
(defun my-status-frame-show ()
  (interactive)
  (status-frame-show
   "Status frame

Line 2
Line 3
Line 4
Line 5
Line 6"))

(defun my-status-frame-hide-before-next-key ()
  "Hide status frame before processing the next key."
  (when (and (boundp 'status-frame--frame)
             status-frame--frame
             (frame-visible-p status-frame--frame))
    (status-frame-hide)
    (remove-hook 'pre-command-hook
                 #'my-status-frame-hide-before-next-key)))

(defun my-status-frame-space ()
  (interactive)
  (my-status-frame-show)
  (add-hook 'pre-command-hook
            #'my-status-frame-hide-before-next-key))

(global-set-key (kbd "SPC") #'my-status-frame-space)

;;;###autoload
(defun ri-enable ()
  "Enable `ri' globally."
  (interactive)
)

(provide 'ri)

