;;; mini-modal.el --- Minimal normal/insert modal editing -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, editing
;; URL: https://github.com/yourname/mini-modal

;;; Commentary:

;; Minimal modal editing:
;;
;;   NORM:
;;     h   -> enter insert mode
;;
;;   INST:
;;     ESC -> return to normal mode
;;
;; The mode line displays NORM or INST.

;;; Code:

(defvar-local mini-modal-state 'normal)

(defvar mini-modal-normal-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "h") #'mini-modal-insert)
    map))

(defvar mini-modal-insert-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<escape>") #'mini-modal-normal)
    map))

(defun mini-modal--update-map ()
  (setq minor-mode-overriding-map-alist
        `((mini-modal-mode
           . ,(if (eq mini-modal-state 'normal)
                  mini-modal-normal-map
                mini-modal-insert-map))))
  (force-mode-line-update))

(defun mini-modal-normal ()
  "Enter normal state."
  (interactive)
  (setq mini-modal-state 'normal)
  (mini-modal--update-map))

(defun mini-modal-insert ()
  "Enter insert state."
  (interactive)
  (setq mini-modal-state 'insert)
  (mini-modal--update-map))

(defun mini-modal--lighter ()
  (if (eq mini-modal-state 'normal)
      " NORM"
    " INST"))

;;;###autoload
(define-minor-mode mini-modal-mode
  "Minimal normal/insert modal editing mode."
  :lighter (:eval (mini-modal--lighter))
  :keymap nil
  (if mini-modal-mode
      (mini-modal-normal)
    (setq minor-mode-overriding-map-alist
          (assq-delete-all 'mini-modal-mode
                           minor-mode-overriding-map-alist))
    (force-mode-line-update)))

(provide 'mini-modal)

;;; mini-modal.el ends here