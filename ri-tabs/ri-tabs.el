;;; ri-tabs.el --- Ki-style tabs for open files -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: convenience, files, tabs
;; URL: https://github.com/rofrol/ri-tabs

;;; Commentary:

;; `ri-tabs-mode' displays every marked file-visiting buffer in a tab line
;; above file windows and appends the current buffer while it is unmarked.
;; Marked tabs stay in path order, use the shortest unique path suffix as
;; their label, and show Ki's marked/modified state indicators.  Selecting a
;; tab switches the current window to its buffer; closing a tab kills it.

;;; Code:

(require 'multisession)
(require 'seq)
(require 'subr-x)
(require 'tab-line)

(defgroup ri-tabs nil
  "Ki-style tabs for open file buffers."
  :group 'convenience
  :prefix "ri-tabs-")

(define-multisession-variable ri-tabs--marks-store nil
  "Persistent Ki tab marks."
  :package "ri-tabs"
  :synchronized t)

(defconst ri-tabs--read-error (make-symbol "ri-tabs-read-error")
  "Sentinel returned when persistent Ki tab marks cannot be read.")

(defcustom ri-tabs-unmarked-marker "[ ]"
  "Marker shown before the name of an unmodified, unmarked file."
  :type 'string
  :group 'ri-tabs)

(defcustom ri-tabs-marked-marker "[-]"
  "Marker shown before the name of an unmodified, marked file."
  :type 'string
  :group 'ri-tabs)

(defcustom ri-tabs-unmarked-modified-marker "[:]"
  "Marker shown before the name of a modified, unmarked file."
  :type 'string
  :group 'ri-tabs)

(defcustom ri-tabs-marked-modified-marker "[÷]"
  "Marker shown before the name of a modified, marked file."
  :type 'string
  :group 'ri-tabs)

(defface ri-tabs-tab
  '((t :inherit tab-line-tab-inactive :box nil))
  "Face used for an inactive file tab."
  :group 'ri-tabs)

(defface ri-tabs-current-tab
  '((t :inherit tab-line-tab-current :weight bold :box nil))
  "Face used for the current tab in the selected window."
  :group 'ri-tabs)

(defface ri-tabs-current-tab-inactive-window
  '((t :inherit tab-line-tab :weight bold :box nil))
  "Face used for the current tab in an unselected window."
  :group 'ri-tabs)

(defface ri-tabs-highlight
  '((t :inherit tab-line-highlight :box nil))
  "Face used when the pointer is over a file tab."
  :group 'ri-tabs)

(defconst ri-tabs--managed-variables
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
  "Buffer-local tab-line variables managed by `ri-tabs-mode'.")

(defvar ri-tabs-mode nil
  "Non-nil when Ki tabs are enabled globally.")

(defvar-local ri-tabs--saved-state nil
  "Tab-line state saved before `ri-tabs-mode' configured this buffer.")

(defvar-local ri-tabs--tab-line-was-active nil
  "Whether `tab-line-mode' was active before Ki tabs were installed.")

(defvar-local ri-tabs--marked-p nil
  "Render cache for whether the current file is marked as a Ki tab.")

(defvar-local ri-tabs--file-id nil
  "File identity last synchronized with persistent Ki tab marks.")

(defun ri-tabs-buffer-marked-p (&optional buffer)
  "Return non-nil when BUFFER is marked as a Ki tab.
BUFFER defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'ri-tabs--marked-p buffer))))

(defun ri-tabs--file-buffer-p (buffer)
  "Return non-nil when BUFFER is a live visible file buffer."
  (and (buffer-live-p buffer)
       (buffer-file-name buffer)
       (not (string-prefix-p " " (buffer-name buffer)))))

(defun ri-tabs--buffer-file-id (buffer)
  "Return BUFFER's stable file identity, or nil when it has none."
  (when (ri-tabs--file-buffer-p buffer)
    (with-current-buffer buffer
      (expand-file-name (or buffer-file-truename buffer-file-name)))))

(defun ri-tabs--require-file-id (buffer)
  "Return BUFFER's stable file identity or signal a user error."
  (or (ri-tabs--buffer-file-id buffer)
      (user-error "Buffer is not visiting a visible file")))

(defun ri-tabs--buffer-less-p (left right)
  "Return non-nil when file buffer LEFT sorts before RIGHT."
  (let ((left-file (buffer-file-name left))
        (right-file (buffer-file-name right)))
    (if (equal left-file right-file)
        (string-lessp (buffer-name left) (buffer-name right))
      (string-lessp left-file right-file))))

(defun ri-tabs--file-buffer-list ()
  "Return all open file buffers in stable path order."
  (sort (seq-filter #'ri-tabs--file-buffer-p (buffer-list))
        #'ri-tabs--buffer-less-p))

(defun ri-tabs--make-state (files)
  "Return a normalized version-1 persistent state for FILES."
  (list :version 1
        :files (delete-dups
                (sort (copy-sequence files) #'string-lessp))))

(defun ri-tabs--normalize-state (state)
  "Validate and normalize persistent Ki tab mark STATE.
The uninitialized value nil is returned unchanged."
  (cond
   ((null state) nil)
   ((not (and (proper-list-p state)
              (= (length state) 4)
              (eq (nth 0 state) :version)))
    (error "Malformed persistent Ki tab marks: %S" state))
   ((not (eql (nth 1 state) 1))
    (error "Unsupported persistent Ki tab marks version: %S"
           (nth 1 state)))
   ((not (eq (nth 2 state) :files))
    (error "Malformed persistent Ki tab marks: %S" state))
   (t
    (let ((files (nth 3 state)))
      (unless (and (proper-list-p files)
                   (seq-every-p #'stringp files))
        (error "Malformed persistent Ki tab marks: %S" state))
      (ri-tabs--make-state files)))))

(defun ri-tabs--read-state ()
  "Read and validate the latest persistent Ki tab mark state."
  (ri-tabs--normalize-state
   (multisession-value ri-tabs--marks-store)))

(defun ri-tabs--warn-persistence (operation err)
  "Warn that persistent mark OPERATION failed with ERR."
  (display-warning
   'ri-tabs
   (format "Could not %s persistent Ki tab marks: %s"
           operation (error-message-string err))
   :warning))

(defun ri-tabs--read-state-safely ()
  "Read persistent marks, warning and returning a sentinel on error."
  (condition-case err
      (ri-tabs--read-state)
    (error
     (ri-tabs--warn-persistence "read" err)
     ri-tabs--read-error)))

(defun ri-tabs--write-state (state)
  "Persist validated STATE and return its normalized value."
  (let ((normalized (ri-tabs--normalize-state state)))
    (unless normalized
      (error "Refusing to persist uninitialized Ki tab marks"))
    (setf (multisession-value ri-tabs--marks-store) normalized)
    normalized))

(defun ri-tabs--state-marked-p (state file-id)
  "Return non-nil when FILE-ID is marked in validated STATE."
  (and state (member file-id (nth 3 state))))

(defun ri-tabs--set-buffer-cache (buffer file-id state)
  "Synchronize BUFFER's FILE-ID and render cache from STATE."
  (with-current-buffer buffer
    (setq ri-tabs--file-id file-id
          ri-tabs--marked-p
          (and (ri-tabs--state-marked-p state file-id) t))))

(defun ri-tabs--sync-live-buffers (state &optional file-ids)
  "Synchronize live file buffers from STATE.
When FILE-IDS is non-nil, only synchronize buffers with those
identities."
  (dolist (buffer (ri-tabs--file-buffer-list))
    (let ((file-id (ri-tabs--buffer-file-id buffer)))
      (when (or (null file-ids)
                (member file-id file-ids))
        (ri-tabs--set-buffer-cache buffer file-id state)))))

(defun ri-tabs--marked-buffer-list ()
  "Return marked file buffers in stable path order."
  (seq-filter #'ri-tabs-buffer-marked-p
              (ri-tabs--file-buffer-list)))

(defun ri-tabs--navigation-buffer-list ()
  "Return marked buffers followed by every open unmarked file buffer."
  (let (marked unmarked)
    (dolist (buffer (ri-tabs--file-buffer-list))
      (if (ri-tabs-buffer-marked-p buffer)
          (push buffer marked)
        (push buffer unmarked)))
    (nconc (nreverse marked) (nreverse unmarked))))

(defun ri-tabs--buffer-list ()
  "Return marked file buffers followed by the current unmarked file."
  (let ((current (window-buffer))
        (marked (ri-tabs--marked-buffer-list)))
    (if (or (not (ri-tabs--file-buffer-p current))
            (memq current marked))
        marked
      (append marked (list current)))))

(defun ri-tabs--path-parts (file)
  "Return the non-empty path components of FILE."
  (seq-remove #'string-empty-p
              (file-name-split (abbreviate-file-name file))))

(defun ri-tabs--same-suffix-p (left right width)
  "Return non-nil when LEFT and RIGHT share a WIDTH-component suffix."
  (equal (last left width) (last right width)))

(defun ri-tabs--tab-name (buffer buffers)
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
      (let* ((parts (ri-tabs--path-parts file))
             (other-parts
              (mapcar (lambda (other)
                        (ri-tabs--path-parts (buffer-file-name other)))
                      same-base))
             (width 1)
             (limit (length parts)))
        (while (and (< width limit)
                    (seq-some
                     (lambda (candidate)
                       (ri-tabs--same-suffix-p parts candidate width))
                     other-parts))
          (setq width (1+ width)))
        (string-join (last parts width) "/"))))))

(defun ri-tabs--tab-face (selected)
  "Return the appropriate tab face for SELECTED state."
  (cond
   ((not selected) 'ri-tabs-tab)
   ((mode-line-window-selected-p) 'ri-tabs-current-tab)
   (t 'ri-tabs-current-tab-inactive-window)))

(defun ri-tabs--marker (buffer)
  "Return BUFFER's marker for its marked and modified state."
  (let ((marked (ri-tabs-buffer-marked-p buffer)))
    (if (buffer-modified-p buffer)
        (if marked
            ri-tabs-marked-modified-marker
          ri-tabs-unmarked-modified-marker)
      (if marked
          ri-tabs-marked-marker
        ri-tabs-unmarked-marker))))

(defun ri-tabs--format-tab (buffer buffers)
  "Format BUFFER as a Ki-style tab among BUFFERS."
  (let* ((selected (eq buffer (window-buffer)))
         (marker (ri-tabs--marker buffer))
         (name (funcall tab-line-tab-name-function buffer buffers))
         (label (string-replace "%" "%%"
                                (format " %s %s " marker name)))
         (file (abbreviate-file-name (buffer-file-name buffer))))
    (apply #'propertize label
           `(face ,(ri-tabs--tab-face selected)
             tab ,buffer
             ,@(when selected '(selected t))
             keymap ,tab-line-tab-map
             mouse-face ri-tabs-highlight
             help-echo ,(if selected
                            (format "Current file: %s" file)
                          (format "Switch to %s" file))
             follow-link ignore
             rear-nonsticky nil))))

(defun ri-tabs--cache-key (tabs)
  "Return a tab-line cache key for TABS and their file state."
  (append
   (tab-line-cache-key-default tabs)
   (list ri-tabs-unmarked-marker
         ri-tabs-marked-marker
         ri-tabs-unmarked-modified-marker
         ri-tabs-marked-modified-marker
         (mapcar (lambda (buffer)
                   (list (buffer-name buffer)
                         (buffer-file-name buffer)
                         (buffer-modified-p buffer)
                         (ri-tabs-buffer-marked-p buffer)))
                 tabs))))

(defun ri-tabs--capture-state ()
  "Capture the tab-line variables managed in the current buffer."
  (mapcar (lambda (variable)
            (list variable
                  (local-variable-p variable)
                  (symbol-value variable)))
          ri-tabs--managed-variables))

(defun ri-tabs--set-local-configuration ()
  "Install the Ki tab-line configuration in the current buffer."
  (setq-local tab-line-format '(:eval (tab-line-format))
              tab-line-tabs-function #'ri-tabs--buffer-list
              tab-line-tab-name-function #'ri-tabs--tab-name
              tab-line-tab-name-format-function #'ri-tabs--format-tab
              tab-line-cache-key-function #'ri-tabs--cache-key
              tab-line-new-button-show nil
              tab-line-close-button-show nil
              tab-line-close-tab-function 'kill-buffer
              tab-line-tab-face-functions nil
              tab-line-separator ""
              tab-line-auto-hscroll t))

(defun ri-tabs--install ()
  "Install Ki tabs in the current file buffer."
  (when (ri-tabs--file-buffer-p (current-buffer))
    (unless ri-tabs--saved-state
      (setq ri-tabs--saved-state (ri-tabs--capture-state)
            ri-tabs--tab-line-was-active tab-line-mode))
    (unless tab-line-mode
      (tab-line-mode 1))
    (ri-tabs--set-local-configuration)))

(defun ri-tabs--restore ()
  "Restore tab-line state previously saved in the current buffer."
  (when ri-tabs--saved-state
    (let ((saved-state ri-tabs--saved-state)
          (was-active ri-tabs--tab-line-was-active))
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
      (kill-local-variable 'ri-tabs--saved-state)
      (kill-local-variable 'ri-tabs--tab-line-was-active)))
  (kill-local-variable 'ri-tabs--marked-p)
  (kill-local-variable 'ri-tabs--file-id))

(defun ri-tabs--refresh (&rest _ignored)
  "Invalidate every Ki tab line when `ri-tabs-mode' is active."
  (when ri-tabs-mode
    (tab-line-force-update t)))

(defun ri-tabs--updated-state (state file-id marked)
  "Return STATE with FILE-ID membership set to MARKED."
  (let ((files (and state (nth 3 state))))
    (ri-tabs--make-state
     (if marked
         (cons file-id files)
       (remove file-id files)))))

(defun ri-tabs--commit-state (state &optional file-ids)
  "Persist STATE, synchronize FILE-IDS, and refresh tab lines once.
When FILE-IDS is nil, synchronize every live file buffer."
  (setq state (ri-tabs--write-state state))
  (ri-tabs--sync-live-buffers state file-ids)
  (ri-tabs--refresh))

(defun ri-tabs-mark-buffer (&optional buffer)
  "Persistently mark BUFFER as a Ki tab.
BUFFER defaults to the current buffer.  All live buffers visiting the
same file are synchronized."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (file-id (ri-tabs--require-file-id buffer))
         (state (ri-tabs--read-state)))
    (ri-tabs--commit-state
     (ri-tabs--updated-state state file-id t)
     (list file-id))))

(defun ri-tabs-unmark-buffer (&optional buffer)
  "Persistently unmark BUFFER as a Ki tab.
BUFFER defaults to the current buffer.  All live buffers visiting the
same file are synchronized."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (file-id (ri-tabs--require-file-id buffer))
         (state (ri-tabs--read-state)))
    (ri-tabs--commit-state
     (ri-tabs--updated-state state file-id nil)
     (list file-id))))

(defun ri-tabs-toggle-buffer-mark (&optional buffer)
  "Toggle BUFFER's persistent Ki tab mark.
BUFFER defaults to the current buffer.  The latest persistent state,
not the buffer-local render cache, determines the new mark."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (file-id (ri-tabs--require-file-id buffer))
         (state (ri-tabs--read-state)))
    (ri-tabs--commit-state
     (ri-tabs--updated-state
      state file-id (not (ri-tabs--state-marked-p state file-id)))
     (list file-id))))

(defun ri-tabs--switch-to-marked-buffer (movement)
  "Switch to a marked buffer selected by MOVEMENT.
MOVEMENT is one of `left', `right', `first', or `last'.  Left and
right navigation wrap at the ends of the marked buffer list."
  (let* ((buffers (ri-tabs--marked-buffer-list))
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

(defun ri-tabs-switch-to-left-marked-buffer ()
  "Switch to the marked buffer on the left, wrapping at the start."
  (interactive)
  (ri-tabs--switch-to-marked-buffer 'left))

(defun ri-tabs-switch-to-right-marked-buffer ()
  "Switch to the marked buffer on the right, wrapping at the end."
  (interactive)
  (ri-tabs--switch-to-marked-buffer 'right))

(defun ri-tabs-switch-to-first-marked-buffer ()
  "Switch to the first marked buffer."
  (interactive)
  (ri-tabs--switch-to-marked-buffer 'first))

(defun ri-tabs-switch-to-last-marked-buffer ()
  "Switch to the last marked buffer."
  (interactive)
  (ri-tabs--switch-to-marked-buffer 'last))

(defun ri-tabs--switch-to-relative-buffer (offset)
  "Switch OFFSET positions in the open file list without wrapping.
As in Ki, marked buffers come first, followed by every open unmarked
file buffer."
  (let* ((buffers (ri-tabs--navigation-buffer-list))
         (position (seq-position buffers (current-buffer) #'eq))
         (target-position (and position (+ position offset))))
    (when (and target-position
               (>= target-position 0)
               (< target-position (length buffers)))
      (switch-to-buffer (nth target-position buffers)))))

(defun ri-tabs-switch-to-previous-buffer ()
  "Switch to the previous open file buffer."
  (interactive)
  (ri-tabs--switch-to-relative-buffer -1))

(defun ri-tabs-switch-to-next-buffer ()
  "Switch to the next open file buffer."
  (interactive)
  (ri-tabs--switch-to-relative-buffer 1))

(defun ri-tabs-unmark-other-buffers ()
  "Persistently unmark every file except the current marked file.
If the current file is unmarked, remove every persistent mark,
including marks for files with no live buffer."
  (interactive)
  (let* ((file-id (ri-tabs--require-file-id (current-buffer)))
         (state (ri-tabs--read-state))
         (files (and (ri-tabs--state-marked-p state file-id)
                     (list file-id))))
    (ri-tabs--commit-state (ri-tabs--make-state files))))

(defun ri-tabs-switch-to-alternate-buffer ()
  "Switch to the most recently used other visible file buffer."
  (interactive)
  (let ((current (current-buffer)))
    (when-let* ((alternate
                 (seq-find
                  (lambda (buffer)
                    (and (not (eq buffer current))
                         (ri-tabs--file-buffer-p buffer)))
                  (buffer-list))))
      (switch-to-buffer alternate))))

(defun ri-tabs--sync-visited-buffer ()
  "Restore the current file buffer's mark and install Ki tabs."
  (when ri-tabs-mode
    (if (ri-tabs--file-buffer-p (current-buffer))
        (let* ((file-id (ri-tabs--buffer-file-id (current-buffer)))
               (state (ri-tabs--read-state-safely)))
          (ri-tabs--set-buffer-cache
           (current-buffer) file-id
           (unless (eq state ri-tabs--read-error) state))
          (ri-tabs--install))
      (ri-tabs--restore))
    (ri-tabs--refresh)))

(defun ri-tabs--sync-buffer-role ()
  "Install or remove Ki tabs without reinterpreting the current mark."
  (when ri-tabs-mode
    (if (ri-tabs--file-buffer-p (current-buffer))
        (ri-tabs--install)
      (ri-tabs--restore))
    (ri-tabs--refresh)))

(defun ri-tabs--sync-after-visited-file-name-change ()
  "Synchronize or migrate marks after the visited filename changes."
  (when ri-tabs-mode
    (let ((old-file-id ri-tabs--file-id)
          (new-file-id (ri-tabs--buffer-file-id (current-buffer))))
      (if (null new-file-id)
          (ri-tabs--restore)
        (let ((state (ri-tabs--read-state-safely)))
          (if (eq state ri-tabs--read-error)
              (setq ri-tabs--file-id new-file-id
                    ri-tabs--marked-p nil)
            (let ((affected
                   (delete-dups
                    (delq nil (list old-file-id new-file-id)))))
              (if (and old-file-id
                       (not (equal old-file-id new-file-id))
                       (ri-tabs--state-marked-p state old-file-id))
                  (let ((new-state
                         (ri-tabs--updated-state
                          (ri-tabs--updated-state
                           state old-file-id nil)
                          new-file-id t)))
                    (condition-case err
                        (progn
                          (setq new-state
                                (ri-tabs--write-state new-state))
                          (ri-tabs--sync-live-buffers
                           new-state affected))
                      (error
                       (ri-tabs--warn-persistence "migrate" err)
                       (ri-tabs--sync-live-buffers
                        state affected))))
                (ri-tabs--sync-live-buffers state affected))))
          (ri-tabs--install)))
      (ri-tabs--refresh))))

(defun ri-tabs--enable ()
  "Install Ki tabs and initialize render caches from persistent marks."
  (let ((state (ri-tabs--read-state-safely)))
    (when (null state)
      (condition-case err
          (setq state
                (ri-tabs--write-state
                 (ri-tabs--make-state
                  (mapcar #'ri-tabs--buffer-file-id
                          (ri-tabs--file-buffer-list)))))
        (error
         (ri-tabs--warn-persistence "initialize" err)
         (setq state ri-tabs--read-error))))
    (add-hook 'find-file-hook #'ri-tabs--sync-visited-buffer)
    (add-hook 'after-set-visited-file-name-hook
              #'ri-tabs--sync-after-visited-file-name-change)
    (add-hook 'after-change-major-mode-hook
              #'ri-tabs--sync-buffer-role)
    (add-hook 'kill-buffer-hook #'ri-tabs--refresh)
    (add-hook 'first-change-hook #'ri-tabs--refresh)
    (add-hook 'after-save-hook #'ri-tabs--refresh)
    (add-hook 'after-revert-hook #'ri-tabs--refresh)
    (ri-tabs--sync-live-buffers
     (unless (eq state ri-tabs--read-error) state))
    (dolist (buffer (ri-tabs--file-buffer-list))
      (with-current-buffer buffer
        (ri-tabs--install)))
    (ri-tabs--refresh)))

(defun ri-tabs--disable ()
  "Remove Ki tabs and caches without changing persistent marks."
  (remove-hook 'find-file-hook #'ri-tabs--sync-visited-buffer)
  (remove-hook 'after-set-visited-file-name-hook
               #'ri-tabs--sync-after-visited-file-name-change)
  (remove-hook 'after-change-major-mode-hook
               #'ri-tabs--sync-buffer-role)
  (remove-hook 'kill-buffer-hook #'ri-tabs--refresh)
  (remove-hook 'first-change-hook #'ri-tabs--refresh)
  (remove-hook 'after-save-hook #'ri-tabs--refresh)
  (remove-hook 'after-revert-hook #'ri-tabs--refresh)
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ri-tabs--restore))))
  (tab-line-force-update t))

;;;###autoload
(define-minor-mode ri-tabs-mode
  "Display Ki-style tabs for persistently marked files.

On first use, the mode marks and stores every existing visible file
buffer.  Later enables restore the stored state.  Files visited later
start unmarked unless their canonical identity is stored.  Closing a
buffer never removes its mark; use `ri-tabs-unmark-buffer',
`ri-tabs-toggle-buffer-mark', or `ri-tabs-unmark-other-buffers' to
change persistent membership.  Navigation considers live marked
buffers only."
  :global t
  :group 'ri-tabs
  (if ri-tabs-mode
      (ri-tabs--enable)
    (ri-tabs--disable)))

(provide 'ri-tabs)

;;; ri-tabs.el ends here
