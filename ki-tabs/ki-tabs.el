;;; ki-tabs.el --- Ki-style tabs for open files -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: convenience, files, tabs
;; URL: https://github.com/rofrol/ki-tabs

;;; Commentary:

;; `ki-tabs-mode' displays every marked file-visiting buffer in a tab line
;; above file windows and appends the current buffer while it is unmarked.
;; Marked tabs stay in path order, use the shortest unique path suffix as
;; their label, and show Ki's marked/modified state indicators.  Selecting a
;; tab switches the current window to its buffer; closing a tab kills it.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tab-line)

(defgroup ki-tabs nil
  "Ki-style tabs for open file buffers."
  :group 'convenience
  :prefix "ki-tabs-")

(defcustom ki-tabs-unmarked-marker "[ ]"
  "Marker shown before the name of an unmodified, unmarked file."
  :type 'string
  :group 'ki-tabs)

(defcustom ki-tabs-marked-marker "[-]"
  "Marker shown before the name of an unmodified, marked file."
  :type 'string
  :group 'ki-tabs)

(defcustom ki-tabs-unmarked-modified-marker "[:]"
  "Marker shown before the name of a modified, unmarked file."
  :type 'string
  :group 'ki-tabs)

(defcustom ki-tabs-marked-modified-marker "[÷]"
  "Marker shown before the name of a modified, marked file."
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

(defvar-local ki-tabs--marked-p nil
  "Non-nil when the current file buffer is marked as a Ki tab.")

(defun ki-tabs-buffer-marked-p (&optional buffer)
  "Return non-nil when BUFFER is marked as a Ki tab.
BUFFER defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'ki-tabs--marked-p buffer))))

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

(defun ki-tabs--file-buffer-list ()
  "Return all open file buffers in stable path order."
  (sort (seq-filter #'ki-tabs--file-buffer-p (buffer-list))
        #'ki-tabs--buffer-less-p))

(defun ki-tabs--marked-buffer-list ()
  "Return marked file buffers in stable path order."
  (seq-filter #'ki-tabs-buffer-marked-p
              (ki-tabs--file-buffer-list)))

(defun ki-tabs--navigation-buffer-list ()
  "Return marked buffers followed by every open unmarked file buffer."
  (let (marked unmarked)
    (dolist (buffer (ki-tabs--file-buffer-list))
      (if (ki-tabs-buffer-marked-p buffer)
          (push buffer marked)
        (push buffer unmarked)))
    (nconc (nreverse marked) (nreverse unmarked))))

(defun ki-tabs--buffer-list ()
  "Return marked file buffers followed by the current unmarked file."
  (let ((current (window-buffer))
        (marked (ki-tabs--marked-buffer-list)))
    (if (or (not (ki-tabs--file-buffer-p current))
            (memq current marked))
        marked
      (append marked (list current)))))

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

(defun ki-tabs--marker (buffer)
  "Return BUFFER's marker for its marked and modified state."
  (let ((marked (ki-tabs-buffer-marked-p buffer)))
    (if (buffer-modified-p buffer)
        (if marked
            ki-tabs-marked-modified-marker
          ki-tabs-unmarked-modified-marker)
      (if marked
          ki-tabs-marked-marker
        ki-tabs-unmarked-marker))))

(defun ki-tabs--format-tab (buffer buffers)
  "Format BUFFER as a Ki-style tab among BUFFERS."
  (let* ((selected (eq buffer (window-buffer)))
         (marker (ki-tabs--marker buffer))
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
   (list ki-tabs-unmarked-marker
         ki-tabs-marked-marker
         ki-tabs-unmarked-modified-marker
         ki-tabs-marked-modified-marker
         (mapcar (lambda (buffer)
                   (list (buffer-name buffer)
                         (buffer-file-name buffer)
                         (buffer-modified-p buffer)
                         (ki-tabs-buffer-marked-p buffer)))
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
      (kill-local-variable 'ki-tabs--tab-line-was-active)))
  (kill-local-variable 'ki-tabs--marked-p))

(defun ki-tabs--refresh (&rest _ignored)
  "Invalidate every Ki tab line when `ki-tabs-mode' is active."
  (when ki-tabs-mode
    (tab-line-force-update t)))

(defun ki-tabs--set-buffer-marked (buffer marked)
  "Set BUFFER's marked state to MARKED and refresh every tab line."
  (unless (ki-tabs--file-buffer-p buffer)
    (user-error "Buffer is not visiting a visible file"))
  (with-current-buffer buffer
    (setq ki-tabs--marked-p marked))
  (ki-tabs--refresh))

(defun ki-tabs-mark-buffer (&optional buffer)
  "Mark BUFFER as a Ki tab.
BUFFER defaults to the current buffer."
  (interactive)
  (ki-tabs--set-buffer-marked (or buffer (current-buffer)) t))

(defun ki-tabs-unmark-buffer (&optional buffer)
  "Unmark BUFFER as a Ki tab.
BUFFER defaults to the current buffer."
  (interactive)
  (ki-tabs--set-buffer-marked (or buffer (current-buffer)) nil))

(defun ki-tabs-toggle-buffer-mark (&optional buffer)
  "Toggle whether BUFFER is marked as a Ki tab.
BUFFER defaults to the current buffer."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (ki-tabs--set-buffer-marked
     buffer
     (not (ki-tabs-buffer-marked-p buffer)))))

(defun ki-tabs--switch-to-marked-buffer (movement)
  "Switch to a marked buffer selected by MOVEMENT.
MOVEMENT is one of `left', `right', `first', or `last'.  Left and
right navigation wrap at the ends of the marked buffer list."
  (let* ((buffers (ki-tabs--marked-buffer-list))
         (count (length buffers))
         (position (seq-position buffers (current-buffer) #'eq))
         (target
          (when (> count 0)
            (pcase movement
              ('first (car buffers))
              ('last (nth (1- count) buffers))
              ('left
               (nth (if position
                        (mod (1- position) count)
                      (1- count))
                    buffers))
              ('right
               (nth (if position
                        (mod (1+ position) count)
                      0)
                    buffers))))))
    (when target
      (switch-to-buffer target))))

(defun ki-tabs-switch-to-left-marked-buffer ()
  "Switch to the marked buffer on the left, wrapping at the start."
  (interactive)
  (ki-tabs--switch-to-marked-buffer 'left))

(defun ki-tabs-switch-to-right-marked-buffer ()
  "Switch to the marked buffer on the right, wrapping at the end."
  (interactive)
  (ki-tabs--switch-to-marked-buffer 'right))

(defun ki-tabs-switch-to-first-marked-buffer ()
  "Switch to the first marked buffer."
  (interactive)
  (ki-tabs--switch-to-marked-buffer 'first))

(defun ki-tabs-switch-to-last-marked-buffer ()
  "Switch to the last marked buffer."
  (interactive)
  (ki-tabs--switch-to-marked-buffer 'last))

(defun ki-tabs--switch-to-relative-buffer (offset)
  "Switch OFFSET positions in the open file list without wrapping.
As in Ki, marked buffers come first, followed by every open unmarked
file buffer."
  (let* ((buffers (ki-tabs--navigation-buffer-list))
         (position (seq-position buffers (current-buffer) #'eq))
         (target-position (and position (+ position offset))))
    (when (and target-position
               (>= target-position 0)
               (< target-position (length buffers)))
      (switch-to-buffer (nth target-position buffers)))))

(defun ki-tabs-switch-to-previous-buffer ()
  "Switch to the previous open file buffer."
  (interactive)
  (ki-tabs--switch-to-relative-buffer -1))

(defun ki-tabs-switch-to-next-buffer ()
  "Switch to the next open file buffer."
  (interactive)
  (ki-tabs--switch-to-relative-buffer 1))

(defun ki-tabs-unmark-other-buffers ()
  "Unmark every buffer except the current buffer."
  (interactive)
  (let ((current (current-buffer)))
    (dolist (buffer (buffer-list))
      (when (and (not (eq buffer current))
                 (ki-tabs-buffer-marked-p buffer))
        (with-current-buffer buffer
          (setq ki-tabs--marked-p nil)))))
  (ki-tabs--refresh))

(defun ki-tabs-switch-to-alternate-buffer ()
  "Switch to the most recently used other visible file buffer."
  (interactive)
  (let ((current (current-buffer)))
    (when-let* ((alternate
                 (seq-find
                  (lambda (buffer)
                    (and (not (eq buffer current))
                         (ki-tabs--file-buffer-p buffer)))
                  (buffer-list))))
      (switch-to-buffer alternate))))

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
        (when (ki-tabs--file-buffer-p buffer)
          (setq ki-tabs--marked-p t))
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
  "Display Ki-style tabs for marked files and the current file.

Enabling the global mode marks every existing file-visiting buffer.
Files visited later start unmarked and remain visible while current.
Use `ki-tabs-mark-buffer', `ki-tabs-unmark-buffer', or
`ki-tabs-toggle-buffer-mark' to change that state.  Each tab's marker
shows both its marked and modified state."
  :global t
  :group 'ki-tabs
  (if ki-tabs-mode
      (ki-tabs--enable)
    (ki-tabs--disable)))

(provide 'ki-tabs)

;;; ki-tabs.el ends here
