;;; ri-tabs.el --- Ki-style tabs for open files -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.2"))
;; Keywords: convenience, files, tabs
;; URL: https://github.com/rofrol/ri-tabs

;;; Commentary:

;; `ri-tabs-mode' displays an owner-context set of persistently marked files
;; in one Ri-owned frame-wide tab surface per ordinary frame and appends that
;; frame's selected buffer while it is unmarked in the active owner set.  The
;; owner context of the first marked file owns the set, but files in that set
;; may live in any Git repository or outside Git.  Opening such a file never
;; changes the owner.  Marked tabs stay in path order.  Ordinary labels use
;; basenames; when names collide, the owner-local file stays short where possible
;; and foreign files receive the minimum parent-directory qualification needed
;; for disambiguation.  Tabs are content-sized and Ri explicitly packs complete
;; tabs into as many rows as the frame width requires.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'multisession)
(require 'seq)
(require 'subr-x)

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
  '((t :inherit mode-line-inactive
       :background "#989898"
       :box nil))
  "Face used for an inactive file tab."
  :group 'ri-tabs)

(defface ri-tabs-visible-tab
  '((t :inherit mode-line-inactive
       :background "#8faec7"
       :box nil))
  "Face used for an inactive tab visible in another window of the frame."
  :group 'ri-tabs)

(defface ri-tabs-bar
  '((t :background "#f4f4f4"))
  "Face used for the Ri-owned tab surface background."
  :group 'ri-tabs)

(defface ri-tabs-current-tab
  '((t :inherit mode-line-active
       :foreground "black"
       :background "#ffffff"
       :weight bold
       :box nil))
  "Face used for the current file tab."
  :group 'ri-tabs)

(defvar ri-tabs--surface-windows (make-hash-table :test #'eq)
  "Map live frames to their Ri tab surface windows.")

(defvar ri-tabs--surface-buffers (make-hash-table :test #'eq)
  "Map live frames to their Ri tab surface buffers.")

(defvar ri-tabs--layout-in-progress-p nil
  "Non-nil while an Ri tab surface is being created, laid out, or removed.")

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


(defvar ri-tabs--restored-owners (make-hash-table :test #'equal)
  "Owner contexts whose marked files were restored this enable.")

(defvar-local ri-tabs--marked-p nil
  "Deprecated local test/render hint; persistent state is the source of truth.")

(defvar-local ri-tabs--file-id nil
  "File identity last synchronized with persistent Ki tab marks.")

(defvar-local ri-tabs--owner-context-cache nil
  "Cached canonical owner context for the current visited file buffer.")

(defun ri-tabs--canonical-directory (directory)
  "Return DIRECTORY as a canonical absolute directory name."
  (when directory
    (file-name-as-directory (file-truename (expand-file-name directory)))))

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

(defun ri-tabs--buffer-directory (buffer)
  "Return BUFFER's canonical effective working directory.
Signal a user error unless BUFFER is a live visible file buffer with a usable
`default-directory'."
  (ri-tabs--require-file-id buffer)
  (with-current-buffer buffer
    (unless (and (stringp default-directory)
                 (file-directory-p default-directory))
      (user-error "Buffer has no usable current directory"))
    (ri-tabs--canonical-directory default-directory)))

(defun ri-tabs--git-work-tree-root (directory)
  "Return Git's canonical work-tree root for DIRECTORY, or nil.
Git itself is authoritative so process environment variables such as
GIT_DIR and GIT_WORK_TREE are honored."
  (when (and directory (executable-find "git"))
    (let ((default-directory (ri-tabs--canonical-directory directory)))
      (with-temp-buffer
        (when (eq 0 (process-file "git" nil t nil
                                  "rev-parse" "--show-toplevel"))
          (let ((root (string-trim (buffer-string))))
            (unless (string-empty-p root)
              (ri-tabs--canonical-directory root))))))))

(defun ri-tabs--buffer-git-root (buffer)
  "Return BUFFER's effective canonical Git work-tree root, or nil."
  (when (ri-tabs--file-buffer-p buffer)
    (ri-tabs--git-work-tree-root (ri-tabs--buffer-directory buffer))))

(defun ri-tabs--compute-buffer-owner-context (buffer)
  "Compute BUFFER's canonical marked-set owner context.
Prefer the effective Git work-tree root; outside Git use BUFFER's effective
current directory.  This function may invoke Git and therefore belongs only on
model-synchronization paths, never presentation repaint paths."
  (let ((directory (ri-tabs--buffer-directory buffer)))
    (or (ri-tabs--git-work-tree-root directory) directory)))

(defun ri-tabs--buffer-owner-context (buffer)
  "Return BUFFER's cached canonical marked-set owner context.
Populate the cache lazily for compatibility with buffers created before
`ri-tabs-mode' was enabled."
  (when (ri-tabs--file-buffer-p buffer)
    (with-current-buffer buffer
      (or ri-tabs--owner-context-cache
          (setq ri-tabs--owner-context-cache
                (ri-tabs--compute-buffer-owner-context buffer))))))

(defun ri-tabs--frame-owner (&optional frame)
  "Return FRAME's active marked-set owner context."
  (frame-parameter (or frame (selected-frame)) 'ri-tabs-owner))

(defun ri-tabs--set-frame-owner (frame owner)
  "Set FRAME's active marked-set OWNER context."
  (set-frame-parameter frame 'ri-tabs-owner
                       (and owner (ri-tabs--canonical-directory owner))))

(defun ri-tabs--buffer-less-p (left right)
  "Return non-nil when file buffer LEFT sorts before RIGHT."
  (let ((left-file (buffer-file-name left))
        (right-file (buffer-file-name right)))
    (if (equal left-file right-file)
        (string-lessp (buffer-name left) (buffer-name right))
      (string-lessp left-file right-file))))

(defun ri-tabs-file-buffer-list ()
  "Return all open file buffers in stable path order."
  (sort (seq-filter #'ri-tabs--file-buffer-p (buffer-list))
        #'ri-tabs--buffer-less-p))

(defun ri-tabs--normalize-files (files)
  "Return FILES deduplicated and sorted by canonical identity."
  (delete-dups (sort (mapcar #'expand-file-name (copy-sequence files))
                     #'string-lessp)))

(defun ri-tabs--make-state (&optional owners unresolved)
  "Return normalized version-3 state from OWNERS and UNRESOLVED.
OWNERS is an alist of (OWNER . FILES), where OWNER is a canonical directory."
  (let ((normalized-owners
         (mapcar (lambda (entry)
                   (cons (ri-tabs--canonical-directory (car entry))
                         (ri-tabs--normalize-files (cdr entry))))
                 owners)))
    (list :version 3
          :owners (sort normalized-owners
                        (lambda (a b) (string-lessp (car a) (car b))))
          :unresolved (ri-tabs--normalize-files unresolved))))

(defun ri-tabs--migrate-v1-state (files)
  "Convert legacy global marked FILES to one owner-context set."
  (let ((owner
         (seq-some
          (lambda (file)
            (let ((directory (file-name-directory file)))
              (or (ri-tabs--git-work-tree-root directory)
                  (and (file-directory-p directory)
                       (ri-tabs--canonical-directory directory)))))
          files)))
    (if owner
        (ri-tabs--make-state (list (cons owner files)))
      (ri-tabs--make-state nil files))))

(defun ri-tabs--valid-owner-alist-p (owners)
  "Return non-nil when OWNERS has the persistent owner-set shape."
  (and (proper-list-p owners)
       (seq-every-p
        (lambda (entry)
          (and (consp entry)
               (stringp (car entry))
               (proper-list-p (cdr entry))
               (seq-every-p #'stringp (cdr entry))))
        owners)))

(defun ri-tabs--normalize-state (state)
  "Validate and normalize persistent Ki tab mark STATE.
Nil remains uninitialized.  Versions 1 and 2 are migrated in memory to the
version-3 owner-context representation."
  (cond
   ((null state) nil)
   ((not (proper-list-p state))
    (error "Malformed persistent Ki tab marks: %S" state))
   ((eql (plist-get state :version) 1)
    (let ((files (plist-get state :files)))
      (unless (and (proper-list-p files) (seq-every-p #'stringp files))
        (error "Malformed persistent Ki tab marks: %S" state))
      (ri-tabs--migrate-v1-state files)))
   ((eql (plist-get state :version) 2)
    (let ((owners (plist-get state :repos))
          (unresolved (plist-get state :unresolved)))
      (unless (and (ri-tabs--valid-owner-alist-p owners)
                   (proper-list-p unresolved)
                   (seq-every-p #'stringp unresolved))
        (error "Malformed persistent Ki tab marks: %S" state))
      (ri-tabs--make-state owners unresolved)))
   ((eql (plist-get state :version) 3)
    (let ((owners (plist-get state :owners))
          (unresolved (plist-get state :unresolved)))
      (unless (and (ri-tabs--valid-owner-alist-p owners)
                   (proper-list-p unresolved)
                   (seq-every-p #'stringp unresolved))
        (error "Malformed persistent Ki tab marks: %S" state))
      (ri-tabs--make-state owners unresolved)))
   (t
    (error "Unsupported persistent Ki tab marks version: %S"
           (plist-get state :version)))))

(defun ri-tabs--read-state ()
  "Read and validate the latest persistent Ki tab mark state."
  (ri-tabs--normalize-state (multisession-value ri-tabs--marks-store)))

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

(defun ri-tabs--state-owner-files (state owner)
  "Return marked files belonging to OWNER in validated STATE."
  (and state owner (cdr (assoc owner (plist-get state :owners)))))

(defun ri-tabs--state-has-owner-p (state owner)
  "Return non-nil when STATE contains a marked set owned by OWNER."
  (and state owner (assoc owner (plist-get state :owners))))

(defun ri-tabs--state-marked-p (state owner file-id)
  "Return non-nil when FILE-ID is marked in OWNER's set in STATE."
  (and state owner file-id
       (member file-id (ri-tabs--state-owner-files state owner))))

(defun ri-tabs-buffer-marked-p (&optional buffer frame)
  "Return non-nil when BUFFER is marked in FRAME's active owner set.
BUFFER and FRAME default to the current buffer and selected frame."
  (let* ((buffer (or buffer (current-buffer)))
         (frame (or frame (selected-frame)))
         (owner (ri-tabs--frame-owner frame))
         (state (ri-tabs--read-state-safely))
         (file-id (and (buffer-live-p buffer)
                       (ri-tabs--buffer-file-id buffer))))
    (and (not (eq state ri-tabs--read-error))
         (ri-tabs--state-marked-p state owner file-id))))

(defun ri-tabs--sync-live-buffers (_state &optional file-ids)
  "Synchronize live file identity caches.
When FILE-IDS is non-nil, only synchronize buffers with those identities."
  (dolist (buffer (ri-tabs-file-buffer-list))
    (let ((file-id (ri-tabs--buffer-file-id buffer)))
      (when (or (null file-ids) (member file-id file-ids))
        (with-current-buffer buffer
          (setq ri-tabs--file-id file-id
                ri-tabs--owner-context-cache
                (ri-tabs--compute-buffer-owner-context buffer)))))))

(defun ri-tabs--live-file-index ()
  "Return an index of canonical identities represented by live buffers."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (buffer (ri-tabs-file-buffer-list))
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

(defun ri-tabs--restore-marked-files (state owner)
  "Restore missing marked file buffers for OWNER from validated STATE."
  (let ((live-index (ri-tabs--live-file-index))
        failures)
    (dolist (file-id (ri-tabs--state-owner-files state owner))
      (when (and ri-tabs-mode (not (gethash file-id live-index)))
        (condition-case err
            (if (not (file-exists-p file-id))
                (push (cons file-id "file does not exist") failures)
              (let* ((buffer (find-file-noselect file-id))
                     (resolved (and (bufferp buffer)
                                    (buffer-live-p buffer)
                                    (ri-tabs--buffer-file-id buffer))))
                (if (equal resolved file-id)
                    (puthash file-id t live-index)
                  (push (cons file-id
                              (if resolved
                                  (format "opened buffer resolves to %s" resolved)
                                "opening did not return a live visible file buffer"))
                        failures))))
          (error (push (cons file-id (error-message-string err)) failures)))))
    (setq failures (nreverse failures))
    (ri-tabs--warn-restore-failures failures)
    failures))

(defun ri-tabs--marked-buffer-list (&optional owner state)
  "Return live buffers marked in OWNER's set in stable path order."
  (setq owner (or owner (ri-tabs--frame-owner)))
  (setq state (or state (ri-tabs--read-state-safely)))
  (cond
   ((eq state ri-tabs--read-error) nil)
   (owner
    (seq-filter
     (lambda (buffer)
       (ri-tabs--state-marked-p state owner (ri-tabs--buffer-file-id buffer)))
     (ri-tabs-file-buffer-list)))
   (t
    (seq-filter
     (lambda (buffer)
       (buffer-local-value 'ri-tabs--marked-p buffer))
     (ri-tabs-file-buffer-list)))))

(defun ri-tabs--navigation-buffer-list (&optional owner state)
  "Return OWNER's marked buffers followed by all open owner-unmarked files."
  (setq owner (or owner (ri-tabs--frame-owner)))
  (setq state (or state (ri-tabs--read-state-safely)))
  (let (marked unmarked)
    (dolist (buffer (ri-tabs-file-buffer-list))
      (if (and owner (not (eq state ri-tabs--read-error))
               (ri-tabs--state-marked-p state owner
                                        (ri-tabs--buffer-file-id buffer)))
          (push buffer marked)
        (push buffer unmarked)))
    (nconc (nreverse marked) (nreverse unmarked))))

(defun ri-tabs--buffer-list (selected-buffer &optional owner state)
  "Return OWNER's marked buffers plus SELECTED-BUFFER when unmarked."
  (let ((marked (ri-tabs--marked-buffer-list owner state)))
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

(defun ri-tabs--buffer-in-owner-p (buffer owner)
  "Return non-nil when BUFFER belongs to OWNER.
OWNER is the active marked-set owner context.  Git roots are compared when
available; outside Git, the buffer's effective owner directory is compared
directly with OWNER."
  (and owner
       (equal (ri-tabs--buffer-owner-context buffer)
              (ri-tabs--canonical-directory owner))))

(defun ri-tabs--shortest-distinguishing-suffix (buffer comparison-buffers
                                                        &optional min-width)
  "Return BUFFER's shortest path suffix distinct from COMPARISON-BUFFERS.
MIN-WIDTH defaults to 1 path component.  The caller can pass 2 when BUFFER's
basename is already known to collide and therefore parent context is required."
  (let* ((parts (ri-tabs--path-parts (buffer-file-name buffer)))
         (other-parts
          (mapcar (lambda (other)
                    (ri-tabs--path-parts (buffer-file-name other)))
                  comparison-buffers))
         (width (min (max 1 (or min-width 1)) (length parts)))
         (limit (length parts)))
    (while (and (< width limit)
                (seq-some
                 (lambda (candidate)
                   (ri-tabs--same-suffix-p parts candidate width))
                 other-parts))
      (setq width (1+ width)))
    (string-join (last parts width) "/")))

(defun ri-tabs--tab-name (buffer buffers &optional owner)
  "Return BUFFER's deterministic file label among BUFFERS for OWNER.
A unique basename is kept as-is.  For duplicate basenames, a sole owner-local
file keeps the basename while foreign files gain the shortest sufficient path
suffix.  Multiple owner-local duplicates are qualified as needed so all labels
remain unambiguous."
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
      (let* ((duplicates (cons buffer same-base))
             (owner-local
              (seq-filter (lambda (candidate)
                            (ri-tabs--buffer-in-owner-p candidate owner))
                          duplicates)))
        (if (and (memq buffer owner-local)
                 (= (length owner-local) 1))
            base
          (ri-tabs--shortest-distinguishing-suffix
           buffer same-base 2)))))))

(defun ri-tabs--tab-face (state)
  "Return the tab face for semantic STATE."
  (pcase state
    ('active 'ri-tabs-current-tab)
    ('visible 'ri-tabs-visible-tab)
    ('inactive 'ri-tabs-tab)
    (_ (error "Unknown Ri tab state: %S" state))))

(defun ri-tabs--marker (buffer owner state)
  "Return BUFFER's marker in OWNER's marked set from STATE."
  (let ((marked (if (and state owner)
                    (ri-tabs--state-marked-p
                     state owner (ri-tabs--buffer-file-id buffer))
                  (buffer-local-value 'ri-tabs--marked-p buffer))))
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
  "Return non-nil when FRAME should display an Ri file tab surface.

Ri owns one dedicated top side-window surface on every ordinary top-level
frame while the mode is active.  Structural auxiliary frames are excluded."
  (and (frame-live-p frame)
       (not (ri-tabs--structurally-ineligible-frame-p frame))))


(defun ri-tabs--surface-window-p (window)
  "Return non-nil when WINDOW is an Ri-owned tab surface."
  (and (window-live-p window)
       (window-parameter window 'ri-tabs-surface)))

(defun ri-tabs--frame-selected-window (frame)
  "Return FRAME's selected ordinary editing window.
While FRAME's minibuffer or Ri surface is selected, prefer the live ordinary
window most recently used for editing on that frame."
  (when (frame-live-p frame)
    (let* ((minibuffer (active-minibuffer-window))
           (origin (and minibuffer (minibuffer-selected-window)))
           (selected (frame-selected-window frame))
           (remembered (frame-parameter frame 'ri-tabs-last-editing-window))
           window)
      (setq window
            (cond
             ((and (window-live-p origin)
                   (eq (window-frame origin) frame)
                   (not (window-minibuffer-p origin))
                   (not (ri-tabs--surface-window-p origin)))
              origin)
             ((and (window-live-p selected)
                   (not (window-minibuffer-p selected))
                   (not (ri-tabs--surface-window-p selected)))
              selected)
             ((and (window-live-p remembered)
                   (eq (window-frame remembered) frame)
                   (not (window-minibuffer-p remembered))
                   (not (ri-tabs--surface-window-p remembered)))
              remembered)
             (t
              (seq-find (lambda (candidate)
                          (and (window-live-p candidate)
                               (not (window-minibuffer-p candidate))
                               (not (ri-tabs--surface-window-p candidate))))
                        (window-list frame 'nomini)))))
      (when window
        (set-frame-parameter frame 'ri-tabs-last-editing-window window))
      window)))

(defun ri-tabs--ordinary-window-buffers (frame)
  "Return buffers displayed in live ordinary editing windows of FRAME."
  (let (buffers)
    (dolist (window (window-list frame 'nomini))
      (when (and (window-live-p window)
                 (not (window-minibuffer-p window))
                 (not (ri-tabs--surface-window-p window)))
        (cl-pushnew (window-buffer window) buffers :test #'eq)))
    buffers))

(defun ri-tabs--buffer-state (buffer selected-buffer visible-buffers)
  "Classify BUFFER relative to SELECTED-BUFFER and VISIBLE-BUFFERS."
  (cond
   ((eq buffer selected-buffer) 'active)
   ((memq buffer visible-buffers) 'visible)
   (t 'inactive)))

(defun ri-tabs--tab-label (buffer tab-name tab-state &optional owner state)
  "Return BUFFER's final propertized tab label using TAB-NAME and TAB-STATE.
TAB-NAME is precomputed by the structural renderer so name resolution is
performed only once per tab."
  (let* ((file (abbreviate-file-name (buffer-file-name buffer)))
         (help (if (eq tab-state 'active)
                   (format "Current file: %s" file)
                 (format "Switch to %s" file))))
    (propertize
     (format " %s %s "
             (ri-tabs--marker buffer owner state)
             tab-name)
     'face (ri-tabs--tab-face tab-state)
     'help-echo help)))

(cl-defstruct (ri-tabs--item (:constructor ri-tabs--make-item))
  "Renderer-independent description of one visible Ri tab."
  buffer label display state marked modified)

(defun ri-tabs--visible-items (&optional frame)
  "Return ordered renderer-independent visible tab items for FRAME."
  (setq frame (or frame (selected-frame)))
  (when (ri-tabs--frame-eligible-p frame)
    (let* ((window (ri-tabs--frame-selected-window frame))
           (selected-buffer (and window (window-buffer window)))
           (visible-buffers (ri-tabs--ordinary-window-buffers frame))
           (owner (ri-tabs--frame-owner frame))
           (state (ri-tabs--read-state-safely))
           (buffers (ri-tabs--buffer-list selected-buffer owner state)))
      (mapcar
       (lambda (buffer)
         (let* ((file-id (ri-tabs--buffer-file-id buffer))
                (marked (if (and owner (not (eq state ri-tabs--read-error)))
                            (ri-tabs--state-marked-p state owner file-id)
                          (buffer-local-value 'ri-tabs--marked-p buffer)))
                (tab-state (ri-tabs--buffer-state
                            buffer selected-buffer visible-buffers))
                (label (ri-tabs--tab-name buffer buffers owner))
                (display (ri-tabs--tab-label
                          buffer label tab-state owner state)))
           (ri-tabs--make-item
            :buffer buffer
            :label label
            :display display
            :state tab-state
            :marked marked
            :modified (buffer-modified-p buffer))))
       buffers))))

(defvar ri-tabs--surface-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'ri-tabs--mouse-select)
    (define-key map [drag-mouse-1] #'ignore)
    (define-key map [mouse-1] #'ignore)
    (define-key map [mouse-2] #'ri-tabs--mouse-close)
    (define-key map [down-mouse-3] #'ri-tabs--mouse-context-menu)
    (define-key map [mouse-4] #'ri-tabs--mouse-previous)
    (define-key map [mouse-5] #'ri-tabs--mouse-next)
    (define-key map [wheel-up] #'ri-tabs--mouse-previous)
    (define-key map [wheel-down] #'ri-tabs--mouse-next)
    (define-key map [wheel-left] #'ri-tabs--mouse-previous)
    (define-key map [wheel-right] #'ri-tabs--mouse-next)
    (define-key map [S-mouse-4] #'ignore)
    (define-key map [S-mouse-5] #'ignore)
    (define-key map [S-wheel-up] #'ignore)
    (define-key map [S-wheel-down] #'ignore)
    (define-key map [S-wheel-left] #'ignore)
    (define-key map [S-wheel-right] #'ignore)
    (define-key map [touchscreen-begin] #'ri-tabs--touchscreen-begin)
    map)
  "Keymap used by Ri-owned tab surface buffers.")

(defun ri-tabs--prepare-item-display (frame item)
  "Return ITEM's display string with direct FRAME/buffer hit-test properties."
  (let ((text (copy-sequence (ri-tabs--item-display item))))
    (when (> (length text) 0)
      (add-text-properties
       0 (length text)
       (list 'ri-tabs-frame frame
             'ri-tabs-buffer (ri-tabs--item-buffer item)
             'pointer 'hand)
       text))
    text))

(defun ri-tabs--surface-buffer (frame)
  "Return FRAME's live internal Ri tab surface buffer, creating it if needed."
  (let ((existing (gethash frame ri-tabs--surface-buffers)))
    (if (buffer-live-p existing)
        existing
      (let ((buffer (generate-new-buffer " *ri-tabs*")))
        (with-current-buffer buffer
          (setq-local buffer-read-only t
                      cursor-type nil
                      mode-line-format nil
                      header-line-format nil
                      tab-line-format nil
                      truncate-lines t
                      word-wrap nil
                      buffer-face-mode-face 'ri-tabs-bar)
          (buffer-face-mode 1)
          (buffer-disable-undo)
          (use-local-map ri-tabs--surface-mode-map))
        (puthash frame buffer ri-tabs--surface-buffers)
        buffer))))

(defun ri-tabs--surface-window (frame)
  "Return FRAME's Ri tab side window, creating it when necessary."
  (let* ((buffer (and (ri-tabs--frame-eligible-p frame)
                      (ri-tabs--surface-buffer frame)))
         (existing (gethash frame ri-tabs--surface-windows)))
    (if (and (window-live-p existing)
             (eq (window-frame existing) frame)
             (eq (window-buffer existing) buffer))
        existing
      (when (window-live-p existing)
        (let ((ri-tabs--layout-in-progress-p t))
          (ignore-errors
            (set-window-dedicated-p existing nil)
            (delete-window existing))))
      (remhash frame ri-tabs--surface-windows)
      (when buffer
        (let ((ri-tabs--layout-in-progress-p t)
              window)
          (with-selected-frame frame
            (setq window
                  (display-buffer-in-side-window
                   buffer
                   '((side . top)
                     (slot . -100)
                     (window-height . 1)
                     (window-parameters
                      . ((no-other-window . t)
                         (no-delete-other-windows . t)))))))
          (when (window-live-p window)
            (set-window-dedicated-p window t)
            (set-window-parameter window 'ri-tabs-surface t)
            (set-window-parameter window 'no-other-window t)
            (set-window-parameter window 'no-delete-other-windows t)
            (set-window-fringes window 0 0)
            (ignore-errors (set-window-scroll-bars window 0 nil nil))
            (puthash frame window ri-tabs--surface-windows))
          window)))))

(defun ri-tabs--display-width (window string)
  "Return STRING's rendered width for WINDOW.
Graphical frames use pixel measurement when available; terminals use display
columns."
  (if (and (window-live-p window)
           (display-graphic-p (window-frame window))
           (fboundp 'string-pixel-width))
      (with-selected-window window
        (string-pixel-width string))
    (string-width string)))

(defun ri-tabs--available-width (window)
  "Return the horizontal width available for Ri tabs in WINDOW."
  (max 1
       (if (and (window-live-p window)
                (display-graphic-p (window-frame window))
                (fboundp 'string-pixel-width))
           (window-body-width window t)
         (window-body-width window))))

(defun ri-tabs--pack-items-into-rows (measured-items available-width)
  "Greedily pack MEASURED-ITEMS into rows no wider than AVAILABLE-WIDTH.
MEASURED-ITEMS is a list of (ITEM . WIDTH).  Item order is preserved and no
item is split.  An item wider than AVAILABLE-WIDTH occupies a row by itself."
  (let (rows row (row-width 0))
    (dolist (entry measured-items)
      (let ((width (max 0 (cdr entry))))
        (if (and row (> (+ row-width width) available-width))
            (progn
              (push (nreverse row) rows)
              (setq row (list (car entry))
                    row-width width))
          (push (car entry) row)
          (setq row-width (+ row-width width)))))
    (when row
      (push (nreverse row) rows))
    (nreverse rows)))

(defun ri-tabs--render-rows (frame rows)
  "Return propertized text for FRAME representing packed ROWS explicitly."
  (if (null rows)
      " "
    (mapconcat
     (lambda (row)
       (mapconcat
        (lambda (item) (ri-tabs--prepare-item-display frame item))
        row ""))
     rows "\n")))

(defun ri-tabs--set-surface-height (window rows)
  "Resize Ri surface WINDOW to exactly ROWS text rows where possible."
  (when (window-live-p window)
    (let* ((target (max 1 rows))
           (current (window-total-height window))
           (delta (- target current)))
      (unless (zerop delta)
        (condition-case nil
            (window-resize window delta nil t)
          (error
           (ignore-errors
             (fit-window-to-buffer window target target))))))))

(defun ri-tabs--surface-update (frame)
  "Rebuild FRAME's complete Ri tab surface from model through layout."
  (when (and ri-tabs-mode
             (frame-live-p frame)
             (ri-tabs--frame-eligible-p frame))
    (let ((ri-tabs--layout-in-progress-p t))
      (when-let* ((window (ri-tabs--surface-window frame)))
        (let* ((items (or (ri-tabs--visible-items frame) nil))
               (display-items
                (mapcar
                 (lambda (item)
                   (setf (ri-tabs--item-display item)
                         (ri-tabs--prepare-item-display frame item))
                   item)
                 items))
               (available (ri-tabs--available-width window))
               (measured
                (mapcar
                 (lambda (item)
                   (cons item
                         (ri-tabs--display-width
                          window (ri-tabs--item-display item))))
                 display-items))
               (rows (ri-tabs--pack-items-into-rows measured available))
               (text (ri-tabs--render-rows frame rows))
               (buffer (window-buffer window)))
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert text)
              (goto-char (point-min))))
          (set-window-point window
                            (with-current-buffer buffer (point-min)))
          (ri-tabs--set-surface-height window (max 1 (length rows)))
          (set-window-parameter window 'ri-tabs-rows rows)
          (set-window-parameter window 'ri-tabs-selected-buffer
                                (and (ri-tabs--frame-selected-window frame)
                                     (window-buffer
                                      (ri-tabs--frame-selected-window frame))))
          (set-window-parameter window 'ri-tabs-layout-width available))))))


(defun ri-tabs--row-items (rows)
  "Return a flat list of items from packed ROWS."
  (apply #'append (copy-sequence rows)))

(defun ri-tabs--surface-item-for-buffer (window buffer)
  "Return WINDOW's cached rendered item for BUFFER, or nil."
  (seq-find (lambda (item) (eq (ri-tabs--item-buffer item) buffer))
            (ri-tabs--row-items (or (window-parameter window 'ri-tabs-rows) nil))))

(defun ri-tabs--set-tab-face-in-surface (window buffer state)
  "Set BUFFER's tab face in WINDOW to semantic STATE in place."
  (when (and (window-live-p window) (buffer-live-p buffer))
    (with-current-buffer (window-buffer window)
      (let ((inhibit-read-only t)
            (pos (point-min)))
        (while (< pos (point-max))
          (let ((next (next-single-property-change
                       pos 'ri-tabs-buffer nil (point-max))))
            (when (eq (get-text-property pos 'ri-tabs-buffer) buffer)
              (put-text-property pos next 'face (ri-tabs--tab-face state)))
            (setq pos next)))))))

(defun ri-tabs--reconcile-frame-tab-states (frame)
  "Reconcile cached semantic tab states for FRAME without relayout."
  (let* ((window (gethash frame ri-tabs--surface-windows))
         (editing-window (ri-tabs--frame-selected-window frame))
         (selected-buffer (and editing-window (window-buffer editing-window)))
         (old-selected (and (window-live-p window)
                            (window-parameter window 'ri-tabs-selected-buffer)))
         (old-selected-item
          (and (window-live-p window) old-selected
               (ri-tabs--surface-item-for-buffer window old-selected)))
         (selected-item
          (and (window-live-p window) selected-buffer
               (ri-tabs--surface-item-for-buffer window selected-buffer))))
    (cond
     ((or (not (window-live-p window))
          (not selected-item)
          (and old-selected-item
               (not (ri-tabs--item-marked old-selected-item))
               (not (eq old-selected selected-buffer))))
      nil)
     (t
      (let ((visible-buffers (ri-tabs--ordinary-window-buffers frame))
            (ri-tabs--layout-in-progress-p t))
        (dolist (item (ri-tabs--row-items
                       (or (window-parameter window 'ri-tabs-rows) nil)))
          (let* ((buffer (ri-tabs--item-buffer item))
                 (desired (ri-tabs--buffer-state
                           buffer selected-buffer visible-buffers)))
            (unless (eq desired (ri-tabs--item-state item))
              (setf (ri-tabs--item-state item) desired)
              (ri-tabs--set-tab-face-in-surface window buffer desired))))
        (set-window-parameter window 'ri-tabs-selected-buffer selected-buffer)
        t)))))

(defun ri-tabs--selection-update-frame (frame)
  "Update FRAME tab states in place, falling back to structural refresh."
  (when (and ri-tabs-mode
             (frame-live-p frame)
             (ri-tabs--frame-eligible-p frame)
             (not ri-tabs--layout-in-progress-p))
    (unless (ri-tabs--reconcile-frame-tab-states frame)
      (ri-tabs--surface-update frame))))

(defun ri-tabs--change-frame (args)
  "Return the frame affected by hook ARGS, defaulting to selected frame."
  (or (seq-some (lambda (arg)
                  (cond
                   ((framep arg) arg)
                   ((windowp arg) (window-frame arg))))
                args)
      (selected-frame)))

(defun ri-tabs--selection-changed (&rest args)
  "Handle selected-window/buffer changes without rebuilding every frame."
  (when ri-tabs-mode
    (ri-tabs--selection-update-frame (ri-tabs--change-frame args))))

(defun ri-tabs--window-configuration-changed ()
  "Reconcile tab states after an editing-window layout change."
  (when ri-tabs-mode
    (ri-tabs--selection-update-frame (selected-frame))))

(defun ri-tabs--remove-surface (frame)
  "Remove every Ri-owned UI resource associated with FRAME."
  (let ((window (gethash frame ri-tabs--surface-windows))
        (buffer (gethash frame ri-tabs--surface-buffers))
        (ri-tabs--layout-in-progress-p t))
    (remhash frame ri-tabs--surface-windows)
    (remhash frame ri-tabs--surface-buffers)
    (when (frame-live-p frame)
      (set-frame-parameter frame 'ri-tabs-last-editing-window nil))
    (when (window-live-p window)
      (ignore-errors (delete-window window)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun ri-tabs--remove-all-surfaces ()
  "Remove all Ri-owned tab surface windows and buffers."
  (let (frames)
    (maphash (lambda (frame _window) (push frame frames))
             ri-tabs--surface-windows)
    (maphash (lambda (frame _buffer) (cl-pushnew frame frames :test #'eq))
             ri-tabs--surface-buffers)
    (dolist (frame frames)
      (ri-tabs--remove-surface frame))
    (setq ri-tabs--surface-windows (make-hash-table :test #'eq)
          ri-tabs--surface-buffers (make-hash-table :test #'eq))))

(defun ri-tabs--install-surfaces ()
  "Create/update one Ri-owned frame-wide tab surface per eligible frame."
  (dolist (frame (frame-list))
    (if (ri-tabs--frame-eligible-p frame)
        (ri-tabs--surface-update frame)
      (ri-tabs--remove-surface frame))))

(defun ri-tabs--event-position (event)
  "Return the mouse or touch position carried by EVENT."
  (cond
   ((and (consp event)
         (eq (car event) 'touchscreen-begin))
    (cdadr event))
   (t
    (event-start event))))

(defun ri-tabs--event-target (event &optional position)
  "Decode EVENT at POSITION into (FRAME WINDOW BUFFER).
Target identity comes directly from text properties rendered by Ri."
  (let* ((position (or position (ri-tabs--event-position event)))
         (window (and position (posn-window position)))
         (point (and position (posn-point position)))
         (frame (cond
                 ((windowp window) (window-frame window))
                 ((framep window) window)
                 (t (selected-frame))))
         buffer)
    (when (and (windowp window)
               (ri-tabs--surface-window-p window)
               (integer-or-marker-p point))
      (with-current-buffer (window-buffer window)
        (when (and (>= point (point-min)) (< point (point-max)))
          (setq buffer (get-text-property point 'ri-tabs-buffer)))))
    (list frame window buffer)))

(defun ri-tabs--select-buffer (frame buffer)
  "Display live BUFFER in FRAME's selected ordinary editing window."
  (if (and (frame-live-p frame) (buffer-live-p buffer))
      (if-let* ((window (ri-tabs--frame-selected-window frame)))
          (progn
            ;; A mouse command can originate in the Ri side window.  Leave the
            ;; frame focused on the editing window, never on the UI surface.
            (select-window window)
            (switch-to-buffer buffer)
            (set-frame-parameter frame 'ri-tabs-last-editing-window window))
        (ri-tabs--surface-update frame))
    (ri-tabs--surface-update frame)))

(defun ri-tabs--close-buffer (buffer)
  "Kill live BUFFER without changing its persistent Ri mark."
  (if (buffer-live-p buffer)
      (kill-buffer buffer)
    (ri-tabs--refresh)))

(defun ri-tabs--toggle-buffer-from-tab (frame buffer)
  "Toggle live BUFFER's persistent mark in FRAME's active owner set."
  (if (and (frame-live-p frame) (buffer-live-p buffer))
      (with-selected-frame frame
        (ri-tabs-toggle-buffer-mark buffer))
    (ri-tabs--refresh)))

(defun ri-tabs--mouse-switch-relative (event offset)
  "Switch OFFSET file tabs in the editing window targeted by mouse EVENT."
  (let* ((position (ri-tabs--event-position event))
         (location (and position (posn-window position)))
         (frame (cond
                 ((windowp location) (window-frame location))
                 ((framep location) location)
                 (t (selected-frame)))))
    (when-let* ((window (ri-tabs--frame-selected-window frame)))
      (select-window window)
      (ri-tabs--switch-to-relative-buffer offset)
      (set-frame-parameter frame 'ri-tabs-last-editing-window window))))

(defun ri-tabs--mouse-previous (event)
  "Switch to the previous file from Ri surface mouse EVENT."
  (interactive "e")
  (ri-tabs--mouse-switch-relative event -1))

(defun ri-tabs--mouse-next (event)
  "Switch to the next file from Ri surface mouse EVENT."
  (interactive "e")
  (ri-tabs--mouse-switch-relative event 1))

(defun ri-tabs--mouse-select (event)
  "Select the Ri file tab clicked by EVENT."
  (interactive "e")
  (pcase-let ((`(,frame ,_window ,buffer) (ri-tabs--event-target event)))
    (when buffer
      (ri-tabs--select-buffer frame buffer))))

(defun ri-tabs--mouse-close (event)
  "Close the Ri file tab clicked by EVENT."
  (interactive "e")
  (pcase-let ((`(,_frame ,_window ,buffer) (ri-tabs--event-target event)))
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
        ,(if (ri-tabs-buffer-marked-p buffer frame) "Unmark" "Mark")
        ,(lambda ()
           (interactive)
           (ri-tabs--toggle-buffer-from-tab frame buffer))
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
  (pcase-let ((`(,frame ,_window ,buffer)
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
  "Select or open a context menu for touchscreen EVENT."
  (interactive "e")
  (let* ((position (ri-tabs--event-position event))
         (target (ri-tabs--event-target event position))
         (frame (nth 0 target))
         (buffer (nth 2 target))
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
                     (ri-tabs--select-buffer frame buffer)))
               (when timer
                 (cancel-timer timer))))
           'context-menu)
        (popup-menu (ri-tabs--context-menu frame buffer) event)))))

(defun ri-tabs--configure-new-frame (frame)
  "Initialize newly created FRAME while `ri-tabs-mode' is active."
  (when ri-tabs-mode
    (if (ri-tabs--frame-eligible-p frame)
        (let ((state (ri-tabs--state-for-hook)))
          (unless (eq state ri-tabs--read-error)
            (ri-tabs--sync-live-buffers state))
          (ri-tabs--surface-update frame))
      (ri-tabs--remove-surface frame))))

(defun ri-tabs--frame-deleted (frame)
  "Forget Ri-owned renderer resources belonging to deleted FRAME."
  (let ((buffer (gethash frame ri-tabs--surface-buffers)))
    (remhash frame ri-tabs--surface-windows)
    (remhash frame ri-tabs--surface-buffers)
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun ri-tabs--window-size-changed (frame)
  "Re-layout FRAME after a width/geometry change."
  (when (and ri-tabs-mode
             (not ri-tabs--layout-in-progress-p)
             (frame-live-p frame))
    (if (ri-tabs--frame-eligible-p frame)
        (ri-tabs--surface-update frame)
      (ri-tabs--remove-surface frame))))

(defun ri-tabs--clear-buffer-cache (buffer)
  "Remove Ri-owned persistent-state cache variables from BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (kill-local-variable 'ri-tabs--marked-p)
      (kill-local-variable 'ri-tabs--file-id)
      (kill-local-variable 'ri-tabs--owner-context-cache))))

(defun ri-tabs--refresh (&rest _ignored)
  "Rebuild every eligible Ri-owned frame-wide tab surface."
  (when (and ri-tabs-mode (not ri-tabs--layout-in-progress-p))
    (if ri-tabs--refresh-batching-p
        (setq ri-tabs--refresh-pending-p t)
      (let ((ri-tabs--layout-in-progress-p t))
        (dolist (frame (frame-list))
          (if (ri-tabs--frame-eligible-p frame)
              (ri-tabs--surface-update frame)
            (ri-tabs--remove-surface frame)))))))

(defun ri-tabs--updated-state (state owner file-id marked)
  "Return STATE with FILE-ID membership in OWNER set to MARKED."
  (setq state (or state (ri-tabs--make-state)))
  (let* ((owners (copy-tree (plist-get state :owners)))
         (entry (assoc owner owners))
         (files (and entry (cdr entry)))
         (new-files (if marked
                        (ri-tabs--normalize-files (cons file-id files))
                      (remove file-id files))))
    (if entry
        (setcdr entry new-files)
      (push (cons owner new-files) owners))
    (ri-tabs--make-state owners (plist-get state :unresolved))))

(defun ri-tabs--replace-file-id (state old-file-id new-file-id)
  "Replace OLD-FILE-ID with NEW-FILE-ID in every marked set in STATE."
  (if (or (null state) (equal old-file-id new-file-id))
      state
    (let ((owners
           (mapcar
            (lambda (entry)
              (cons (car entry)
                    (ri-tabs--normalize-files
                     (mapcar (lambda (file)
                               (if (equal file old-file-id) new-file-id file))
                             (cdr entry)))))
            (plist-get state :owners)))
          (unresolved
           (ri-tabs--normalize-files
            (mapcar (lambda (file)
                      (if (equal file old-file-id) new-file-id file))
                    (plist-get state :unresolved)))))
      (ri-tabs--make-state owners unresolved))))

(defun ri-tabs--commit-state (state &optional file-ids)
  "Persist STATE, synchronize FILE-IDS, and refresh file tabs once."
  (setq state (ri-tabs--write-state state))
  (ri-tabs--sync-live-buffers state file-ids)
  (ri-tabs--refresh)
  state)

(defun ri-tabs--owner-for-mark (buffer frame state)
  "Return owner for marking BUFFER in FRAME, establishing it if needed."
  (or (ri-tabs--frame-owner frame)
      (let ((owner (ri-tabs--buffer-owner-context buffer)))
        (ri-tabs--set-frame-owner frame owner)
        ;; Existing persisted membership for this owner may need restoration.
        (when (ri-tabs--state-has-owner-p state owner)
          (ri-tabs--activate-owner owner state))
        owner)))

(defun ri-tabs-mark-buffer (&optional buffer)
  "Persistently mark BUFFER in the active owner-context marked set."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (frame (selected-frame))
         (file-id (ri-tabs--require-file-id buffer))
         (state (or (ri-tabs--read-state) (ri-tabs--make-state)))
         (owner (ri-tabs--owner-for-mark buffer frame state)))
    (ri-tabs--commit-state
     (ri-tabs--updated-state state owner file-id t)
     (list file-id))))

(defun ri-tabs-unmark-buffer (&optional buffer)
  "Persistently unmark BUFFER in the active owner-context marked set."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (file-id (ri-tabs--require-file-id buffer))
         (owner (ri-tabs--frame-owner))
         (state (or (ri-tabs--read-state) (ri-tabs--make-state))))
    (unless owner (user-error "No active marked-set owner context"))
    (ri-tabs--commit-state
     (ri-tabs--updated-state state owner file-id nil)
     (list file-id))))

(defun ri-tabs-toggle-buffer-mark (&optional buffer)
  "Toggle BUFFER's mark in the active owner-context marked set."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (frame (selected-frame))
         (file-id (ri-tabs--require-file-id buffer))
         (state (or (ri-tabs--read-state) (ri-tabs--make-state)))
         (owner (or (ri-tabs--frame-owner frame)
                    (ri-tabs--owner-for-mark buffer frame state))))
    (ri-tabs--commit-state
     (ri-tabs--updated-state
      state owner file-id (not (ri-tabs--state-marked-p state owner file-id)))
     (list file-id))))

(defun ri-tabs-switch-owner-context (&optional buffer)
  "Switch this frame's marked-set owner to BUFFER's owner context.
The owner is Git's effective work-tree root, or BUFFER's current directory
outside Git.  Opening files never changes the owner implicitly."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (owner (ri-tabs--buffer-owner-context buffer)))
    (ri-tabs--set-frame-owner (selected-frame) owner)
    (ri-tabs--activate-owner owner)
    (ri-tabs--refresh)
    owner))

(defalias 'ri-tabs-switch-repository #'ri-tabs-switch-owner-context)

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
  "Unmark every file except the current marked file in the active owner set."
  (interactive)
  (let* ((file-id (ri-tabs--require-file-id (current-buffer)))
         (owner (ri-tabs--frame-owner))
         (state (or (ri-tabs--read-state) (ri-tabs--make-state))))
    (unless owner (user-error "No active marked-set owner context"))
    (let ((owners (copy-tree (plist-get state :owners)))
          (keep (and (ri-tabs--state-marked-p state owner file-id)
                     (list file-id))))
      (if-let* ((entry (assoc owner owners)))
          (setcdr entry keep)
        (push (cons owner keep) owners))
      (ri-tabs--commit-state
       (ri-tabs--make-state owners (plist-get state :unresolved))))))

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
  "Synchronize current file identity and refresh tabs without changing owner."
  (when ri-tabs-mode
    (if (ri-tabs--file-buffer-p (current-buffer))
        (setq ri-tabs--file-id (ri-tabs--buffer-file-id (current-buffer))
              ri-tabs--owner-context-cache
              (ri-tabs--compute-buffer-owner-context (current-buffer)))
      (ri-tabs--clear-buffer-cache (current-buffer)))
    (ri-tabs--refresh)))

(defun ri-tabs--sync-after-visited-file-name-change ()
  "Migrate a changed file identity across every owner-context marked set."
  (when ri-tabs-mode
    (let ((old-file-id ri-tabs--file-id)
          (new-file-id (ri-tabs--buffer-file-id (current-buffer))))
      (if (null new-file-id)
          (ri-tabs--clear-buffer-cache (current-buffer))
        (let ((state (ri-tabs--state-for-hook)))
          (setq ri-tabs--file-id new-file-id
                ri-tabs--owner-context-cache
                (ri-tabs--compute-buffer-owner-context (current-buffer)))
          (when (and old-file-id
                     (not (equal old-file-id new-file-id))
                     (not (eq state ri-tabs--read-error)))
            (condition-case err
                (ri-tabs--commit-state
                 (ri-tabs--replace-file-id state old-file-id new-file-id)
                 (list old-file-id new-file-id))
              (error
               (ri-tabs--warn-persistence "migrate" err))))))
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
  (add-hook 'window-selection-change-functions #'ri-tabs--selection-changed)
  (add-hook 'window-buffer-change-functions #'ri-tabs--selection-changed)
  (add-hook 'window-size-change-functions #'ri-tabs--window-size-changed)
  (add-hook 'window-configuration-change-hook
            #'ri-tabs--window-configuration-changed)
  (add-hook 'after-make-frame-functions #'ri-tabs--configure-new-frame)
  (add-hook 'delete-frame-functions #'ri-tabs--frame-deleted))

(defun ri-tabs--remove-infrastructure ()
  "Remove every global hook installed by `ri-tabs-mode'."
  (remove-hook 'find-file-hook #'ri-tabs--sync-visited-buffer)
  (remove-hook 'after-set-visited-file-name-hook
               #'ri-tabs--sync-after-visited-file-name-change)
  (remove-hook 'kill-buffer-hook #'ri-tabs--refresh)
  (remove-hook 'first-change-hook #'ri-tabs--refresh)
  (remove-hook 'after-save-hook #'ri-tabs--refresh)
  (remove-hook 'after-revert-hook #'ri-tabs--refresh)
  (remove-hook 'window-selection-change-functions #'ri-tabs--selection-changed)
  (remove-hook 'window-buffer-change-functions #'ri-tabs--selection-changed)
  (remove-hook 'window-size-change-functions #'ri-tabs--window-size-changed)
  (remove-hook 'window-configuration-change-hook
               #'ri-tabs--window-configuration-changed)
  (remove-hook 'after-make-frame-functions #'ri-tabs--configure-new-frame)
  (remove-hook 'delete-frame-functions #'ri-tabs--frame-deleted))

(defun ri-tabs--cancel-pending-activation ()
  "Cancel any persistent Ki tab activation awaiting startup."
  (remove-hook 'emacs-startup-hook #'ri-tabs--startup-activate)
  (setq ri-tabs--activation-pending-p nil))

(defun ri-tabs--activate-owner (owner &optional state)
  "Restore OWNER's marked files once for this enable."
  (when (and ri-tabs-mode owner (not (gethash owner ri-tabs--restored-owners)))
    (setq state (or state (ri-tabs--read-state-safely)))
    (unless (eq state ri-tabs--read-error)
      (puthash owner t ri-tabs--restored-owners)
      (when (ri-tabs--state-has-owner-p state owner)
        (ri-tabs--restore-marked-files state owner))
      (ri-tabs--sync-live-buffers state))))

(defun ri-tabs--activate-existing-owner-for-frame (frame state)
  "Activate FRAME's current owner context only if STATE already owns a set there."
  (when-let* ((window (ri-tabs--frame-selected-window frame))
              (buffer (window-buffer window))
              ((ri-tabs--file-buffer-p buffer))
              (owner (ri-tabs--buffer-owner-context buffer)))
    (when (ri-tabs--state-has-owner-p state owner)
      (ri-tabs--set-frame-owner frame owner)
      (ri-tabs--activate-owner owner state))))

(defun ri-tabs--activate ()
  "Activate owner-context persistent marks without inventing a new owner."
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
            (let ((state (ri-tabs--read-state-safely)))
              (when (null state)
                (condition-case err
                    (setq state (ri-tabs--write-state (ri-tabs--make-state)))
                  (error
                   (ri-tabs--warn-persistence "initialize" err)
                   (setq state ri-tabs--read-error))))
              (setq ri-tabs--activation-state state)
              (when (and ri-tabs-mode (not (eq state ri-tabs--read-error)))
                (dolist (frame (frame-list))
                  (when (ri-tabs--frame-eligible-p frame)
                    (ri-tabs--activate-existing-owner-for-frame frame state)))
                (ri-tabs--sync-live-buffers state)))
            (setq completed t))
        (when (and completed ri-tabs-mode)
          (setq ri-tabs--activation-complete-p t))
        (when (and ri-tabs-mode (or completed ri-tabs--refresh-pending-p))
          (let ((ri-tabs--refresh-batching-p nil))
            (ri-tabs--refresh)))))))

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
  (setq ri-tabs--restored-owners (make-hash-table :test #'equal))
  (condition-case err
      (progn
        (ri-tabs--install-infrastructure)
        (ri-tabs--install-surfaces)
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
         (ri-tabs--remove-all-surfaces)
       (error
        (display-warning
         'ri-tabs
         (format "Could not roll back failed Ri tab surface installation: %s"
                 (error-message-string rollback-error))
         :error)))
     (signal (car err) (cdr err)))))

(defun ri-tabs--disable ()
  "Remove frame-wide tabs and caches without changing persistent marks."
  (setq ri-tabs--restored-owners (make-hash-table :test #'equal))
  (let ((ri-tabs--refresh-batching-p t)
        (ri-tabs--refresh-pending-p nil))
    (ri-tabs--cancel-pending-activation)
    (setq ri-tabs--activation-complete-p nil)
    (ri-tabs--remove-infrastructure)
    (dolist (buffer (buffer-list))
      (ri-tabs--clear-buffer-cache buffer))
    (dolist (frame (frame-list))
      (when (frame-live-p frame)
        (set-frame-parameter frame 'ri-tabs-owner nil)
        (set-frame-parameter frame 'ri-tabs-last-editing-window nil)))
    (ri-tabs--remove-all-surfaces))
  (setq ri-tabs--refresh-pending-p nil))

;;;###autoload
(define-minor-mode ri-tabs-mode
  "Display one Ri-owned frame-wide wrapping tab surface for file buffers.

Every ordinary frame has an active owner-context marked set.  The
first marked file establishes the owner context.  Files subsequently
marked may come from any owner context or from outside Git, and opening such
files never changes the owner.  Use `ri-tabs-switch-owner-context' to switch
explicitly to the marked set owned by the current file's owner context.

Existing owner sets are restored lazily when their owner context is
activated.  Activation requested during initialization is deferred until
`emacs-startup-hook'.

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
