;;; dev.el --- Local development setup for ri-mode -*- lexical-binding: t; -*-

(let ((root (file-name-directory
             (or load-file-name buffer-file-name))))
  (add-to-list 'load-path root)
  (dolist (package '("mini-modal"
                     "kkp-chord"
                     "keymap-legend"
                     "status-frame"
                     "semantic-regions"))
    (add-to-list 'load-path
                 (expand-file-name package root))))

(require 'ri)

(provide 'dev)
;;; dev.el ends here
