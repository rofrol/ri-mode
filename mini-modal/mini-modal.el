;;; mini-modal.el --- Minimal normal/insert modal editing -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, editing
;; URL: https://github.com/yourname/mini-modal

;;; Commentary:

;; Minimal modal editing:
;;
;;   NORM (mini-modal-mode on):
;;     h   -> enter insert mode
;;     ESC -> no-op (already normal)
;;
;;   INST (mini-modal-mode off):
;;     ESC -> return to normal mode
;;
;; The mode line displays NORM or INST.

;;; Code:

(defvar mini-modal-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "h") #'mini-modal-insert)
    map)
  "Keymap for `mini-modal-mode' (normal mode).
Self-insert is suppressed; only explicitly bound keys work.")

;;;###autoload
(define-minor-mode mini-modal-mode
  "Minimal normal/insert modal editing mode.

When enabled (NORM): self-insert is suppressed, `h' enters insert mode.
When disabled (INST): normal editing, `ESC' returns to normal mode."
  :lighter (:eval (if mini-modal-mode " NORM" " INST"))
  :keymap mini-modal-map
  :group 'mini-modal
  (force-mode-line-update))

(defun mini-modal--turn-on ()
  "Enable `mini-modal-mode' in buffers meant for text editing.
Skips the minibuffer and buffers derived from `special-mode'
(help, info, dired, customize, package lists, etc.)."
  (unless (or (minibufferp)
              (derived-mode-p 'special-mode))
    (mini-modal-mode 1)))

;;;###autoload
(define-globalized-minor-mode mini-modal-global-mode
  mini-modal-mode
  mini-modal--turn-on
  :group 'mini-modal)

(defun mini-modal-normal ()
  "Enter normal state (enable `mini-modal-mode' in current buffer)."
  (interactive)
  (mini-modal-mode 1))

(defun mini-modal-insert ()
  "Enter insert state (disable `mini-modal-mode' in current buffer)."
  (interactive)
  (mini-modal-mode -1))

;;;###autoload
(defun mini-modal-setup ()
  "Configure global ESC binding and enable `mini-modal-global-mode'.
Call this once during init."
  (keymap-global-set "<escape>" #'mini-modal-normal)
  (mini-modal-global-mode 1))

(provide 'mini-modal)

;;; mini-modal.el ends here
