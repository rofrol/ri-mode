;;; ki-tabs.el --- Ki-style tabs for open files -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: convenience, files, tabs
;; URL: https://github.com/rofrol/ki-tabs

;;; Commentary:

;; `ki-tabs-mode' displays every live file-visiting buffer in a tab line
;; above file windows.  Tabs stay in path order, use the shortest unique
;; path suffix as their label, and follow Ki's clean/modified markers.
;; Selecting a tab switches the current window to its buffer; closing a tab
;; kills that buffer.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tab-line)

(defgroup ki-tabs nil
  "Ki-style tabs for open file buffers."
  :group 'convenience
  :prefix "ki-tabs-")

(defcustom ki-tabs-clean-marker "[-]"
  "Marker shown before the name of an unmodified file."
  :type 'string
  :group 'ki-tabs)

(defcustom ki-tabs-modified-marker "[÷]"
  "Marker shown before the name of a modified file."
  :type 'string
  :group 'ki-tabs)

(defface ki-tabs-tab
  '((t :inherit tab-line-tab-inactive :box nil))
  "Face used for an inactive file tab."
  :group 'ki-tabs)

(defface ki-tabs-current-tab
  '((t :inherit tab-line-tab-current :weight bold :box nil))
  "Face used for the current tab in the selected window."
  :group 'ki-tabs)

(defface ki-tabs-current-tab-inactive-window
  '((t :inherit tab-line-tab :weight bold :box nil))
  "Face used for the current tab in an unselected window."
  :group 'ki-tabs)

(defface ki-tabs-highlight
  '((t :inherit tab-line-highlight :box nil))
  "Face used when the pointer is over a file tab."
  :group 'ki-tabs)

(defconst ki-tabs--managed-variables
  '(tab-line-format
    tab-line-tabs-function
    tab-line-tab-name-function
    tab-line-tab-name-format-function
    tab-line-cache-key-function
    tab-line-new-button-show
    tab-line-close-button-show
    tab-line-close-tab-function
    tab-line-tab-face-functions
    tab-line-separator
    tab-line-auto-hscroll)
  "Buffer-local tab-line variables managed by `ki-tabs-mode'.")

(defvar ki-tabs-mode nil
  "Non-nil when Ki tabs are enabled globally.")

(defvar-local ki-tabs--saved-state nil
  "Tab-line state saved before `ki-tabs-mode' configured this buffer.")

(defvar-local ki-tabs--tab-line-was-active nil
  "Whether `tab-line-mode' was active before Ki tabs were installed.")

(defun ki-tabs--file-buffer-p (buffer)
  "Return non-nil when BUFFER is a live visible file buffer."
  (and (buffer-live-p buffer)
       (buffer-file-name buffer)
       (not (string-prefix-p " " (buffer-name buffer)))))

(defun ki-tabs--buffer-less-p (left right)
  "Return non-nil when file buffer LEFT sorts before RIGHT."
  (let ((left-file (buffer-file-name left))
        (right-file (buffer-file-name right)))
    (if (equal left-file right-file)
        (string-lessp (buffer-name left) (buffer-name right))
      (string-lessp left-file right-file))))

(defun ki-tabs--buffer-list ()
  "Return all open file buffers in stable path order."
  (sort (seq-filter #'ki-tabs--file-buffer-p (buffer-list))
        #'ki-tabs--buffer-less-p))

(defun ki-tabs--path-parts (file)
  "Return the non-empty path components of FILE."
  (seq-remove #'string-empty-p
              (file-name-split (abbreviate-file-name file))))

(defun ki-tabs--same-suffix-p (left right width)
  "Return non-nil when LEFT and RIGHT share a WIDTH-component suffix."
  (equal (last left width) (last right width)))

(defun ki-tabs--tab-name (buffer buffers)
  "Return BUFFER's shortest unique file label among BUFFERS."
  (let* ((file (buffer-file-name buffer))
         (base (file-name-nondirectory file))
         (same-base
          (seq-filter
           (lambda (other)
             (and (not (eq other buffer))
                  (equal base
                         (file-name-nondirectory
                          (buffer-file-name other)))))
           buffers)))
    (cond
     ((null same-base) base)
     ((seq-some (lambda (other)
                  (equal file (buffer-file-name other)))
                same-base)
      (buffer-name buffer))
     (t
      (let* ((parts (ki-tabs--path-parts file))
             (other-parts
              (mapcar (lambda (other)
                        (ki-tabs--path-parts (buffer-file-name other)))
                      same-base))
             (width 1)
             (limit (length parts)))
        (while (and (< width limit)
                    (seq-some
                     (lambda (candidate)
                       (ki-tabs--same-suffix-p parts candidate width))
                     other-parts))
          (setq width (1+ width)))
        (string-join (last parts width) "/"))))))

(defun ki-tabs--tab-face (selected)
  "Return the appropriate tab face for SELECTED state."
  (cond
   ((not selected) 'ki-tabs-tab)
   ((mode-line-window-selected-p) 'ki-tabs-current-tab)
   (t 'ki-tabs-current-tab-inactive-window)))

(defun ki-tabs--format-tab (buffer buffers)
  "Format BUFFER as a Ki-style tab among BUFFERS."
  (let* ((selected (eq buffer (window-buffer)))
         (marker (if (buffer-modified-p buffer)
                     ki-tabs-modified-marker
                   ki-tabs-clean-marker))
         (name (funcall tab-line-tab-name-function buffer buffers))
         (label (string-replace "%" "%%"
                                (format " %s %s " marker name)))
         (file (abbreviate-file-name (buffer-file-name buffer))))
    (apply #'propertize label
           `(face ,(ki-tabs--tab-face selected)
             tab ,buffer
             ,@(when selected '(selected t))
             keymap ,tab-line-tab-map
             mouse-face ki-tabs-highlight
             help-echo ,(if selected
                            (format "Current file: %s" file)
                          (format "Switch to %s" file))
             follow-link ignore
             rear-nonsticky nil))))

(defun ki-tabs--cache-key (tabs)
  "Return a tab-line cache key for TABS and their file state."
  (append
   (tab-line-cache-key-default tabs)
   (list ki-tabs-clean-marker
         ki-tabs-modified-marker
         (mapcar (lambda (buffer)
                   (list (buffer-name buffer)
                         (buffer-file-name buffer)
                         (buffer-modified-p buffer)))
                 tabs))))

(defun ki-tabs--capture-state ()
  "Capture the tab-line variables managed in the current buffer."
  (mapcar (lambda (variable)
            (list variable
                  (local-variable-p variable)
                  (symbol-value variable)))
          ki-tabs--managed-variables))

(defun ki-tabs--set-local-configuration ()
  "Install the Ki tab-line configuration in the current buffer."
  (setq-local tab-line-format '(:eval (tab-line-format))
              tab-line-tabs-function #'ki-tabs--buffer-list
              tab-line-tab-name-function #'ki-tabs--tab-name
              tab-line-tab-name-format-function #'ki-tabs--format-tab
              tab-line-cache-key-function #'ki-tabs--cache-key
              tab-line-new-button-show nil
              tab-line-close-button-show nil
              tab-line-close-tab-function 'kill-buffer
              tab-line-tab-face-functions nil
              tab-line-separator ""
              tab-line-auto-hscroll t))

(defun ki-tabs--install ()
  "Install Ki tabs in the current file buffer."
  (when (ki-tabs--file-buffer-p (current-buffer))
    (unless ki-tabs--saved-state
      (setq ki-tabs--saved-state (ki-tabs--capture-state)
            ki-tabs--tab-line-was-active tab-line-mode))
    (unless tab-line-mode
      (tab-line-mode 1))
    (ki-tabs--set-local-configuration)))

(defun ki-tabs--restore ()
  "Restore tab-line state previously saved in the current buffer."
  (when ki-tabs--saved-state
    (let ((saved-state ki-tabs--saved-state)
          (was-active ki-tabs--tab-line-was-active))
      (if was-active
          (unless tab-line-mode
            (tab-line-mode 1))
        (when tab-line-mode
          (tab-line-mode -1)))
      (dolist (entry saved-state)
        (pcase-let ((`(,variable ,was-local ,value) entry))
          (if was-local
              (set (make-local-variable variable) value)
            (kill-local-variable variable))))
      (kill-local-variable 'ki-tabs--saved-state)
      (kill-local-variable 'ki-tabs--tab-line-was-active))))

(defun ki-tabs--refresh (&rest _ignored)
  "Invalidate every Ki tab line when `ki-tabs-mode' is active."
  (when ki-tabs-mode
    (tab-line-force-update t)))

(defun ki-tabs--sync-current-buffer ()
  "Install or remove Ki tabs after the current buffer changes role."
  (when ki-tabs-mode
    (if (ki-tabs--file-buffer-p (current-buffer))
        (ki-tabs--install)
      (ki-tabs--restore))
    (ki-tabs--refresh)))

(defun ki-tabs--enable ()
  "Install Ki tabs and the hooks that keep them current."
  (add-hook 'find-file-hook #'ki-tabs--sync-current-buffer)
  (add-hook 'after-set-visited-file-name-hook #'ki-tabs--sync-current-buffer)
  (add-hook 'after-change-major-mode-hook #'ki-tabs--sync-current-buffer)
  (add-hook 'kill-buffer-hook #'ki-tabs--refresh)
  (add-hook 'first-change-hook #'ki-tabs--refresh)
  (add-hook 'after-save-hook #'ki-tabs--refresh)
  (add-hook 'after-revert-hook #'ki-tabs--refresh)
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ki-tabs--install))))
  (ki-tabs--refresh))

(defun ki-tabs--disable ()
  "Remove Ki tabs and restore every buffer's previous tab-line state."
  (remove-hook 'find-file-hook #'ki-tabs--sync-current-buffer)
  (remove-hook 'after-set-visited-file-name-hook #'ki-tabs--sync-current-buffer)
  (remove-hook 'after-change-major-mode-hook #'ki-tabs--sync-current-buffer)
  (remove-hook 'kill-buffer-hook #'ki-tabs--refresh)
  (remove-hook 'first-change-hook #'ki-tabs--refresh)
  (remove-hook 'after-save-hook #'ki-tabs--refresh)
  (remove-hook 'after-revert-hook #'ki-tabs--refresh)
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ki-tabs--restore))))
  (tab-line-force-update t))

;;;###autoload
(define-minor-mode ki-tabs-mode
  "Display Ki-style tabs for all open file buffers.

The global mode adds a tab line to every file-visiting buffer.  Tabs are
sorted by path, duplicate basenames receive the shortest unique path
suffix, and modified files use `ki-tabs-modified-marker'."
  :global t
  :group 'ki-tabs
  (if ki-tabs-mode
      (ki-tabs--enable)
    (ki-tabs--disable)))

(provide 'ki-tabs)

;;; ki-tabs.el ends here
