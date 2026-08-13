;;; ri-tabs.el --- Ki-style tabs for open files -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.2"))
;; Keywords: convenience, files, tabs
;; URL: https://github.com/rofrol/ri-tabs

;;; Commentary:

;; `ri-tabs-mode' displays every persistently marked file in one native Tab
;; Bar spanning each ordinary frame and appends that frame's selected buffer
;; while it is unmarked.  On mode activation, available marked files without
;; live buffers are reopened in the background.  Marked tabs stay in path
;; order, use the shortest unique path suffix as their label, and show Ki's
;; marked/modified state indicators.  Selecting a tab switches the selected
;; window of its frame to the file buffer; closing a tab kills it without
;; removing its persistent mark.

;;; Code:

(require 'multisession)
(require 'seq)
(require 'subr-x)
(require 'tab-bar)

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
  '((t :inherit tab-bar-tab-inactive :box nil))
  "Face used for an inactive file tab."
  :group 'ri-tabs)

(defface ri-tabs-current-tab
  '((t :inherit tab-bar-tab
       :foreground "black"
       :background "#ffffff"
       :weight bold
       :box nil))
  "Face used for the current file tab."
  :group 'ri-tabs)

(defface ri-tabs-highlight
  '((t :inherit tab-bar-tab-highlight :box nil))
  "Face used when the pointer is over a file tab."
  :group 'ri-tabs)

(defconst ri-tabs--tab-bar-event-bindings
  '(([down-mouse-1] . ri-tabs--mouse-select)
    ([drag-mouse-1] . ignore)
    ([mouse-1] . ignore)
    ([mouse-2] . ri-tabs--mouse-close)
    ([down-mouse-3] . ri-tabs--mouse-context-menu)
    ([mouse-4] . ri-tabs-switch-to-previous-buffer)
    ([mouse-5] . ri-tabs-switch-to-next-buffer)
    ([wheel-up] . ri-tabs-switch-to-previous-buffer)
    ([wheel-down] . ri-tabs-switch-to-next-buffer)
    ([wheel-left] . ri-tabs-switch-to-previous-buffer)
    ([wheel-right] . ri-tabs-switch-to-next-buffer)
    ([S-mouse-4] . ignore)
    ([S-mouse-5] . ignore)
    ([S-wheel-up] . ignore)
    ([S-wheel-down] . ignore)
    ([S-wheel-left] . ignore)
    ([S-wheel-right] . ignore)
    ([touchscreen-begin] . ri-tabs--touchscreen-begin))
  "Tab Bar event bindings owned while `ri-tabs-mode' is active.")

(defconst ri-tabs--workspace-shortcut-commands
  '(tab-recent tab-bar-select-tab tab-last tab-next tab-previous)
  "Native workspace commands hidden while Ri file tabs are visible.")

(defconst ri-tabs--absent (make-symbol "ri-tabs-absent")
  "Sentinel representing an absent saved alist entry.")

(defvar ri-tabs--tab-bar-state nil
  "Pre-existing native Tab Bar state saved by `ri-tabs-mode'.")

(defvar ri-tabs--temporary-frame-states nil
  "Tab Bar state of frames created while Ri is active.")

(defvar ri-tabs-mode nil
  "Non-nil when Ki tabs are enabled globally.")

(defvar ri-tabs--activation-pending-p nil
  "Non-nil when persistent Ki tab activation awaits Emacs startup.")

(defvar ri-tabs--activation-active-p nil
  "Non-nil while persistent Ki tab activation is running.")

(defvar ri-tabs--activation-complete-p nil
  "Non-nil after persistent Ki tab activation finishes for this enable.")

(defvar ri-tabs--activation-state ri-tabs--read-error
  "Persistent state used by file hooks during activation.
This variable is dynamically bound to the validated activation snapshot.")

(defvar ri-tabs--refresh-batching-p nil
  "Non-nil while Ki tab refresh requests must be deferred.")

(defvar ri-tabs--refresh-pending-p nil
  "Non-nil when a refresh was requested during the current batch.")


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

(defun ri-tabs--live-file-index ()
  "Return an index of canonical identities represented by live buffers."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (buffer (ri-tabs--file-buffer-list))
      (when-let* ((file-id (ri-tabs--buffer-file-id buffer)))
        (puthash file-id t index)))
    index))

(defun ri-tabs--warn-restore-failures (failures)
  "Emit one warning summarizing marked file restore FAILURES."
  (when failures
    (display-warning
     'ri-tabs
     (concat
      (format "Could not restore %d persistently marked Ki tab file%s:"
              (length failures)
              (if (= (length failures) 1) "" "s"))
      (mapconcat
       (lambda (failure)
         (format "\n  %s: %s" (car failure) (cdr failure)))
       failures ""))
     :warning)))

(defun ri-tabs--restore-marked-files (state)
  "Restore missing marked file buffers from validated STATE.
Return an ordered list of (FILE-ID . REASON) failures.  This function
does not read or write persistent membership."
  (let ((live-index (ri-tabs--live-file-index))
        failures)
    (dolist (file-id (plist-get state :files))
      (when (and ri-tabs-mode
                 (not (gethash file-id live-index)))
        (condition-case err
            (if (not (file-exists-p file-id))
                (push (cons file-id "file does not exist") failures)
              (let* ((buffer (find-file-noselect file-id))
                     (resolved
                      (and (bufferp buffer)
                           (buffer-live-p buffer)
                           (ri-tabs--buffer-file-id buffer))))
                (if (equal resolved file-id)
                    (puthash file-id t live-index)
                  (push
                   (cons
                    file-id
                    (if resolved
                        (format "opened buffer resolves to %s" resolved)
                      "opening did not return a live visible file buffer"))
                   failures))))
          (error
           (push (cons file-id (error-message-string err)) failures)))))
    (setq failures (nreverse failures))
    (ri-tabs--warn-restore-failures failures)
    failures))

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

(defun ri-tabs--buffer-list (selected-buffer)
  "Return marked buffers followed by SELECTED-BUFFER when unmarked.
SELECTED-BUFFER is included only when it is a live visible file
buffer."
  (let ((marked (ri-tabs--marked-buffer-list)))
    (if (or (not (ri-tabs--file-buffer-p selected-buffer))
            (memq selected-buffer marked))
        marked
      (append marked (list selected-buffer)))))

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
  (if selected 'ri-tabs-current-tab 'ri-tabs-tab))

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

(defun ri-tabs--structurally-ineligible-frame-p (frame)
  "Return non-nil when FRAME is not an ordinary top-level frame."
  (or (frame-parameter frame 'parent-frame)
      (frame-parameter frame 'tooltip)
      (frame-parameter frame 'no-accept-focus)
      (eq (frame-parameter frame 'minibuffer) 'only)))
(defun ri-tabs--frame-eligible-p (frame)
  "Return non-nil when FRAME should display an Ri file Tab Bar.

Ri owns the Tab Bar row of every ordinary top-level frame while the
mode is active.  A pre-existing `tab-bar-lines-keep-state' value is
saved and restored on disable, but must not suppress Ri's row on an
otherwise ordinary frame.  Structural auxiliary frames are excluded."
  (and (frame-live-p frame)
       (not (ri-tabs--structurally-ineligible-frame-p frame))))

(defun ri-tabs--frame-selected-window (frame)
  "Return FRAME's selected ordinary window.
While FRAME's minibuffer is active, return the live window that
selected it.  Never return a minibuffer window."
  (when (frame-live-p frame)
    (let* ((minibuffer (active-minibuffer-window))
           (origin (and minibuffer (minibuffer-selected-window)))
           (selected (frame-selected-window frame)))
      (cond
       ((and (window-live-p origin)
             (eq (window-frame origin) frame)
             (not (window-minibuffer-p origin)))
        origin)
       ((and (window-live-p selected)
             (not (window-minibuffer-p selected)))
        selected)
       (t
        (seq-find (lambda (window)
                    (and (window-live-p window)
                         (not (window-minibuffer-p window))))
                  (window-list frame 'nomini)))))))

(defun ri-tabs--tab-label (buffer buffers selected-buffer)
  "Return BUFFER's Tab Bar label among BUFFERS.
SELECTED-BUFFER determines the active face without consulting an
ambient selected window."
  (let* ((selected (eq buffer selected-buffer))
         (file (abbreviate-file-name (buffer-file-name buffer)))
         (help (if selected
                   (format "Current file: %s" file)
                 (format "Switch to %s" file))))
    (propertize
     (format " %s %s "
             (ri-tabs--marker buffer)
             (ri-tabs--tab-name buffer buffers))
     'face (ri-tabs--tab-face selected)
     'mouse-face 'ri-tabs-highlight
     'help-echo help)))

(defun ri-tabs--select-buffer (frame buffer)
  "Display live BUFFER in FRAME's selected ordinary window.
Resolve the target window at action time so a rendered item cannot
retain a stale window."
  (if (and (frame-live-p frame) (buffer-live-p buffer))
      (if-let* ((window (ri-tabs--frame-selected-window frame)))
          (progn
            (with-selected-window window
              (switch-to-buffer buffer))
            (ri-tabs--refresh))
        (ri-tabs--refresh))
    (ri-tabs--refresh)))

(defun ri-tabs--close-buffer (buffer)
  "Kill live BUFFER without changing its persistent Ri mark."
  (if (buffer-live-p buffer)
      (kill-buffer buffer)
    (ri-tabs--refresh)))

(defun ri-tabs--toggle-buffer-from-tab (buffer)
  "Toggle live BUFFER's persistent mark from a rendered tab action."
  (if (buffer-live-p buffer)
      (ri-tabs-toggle-buffer-mark buffer)
    (ri-tabs--refresh)))

(defun ri-tabs--format-tabs (&optional frame)
  "Return native file-tab menu items for FRAME.
FRAME defaults to the selected frame because `tab-bar-format' calls
formatters without arguments."
  (setq frame (or frame (selected-frame)))
  (if (not (ri-tabs--frame-eligible-p frame))
      (when (frame-live-p frame)
        (set-frame-parameter frame 'ri-tabs--item-buffers nil))
    (let* ((window (ri-tabs--frame-selected-window frame))
           (selected-buffer (and window (window-buffer window)))
           (buffers (ri-tabs--buffer-list selected-buffer))
           (index 0)
           items
           mapping)
      (dolist (buffer buffers)
        (setq index (1+ index))
        (let* ((item-frame frame)
               (item-buffer buffer)
               (selected (eq item-buffer selected-buffer))
               (key (if selected
                        'current-tab
                      (intern (format "tab-%d" index))))
               (label
                (ri-tabs--tab-label
                 item-buffer buffers selected-buffer))
               (help (get-text-property 0 'help-echo label))
               (command
                (if selected
                    #'ignore
                  (lambda ()
                    (interactive)
                    (ri-tabs--select-buffer item-frame item-buffer)))))
          (push (list key 'menu-item label command :help help)
                items)
          (push (cons key item-buffer) mapping)))
      (setq items (nreverse items)
            mapping (nreverse mapping))
      (set-frame-parameter frame 'ri-tabs--item-buffers mapping)
      items)))

(defun ri-tabs--event-position (event)
  "Return the mouse or touch position carried by EVENT."
  (cond
   ((and (consp event)
         (eq (car event) 'touchscreen-begin))
    (cdadr event))
   (t
    (event-start event))))

(defun ri-tabs--event-target (event &optional position)
  "Decode EVENT at POSITION into (FRAME KEY BUFFER CLOSE-P).
This is the only Ri helper that calls the native private event
decoder.  A graphical position identifies its frame directly; a TTY
position falls back to the selected frame."
  (let* ((position (or position (ri-tabs--event-position event)))
         (location (and position (posn-window position)))
         (frame (cond
                 ((framep location) location)
                 ((windowp location) (window-frame location))
                 (t (selected-frame))))
         (item (and position (tab-bar--event-to-item position)))
         (key (car item))
         (entry
          (and (frame-live-p frame)
               (assq key
                     (frame-parameter frame
                                      'ri-tabs--item-buffers)))))
    (list frame key (cdr entry) (nth 2 item))))

(defun ri-tabs--mouse-select (event)
  "Select the inactive Ri file tab clicked by EVENT."
  (interactive "e")
  (pcase-let ((`(,frame ,key ,buffer ,_)
               (ri-tabs--event-target event)))
    (when (and buffer (not (eq key 'current-tab)))
      (ri-tabs--select-buffer frame buffer))))

(defun ri-tabs--mouse-close (event)
  "Close the Ri file tab clicked by EVENT."
  (interactive "e")
  (pcase-let ((`(,_frame ,_key ,buffer ,_)
               (ri-tabs--event-target event)))
    (when buffer
      (ri-tabs--close-buffer buffer))))

(defun ri-tabs--context-menu (frame buffer)
  "Return a file-tab context menu for BUFFER on FRAME."
  (let ((menu
         (make-sparse-keymap
          (propertize "Ri File Tab" 'hide t))))
    (define-key-after
      menu [select]
      `(menu-item
        "Select"
        ,(lambda ()
           (interactive)
           (ri-tabs--select-buffer frame buffer))
        :help "Display this file in the selected window"))
    (define-key-after
      menu [toggle-mark]
      `(menu-item
        ,(if (ri-tabs-buffer-marked-p buffer) "Unmark" "Mark")
        ,(lambda ()
           (interactive)
           (ri-tabs--toggle-buffer-from-tab buffer))
        :help "Toggle this file's persistent tab mark"))
    (define-key-after
      menu [close]
      `(menu-item
        "Close"
        ,(lambda ()
           (interactive)
           (ri-tabs--close-buffer buffer))
        :help "Kill this file buffer without removing its mark"))
    menu))

(defun ri-tabs--mouse-context-menu (event &optional position)
  "Open the Ri file-tab context menu for EVENT at POSITION."
  (interactive "e")
  (pcase-let ((`(,frame ,_key ,buffer ,_)
               (ri-tabs--event-target event position)))
    (when buffer
      (popup-menu (ri-tabs--context-menu frame buffer) event))))

(declare-function touch-screen-track-tap "touch-screen.el")
(defvar touch-screen-delay)

(defun ri-tabs--touchscreen-timeout ()
  "Request an Ri file-tab context menu after a long touch."
  (beep)
  (throw 'ri-tabs--context-menu 'context-menu))

(defun ri-tabs--touchscreen-begin (event)
  "Select, close, or open a context menu for touchscreen EVENT."
  (interactive "e")
  (let* ((position (ri-tabs--event-position event))
         (target (ri-tabs--event-target event position))
         (frame (nth 0 target))
         (key (nth 1 target))
         (buffer (nth 2 target))
         (close-p (nth 3 target))
         timer)
    (when buffer
      (when
          (eq
           (catch 'ri-tabs--context-menu
             (unwind-protect
                 (progn
                   (setq timer
                         (run-at-time
                          touch-screen-delay nil
                          #'ri-tabs--touchscreen-timeout))
                   (when (touch-screen-track-tap event)
                     (cond
                      (close-p
                       (ri-tabs--close-buffer buffer))
                      ((not (eq key 'current-tab))
                       (ri-tabs--select-buffer frame buffer)))))
               (when timer
                 (cancel-timer timer))))
           'context-menu)
        (popup-menu (ri-tabs--context-menu frame buffer) event)))))

(defun ri-tabs--shortcut-keys ()
  "Return native Tab Bar shortcut keys that can select workspaces."
  (let ((modifiers tab-bar-select-tab-modifiers))
    (append
     (list [(control tab)]
           [(control shift tab)]
           [(control shift iso-lefttab)])
     (when modifiers
       (mapcar
        (lambda (digit)
          (vector (append modifiers (list digit))))
        (number-sequence ?0 ?9))))))

(defun ri-tabs--capture-bindings (map keys)
  "Capture direct bindings for KEYS in MAP."
  (mapcar
   (lambda (key)
     (cons (copy-sequence key) (lookup-key map key)))
   keys))

(defun ri-tabs--restore-bindings (map bindings)
  "Restore MAP from saved BINDINGS."
  (dolist (entry bindings)
    (if (cdr entry)
        (define-key map (car entry) (cdr entry))
      (define-key map (car entry) nil t))))

(defun ri-tabs--install-event-bindings ()
  "Install Ri pointer, touch, and wheel bindings in `tab-bar-map'."
  (dolist (entry ri-tabs--tab-bar-event-bindings)
    (define-key tab-bar-map (car entry) (cdr entry))))

(defun ri-tabs--hide-workspace-shortcuts ()
  "Disable native shortcuts that target hidden workspace tabs."
  (dolist (key (ri-tabs--shortcut-keys))
    (when (memq (lookup-key tab-bar-mode-map key)
                ri-tabs--workspace-shortcut-commands)
      (define-key tab-bar-mode-map key #'undefined))))

(defun ri-tabs--capture-frame-state (frame)
  "Capture Ri-owned Tab Bar parameters of FRAME."
  (list frame
        (frame-parameter frame 'tab-bar-lines)
        (frame-parameter frame 'tab-bar-lines-keep-state)))

(defun ri-tabs--configure-frame (frame &optional remember-temporary)
  "Apply the active Ri Tab Bar policy to FRAME.
When REMEMBER-TEMPORARY is non-nil, remember FRAME's original Tab Bar
parameters so a frame created while Ri is active can be restored
exactly on disable."
  (when (frame-live-p frame)
    (let ((ineligible
           (ri-tabs--structurally-ineligible-frame-p frame)))
      (when (and remember-temporary
                 (not (assq frame ri-tabs--temporary-frame-states)))
        (push
         (ri-tabs--capture-frame-state frame)
         ri-tabs--temporary-frame-states))
      (if ineligible
          (progn
            (set-frame-parameter frame 'tab-bar-lines 0)
            (set-frame-parameter
             frame 'tab-bar-lines-keep-state t))
        ;; Ri temporarily owns the visible row on ordinary frames.
        ;; Pin the row while Ri is active: core Tab Bar code recalculates
        ;; `tab-bar-lines' in several paths, and our file tabs intentionally
        ;; are not represented by `tab-bar-tabs-function'.  The original
        ;; keep-state value is already captured and is restored on disable.
        (set-frame-parameter frame 'tab-bar-lines 1)
        (set-frame-parameter frame 'tab-bar-lines-keep-state t)))))

(defun ri-tabs--configure-new-frame (frame)
  "Configure newly created FRAME while `ri-tabs-mode' is active."
  (when ri-tabs-mode
    (ri-tabs--configure-frame frame t)
    (when (ri-tabs--frame-eligible-p frame)
      (let ((state (ri-tabs--state-for-hook)))
        (unless (eq state ri-tabs--read-error)
          (ri-tabs--sync-live-buffers state))))
    (ri-tabs--refresh)))

(defun ri-tabs--default-frame-lines-entry ()
  "Return the position and value of the default Tab Bar lines entry.
Return `ri-tabs--absent' when `default-frame-alist' has no such entry."
  (let ((index 0)
        (tail default-frame-alist)
        entry)
    (while (and tail (not entry))
      (if (eq (caar tail) 'tab-bar-lines)
          (setq entry (car tail))
        (setq index (1+ index)
              tail (cdr tail))))
    (if entry
        (list :index index :entry (copy-tree entry))
      ri-tabs--absent)))

(defun ri-tabs--set-default-frame-lines (value)
  "Set the default frame Tab Bar lines entry to VALUE."
  (setq default-frame-alist
        (cons (cons 'tab-bar-lines value)
              (assq-delete-all
               'tab-bar-lines default-frame-alist))))

(defun ri-tabs--restore-default-frame-lines (saved)
  "Restore the saved default Tab Bar lines entry in SAVED."
  (setq default-frame-alist
        (assq-delete-all 'tab-bar-lines default-frame-alist))
  (unless (eq saved ri-tabs--absent)
    (let ((index
           (min (plist-get saved :index)
                (length default-frame-alist))))
      (setq default-frame-alist
            (append
             (seq-take default-frame-alist index)
             (list (copy-tree (plist-get saved :entry)))
             (seq-drop default-frame-alist index))))))

(defun ri-tabs--capture-tab-bar-state ()
  "Capture native Tab Bar state before Ri takes ownership."
  (list
   :mode (and tab-bar-mode t)
   :format (copy-tree (default-value 'tab-bar-format))
   :show (default-value 'tab-bar-show)
   :event-bindings
   (ri-tabs--capture-bindings
    tab-bar-map (mapcar #'car ri-tabs--tab-bar-event-bindings))
   :shortcut-bindings
   (ri-tabs--capture-bindings
    tab-bar-mode-map (ri-tabs--shortcut-keys))
   :frames (mapcar #'ri-tabs--capture-frame-state (frame-list))
   :default-frame-lines (ri-tabs--default-frame-lines-entry)))

(defun ri-tabs--install-tab-bar ()
  "Install the frame-wide native Ri file Tab Bar."
  (unless ri-tabs--tab-bar-state
    (setq ri-tabs--tab-bar-state
          (ri-tabs--capture-tab-bar-state)))
  (setq-default tab-bar-format '(ri-tabs--format-tabs)
                ;; `t' is the documented unconditional visibility value.
                ;; A numeric value is a threshold based on native workspace
                ;; tabs, which Ri deliberately does not use for file tabs.
                tab-bar-show t)
  (ri-tabs--install-event-bindings)
  (dolist (frame (frame-list))
    (ri-tabs--configure-frame frame))
  (ri-tabs--set-default-frame-lines 1)
  (tab-bar-mode 1)
  (ri-tabs--hide-workspace-shortcuts)
  (dolist (frame (frame-list))
    (ri-tabs--configure-frame frame)))

(defun ri-tabs--restore-tab-bar-state ()
  "Restore native Tab Bar state saved before Ri activation."
  (when ri-tabs--tab-bar-state
    (let ((state ri-tabs--tab-bar-state))
      (setq-default
       tab-bar-format (copy-tree (plist-get state :format))
       tab-bar-show (plist-get state :show))
      (unless (plist-get state :mode)
        (tab-bar-mode -1))
      (when (plist-get state :mode)
        (tab-bar-mode 1))
      (dolist (entry ri-tabs--temporary-frame-states)
        (when (frame-live-p (car entry))
          (set-frame-parameter
           (car entry) 'tab-bar-lines (nth 1 entry))
          (set-frame-parameter
           (car entry) 'tab-bar-lines-keep-state (nth 2 entry))))
      (ri-tabs--restore-bindings
       tab-bar-map (plist-get state :event-bindings))
      (ri-tabs--restore-bindings
       tab-bar-mode-map (plist-get state :shortcut-bindings))
      (dolist (entry (plist-get state :frames))
        (when (frame-live-p (car entry))
          (set-frame-parameter
           (car entry) 'tab-bar-lines (nth 1 entry))
          (set-frame-parameter
           (car entry) 'tab-bar-lines-keep-state (nth 2 entry))))
      (ri-tabs--restore-default-frame-lines
       (plist-get state :default-frame-lines))
      (dolist (frame (frame-list))
        (set-frame-parameter frame 'ri-tabs--item-buffers nil))
      (setq ri-tabs--temporary-frame-states nil
            ri-tabs--tab-bar-state nil))))

(defun ri-tabs--clear-buffer-cache (buffer)
  "Remove Ri-owned persistent-state cache variables from BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (kill-local-variable 'ri-tabs--marked-p)
      (kill-local-variable 'ri-tabs--file-id))))

(defun ri-tabs--enforce-tab-bar ()
  "Reassert the native Tab Bar state owned by active Ri tabs.

This deliberately runs after initialization as well as during later
refreshes.  `ri-enable' is commonly called before the rest of init.el has
finished, so later user setup must not be able to leave `ri-tabs-mode' in
a contradictory state where the mode is active but its rendering surface
is disabled."
  (when ri-tabs-mode
    (setq-default tab-bar-format '(ri-tabs--format-tabs)
                  tab-bar-show t)
    (unless tab-bar-mode
      (tab-bar-mode 1))
    (dolist (frame (frame-list))
      (ri-tabs--configure-frame frame))))

(defun ri-tabs--refresh (&rest _ignored)
  "Invalidate every frame-wide Ri file Tab Bar and keep it visible."
  (when ri-tabs-mode
    (if ri-tabs--refresh-batching-p
        (setq ri-tabs--refresh-pending-p t)
      (ri-tabs--enforce-tab-bar)
      (force-mode-line-update t))))

(defun ri-tabs--updated-state (state file-id marked)
  "Return STATE with FILE-ID membership set to MARKED."
  (let ((files (and state (nth 3 state))))
    (ri-tabs--make-state
     (if marked
         (cons file-id files)
       (remove file-id files)))))

(defun ri-tabs--commit-state (state &optional file-ids)
  "Persist STATE, synchronize FILE-IDS, and refresh file tabs once.
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

(defun ri-tabs--state-for-hook ()
  "Return the activation snapshot or safely read current persistent state."
  (if ri-tabs--activation-active-p
      ri-tabs--activation-state
    (ri-tabs--read-state-safely)))

(defun ri-tabs--sync-visited-buffer ()
  "Restore the current file buffer's persistent mark and refresh tabs."
  (when ri-tabs-mode
    (if (ri-tabs--file-buffer-p (current-buffer))
        (let* ((file-id (ri-tabs--buffer-file-id (current-buffer)))
               (state (ri-tabs--state-for-hook)))
          (ri-tabs--set-buffer-cache
           (current-buffer) file-id
           (unless (eq state ri-tabs--read-error) state)))
      (ri-tabs--clear-buffer-cache (current-buffer)))
    (ri-tabs--refresh)))


(defun ri-tabs--sync-after-visited-file-name-change ()
  "Synchronize or migrate marks after the visited filename changes."
  (when ri-tabs-mode
    (let ((old-file-id ri-tabs--file-id)
          (new-file-id (ri-tabs--buffer-file-id (current-buffer))))
      (if (null new-file-id)
          (ri-tabs--clear-buffer-cache (current-buffer))
        (let ((state (ri-tabs--state-for-hook)))
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
          ))
      (ri-tabs--refresh))))

(defun ri-tabs--install-infrastructure ()
  "Install global hooks for file state, frames, and selected windows."
  (add-hook 'find-file-hook #'ri-tabs--sync-visited-buffer)
  (add-hook 'after-set-visited-file-name-hook
            #'ri-tabs--sync-after-visited-file-name-change)
  (add-hook 'kill-buffer-hook #'ri-tabs--refresh)
  (add-hook 'first-change-hook #'ri-tabs--refresh)
  (add-hook 'after-save-hook #'ri-tabs--refresh)
  (add-hook 'after-revert-hook #'ri-tabs--refresh)
  (add-hook 'window-selection-change-functions #'ri-tabs--refresh)
  (add-hook 'window-buffer-change-functions #'ri-tabs--refresh)
  (add-hook 'after-make-frame-functions #'ri-tabs--configure-new-frame))

(defun ri-tabs--remove-infrastructure ()
  "Remove every global hook installed by `ri-tabs-mode'."
  (remove-hook 'find-file-hook #'ri-tabs--sync-visited-buffer)
  (remove-hook 'after-set-visited-file-name-hook
               #'ri-tabs--sync-after-visited-file-name-change)
  (remove-hook 'kill-buffer-hook #'ri-tabs--refresh)
  (remove-hook 'first-change-hook #'ri-tabs--refresh)
  (remove-hook 'after-save-hook #'ri-tabs--refresh)
  (remove-hook 'after-revert-hook #'ri-tabs--refresh)
  (remove-hook 'window-selection-change-functions #'ri-tabs--refresh)
  (remove-hook 'window-buffer-change-functions #'ri-tabs--refresh)
  (remove-hook 'after-make-frame-functions #'ri-tabs--configure-new-frame))

(defun ri-tabs--cancel-pending-activation ()
  "Cancel any persistent Ki tab activation awaiting startup."
  (remove-hook 'emacs-startup-hook #'ri-tabs--startup-activate)
  (setq ri-tabs--activation-pending-p nil))

(defun ri-tabs--activate ()
  "Activate persistent marks and restore their available file buffers."
  (when (and ri-tabs-mode
             (not ri-tabs--activation-active-p)
             (not ri-tabs--activation-complete-p))
    (ri-tabs--cancel-pending-activation)
    (let ((ri-tabs--activation-active-p t)
          (ri-tabs--activation-state ri-tabs--read-error)
          (ri-tabs--refresh-batching-p t)
          (ri-tabs--refresh-pending-p nil)
          completed)
      (unwind-protect
          (progn
            (save-current-buffer
              (save-window-excursion
                (let ((state (ri-tabs--read-state-safely)))
                  (when (null state)
                    (condition-case err
                        (setq state
                              (ri-tabs--write-state
                               (ri-tabs--make-state
                                (mapcar
                                 #'ri-tabs--buffer-file-id
                                 (ri-tabs--file-buffer-list)))))
                      (error
                       (ri-tabs--warn-persistence "initialize" err)
                       (setq state ri-tabs--read-error))))
                  (setq ri-tabs--activation-state state)
                  (when (and ri-tabs-mode
                             (not (eq state ri-tabs--read-error)))
                    (ri-tabs--restore-marked-files state))
                  (when ri-tabs-mode
                    (ri-tabs--sync-live-buffers
                     (unless (eq state ri-tabs--read-error)
                       state))))))
            (setq completed t))
        (when (and completed ri-tabs-mode)
          (setq ri-tabs--activation-complete-p t))
        (when (and ri-tabs-mode
                   (or completed ri-tabs--refresh-pending-p))
          (ri-tabs--enforce-tab-bar)
          (force-mode-line-update t))))))

(defun ri-tabs--startup-activate ()
  "Run deferred persistent Ki tab activation after Emacs startup."
  (unwind-protect
      (when ri-tabs--activation-pending-p
        (setq ri-tabs--activation-pending-p nil)
        (remove-hook 'emacs-startup-hook #'ri-tabs--startup-activate)
        (when ri-tabs-mode
          (ri-tabs--activate)))
    (setq ri-tabs--activation-pending-p nil)
    (remove-hook 'emacs-startup-hook #'ri-tabs--startup-activate)))

(defun ri-tabs--schedule-activation ()
  "Schedule one persistent Ki tab activation after Emacs startup."
  (unless (or ri-tabs--activation-pending-p
              ri-tabs--activation-active-p
              ri-tabs--activation-complete-p)
    (setq ri-tabs--activation-pending-p t)
    (add-hook 'emacs-startup-hook #'ri-tabs--startup-activate t)))

(defun ri-tabs--enable ()
  "Install frame-wide tabs and activate persistent marks."
  (condition-case err
      (progn
        (ri-tabs--install-infrastructure)
        (ri-tabs--install-tab-bar)
        (cond
         ((or ri-tabs--activation-active-p
              ri-tabs--activation-complete-p)
          (ri-tabs--refresh))
         ((null after-init-time)
          (ri-tabs--schedule-activation)
          (ri-tabs--refresh))
         (t
          (ri-tabs--cancel-pending-activation)
          (ri-tabs--activate))))
    (error
     (setq ri-tabs-mode nil
           ri-tabs--activation-complete-p nil
           ri-tabs--refresh-pending-p nil)
     (ri-tabs--cancel-pending-activation)
     (ri-tabs--remove-infrastructure)
     (dolist (buffer (buffer-list))
       (ri-tabs--clear-buffer-cache buffer))
     (condition-case rollback-error
         (ri-tabs--restore-tab-bar-state)
       (error
        (display-warning
         'ri-tabs
         (format "Could not roll back failed Tab Bar installation: %s"
                 (error-message-string rollback-error))
         :error)))
     (signal (car err) (cdr err)))))

(defun ri-tabs--disable ()
  "Remove frame-wide tabs and caches without changing persistent marks."
  (let ((ri-tabs--refresh-batching-p t)
        (ri-tabs--refresh-pending-p nil))
    (ri-tabs--cancel-pending-activation)
    (setq ri-tabs--activation-complete-p nil)
    (ri-tabs--remove-infrastructure)
    (dolist (buffer (buffer-list))
      (ri-tabs--clear-buffer-cache buffer))
    (ri-tabs--restore-tab-bar-state))
  (setq ri-tabs--refresh-pending-p nil)
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode ri-tabs-mode
  "Display one frame-wide native Tab Bar for Ri file buffers.

Every ordinary frame shows the process-global set of live persistently
marked files.  The selected window's current unmarked file is appended
for that frame only, and selecting a tab changes only that window's
buffer.

On first activation, the mode marks and stores every visible file
buffer at the activation boundary.  Later activations reopen each
available persistently marked file that has no live buffer, without
displaying it or changing the selected window.  Activation requested
during initialization is deferred until `emacs-startup-hook'.

Closing a buffer never removes its mark or immediately reopens it; a
still-marked file returns on the next mode activation.  Explicit
unmark commands prevent that restoration.  Unavailable files remain
marked for a later activation.  Navigation considers live marked
buffers only."
  :global t
  :group 'ri-tabs
  (if ri-tabs-mode
      (ri-tabs--enable)
    (ri-tabs--disable)))

(provide 'ri-tabs)

;;; ri-tabs.el ends here
