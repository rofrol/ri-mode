;;; ri-extend.el --- Extend selection for ri -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow

;;; Commentary:

;; Selection state and highlighting for `ri-mode`.

;;; Code:

(require 'cl-lib)
(require 'multisession)
(require 'semantic-regions)

(declare-function mini-modal-normal "mini-modal")
(declare-function desktop-auto-save "desktop" ())

(defvar ri--desktop-autosave-timer nil
  "Deferred Ri-triggered Desktop autosave timer.")

(define-multisession-variable ri--last-selection-submode
  'line
  "Last persistent Ri selection submode."
  :package "ri-mode"
  :synchronized t)

(defun ri--selection-submode-valid-p (submode)
  "Return non-nil when SUBMODE is a supported semantic selection mode."
  (and (symbolp submode)
       (assq submode sr--submode-properties)))

(defun ri--warn-selection-submode-persistence (operation err)
  "Warn that SELECTION submode persistence OPERATION failed with ERR."
  (display-warning
   'ri
   (format "Could not %s persistent Ri selection mode: %s"
           operation (error-message-string err))
   :warning))

(defun ri--read-persistent-selection-submode ()
  "Return the stored selection submode, or `line' when unavailable."
  (condition-case err
      (let ((submode (multisession-value ri--last-selection-submode)))
        (if (ri--selection-submode-valid-p submode)
            submode
          (when submode
            (display-warning
             'ri
             (format "Ignoring invalid persistent Ri selection mode: %S"
                     submode)
             :warning))
          'line))
    (error
     (ri--warn-selection-submode-persistence "read" err)
     'line)))

(defun ri--persist-selection-submode (submode)
  "Make SUBMODE the default and persist it across Emacs sessions."
  (setq-default sr-submode submode)
  (condition-case err
      (setf (multisession-value ri--last-selection-submode) submode)
    (error
     (ri--warn-selection-submode-persistence "write" err))))

(setq-default sr-submode (ri--read-persistent-selection-submode))

(cl-defstruct (ri--selection-state
               (:constructor ri--selection-state-create))
  "Complete state of one active extended selection."
  anchor
  initial-end
  preserved-boundary
  active-edge
  undo-stack)

(defvar-local ri--selection nil
  "The active `ri--selection-state', or nil outside extend mode.")

(defvar-local ri--dup-last-bounds nil
  "Temporary bounds of a just-created inline duplicate.")

(defvar-local ri--momentary-origin-submode nil
  "Submode to restore when a momentary LINE/CHAR/WORD+ layer releases.")
(cl-defstruct (ri--history-snapshot
               (:constructor ri--history-snapshot-create))
  "One transient Ri location that can be restored later."
  buffer
  file
  point
  point-fallback
  submode
  extend-p
  start
  start-fallback
  end
  end-fallback
  active-edge)

(cl-defstruct (ri--history-window-state
               (:constructor ri--history-window-state-create))
  "Coarse Move History state for one editing window."
  current
  back
  forward)

(defvar-local ri--history-fine-current nil
  "Current fine Move History snapshot for this buffer.")
(defvar-local ri--history-fine-back nil
  "Fine Move History snapshots behind the current buffer location.")
(defvar-local ri--history-fine-forward nil
  "Fine Move History snapshots ahead of the current buffer location.")

(defvar ri--history-before-snapshot nil
  "Snapshot captured by `ri--history-pre-command'.")
(defvar ri--history-before-window nil
  "Window captured by `ri--history-pre-command'.")
(defvar ri--history-replaying nil
  "Non-nil while a Move History command is restoring a snapshot.")

(defun ri--history-snapshot-markers (snapshot)
  "Return all markers owned by SNAPSHOT."
  (delq nil
        (list (ri--history-snapshot-point snapshot)
              (ri--history-snapshot-start snapshot)
              (ri--history-snapshot-end snapshot))))

(defun ri--history-dispose-snapshot (snapshot)
  "Detach all markers owned by SNAPSHOT."
  (when (ri--history-snapshot-p snapshot)
    (dolist (marker (ri--history-snapshot-markers snapshot))
      (set-marker marker nil))))

(defun ri--history-dispose-list (snapshots)
  "Detach markers owned by SNAPSHOTS."
  (mapc #'ri--history-dispose-snapshot snapshots))

(defun ri--history-snapshot-position (marker fallback)
  "Return MARKER's position, or FALLBACK after its buffer is gone."
  (or (and (markerp marker) (marker-position marker))
      fallback))

(defun ri--history-snapshot-point-position (snapshot)
  "Return the point position stored in SNAPSHOT."
  (ri--history-snapshot-position
   (ri--history-snapshot-point snapshot)
   (ri--history-snapshot-point-fallback snapshot)))

(defun ri--history-snapshot-bounds (snapshot)
  "Return exact selection bounds stored in SNAPSHOT, or nil."
  (when (ri--history-snapshot-extend-p snapshot)
    (cons
     (ri--history-snapshot-position
      (ri--history-snapshot-start snapshot)
      (ri--history-snapshot-start-fallback snapshot))
     (ri--history-snapshot-position
      (ri--history-snapshot-end snapshot)
      (ri--history-snapshot-end-fallback snapshot)))))

(defun ri--history-effective-submode ()
  "Return the submode represented by the current visible Ri state."
  (or ri--momentary-origin-submode sr-submode))

(defun ri--history-capture-snapshot (&optional buffer)
  "Capture the current Ri location in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((extend-p (ri--selection-active-p))
           (bounds (and extend-p (ri--selection-bounds)))
           (start (and bounds (copy-marker (car bounds))))
           (end (and bounds (copy-marker (cdr bounds)))))
      (ri--history-snapshot-create
       :buffer (current-buffer)
       :file buffer-file-name
       :point (copy-marker (point))
       :point-fallback (point)
       :submode (ri--history-effective-submode)
       :extend-p extend-p
       :start start
       :start-fallback (and bounds (car bounds))
       :end end
       :end-fallback (and bounds (cdr bounds))
       :active-edge (and extend-p
                         (ri--selection-state-active-edge ri--selection))))))

(defun ri--history-snapshot-equal-p (left right)
  "Return non-nil when LEFT and RIGHT describe the same location."
  (and (ri--history-snapshot-p left)
       (ri--history-snapshot-p right)
       (eq (ri--history-snapshot-buffer left)
           (ri--history-snapshot-buffer right))
       (equal (ri--history-snapshot-file left)
              (ri--history-snapshot-file right))
       (eq (ri--history-snapshot-submode left)
           (ri--history-snapshot-submode right))
       (= (ri--history-snapshot-point-position left)
          (ri--history-snapshot-point-position right))
       (eq (ri--history-snapshot-extend-p left)
           (ri--history-snapshot-extend-p right))
       (equal (ri--history-snapshot-bounds left)
              (ri--history-snapshot-bounds right))
       (eq (ri--history-snapshot-active-edge left)
           (ri--history-snapshot-active-edge right))))

(defun ri--history-snapshot-file-equal-p (left right)
  "Return non-nil when LEFT and RIGHT refer to the same file."
  (and (ri--history-snapshot-p left)
       (ri--history-snapshot-p right)
       (equal (ri--history-snapshot-file left)
              (ri--history-snapshot-file right))))

(defun ri--history-window (window)
  "Return WINDOW's coarse Move History state."
  (window-parameter window 'ri--history-state))

(defun ri--history-set-window (window state)
  "Set WINDOW's coarse Move History STATE."
  (set-window-parameter window 'ri--history-state state))

(defun ri--history-eligible-window-p (window)
  "Return non-nil when WINDOW is an ordinary Ri editing window."
  (and (window-live-p window)
       (null (window-parameter window 'window-side))
       (not (window-minibuffer-p window))
       (with-current-buffer (window-buffer window)
         (and (bound-and-true-p sr-mode)
              (bound-and-true-p mini-modal-mode)
              (not (derived-mode-p 'special-mode))))))

(defun ri--history-fine-ensure-current ()
  "Initialize the current fine snapshot lazily."
  (unless (ri--history-snapshot-p ri--history-fine-current)
    (setq ri--history-fine-current (ri--history-capture-snapshot))))

(defun ri--history-fine-clear-forward ()
  "Discard fine snapshots ahead of the current location."
  (ri--history-dispose-list ri--history-fine-forward)
  (setq ri--history-fine-forward nil))

(defun ri--history-window-ensure-current (window)
  "Initialize WINDOW's coarse snapshot lazily."
  (or (ri--history-window window)
      (let ((state (ri--history-window-state-create
                    :current (with-current-buffer (window-buffer window)
                               (ri--history-capture-snapshot))
                    :back nil
                    :forward nil)))
        (ri--history-set-window window state)
        state)))

(defun ri--history-window-clear-forward (state)
  "Discard coarse snapshots ahead of STATE's current location."
  (ri--history-dispose-list
   (ri--history-window-state-forward state))
  (setf (ri--history-window-state-forward state) nil))

(defun ri--history-restore-extend (snapshot)
  "Restore the exact Extend state stored in SNAPSHOT."
  (let* ((bounds (ri--history-snapshot-bounds snapshot))
         (start (max (point-min) (min (point-max) (car bounds))))
         (end (max start (min (point-max) (cdr bounds))))
         (edge (or (ri--history-snapshot-active-edge snapshot) 'end))
         (state (ri--selection-state-create
                 :anchor (copy-marker (if (eq edge 'end) start end))
                 :initial-end nil
                 :preserved-boundary
                 (copy-marker (if (eq edge 'end) end start))
                 :active-edge edge
                 :undo-stack nil)))
    (setq ri--selection state)
    (goto-char (ri--point-at-unit-edge (cons start end) edge))))

(defun ri--history-restore-snapshot (snapshot)
  "Restore SNAPSHOT in its current buffer."
  (let ((buffer (ri--history-snapshot-buffer snapshot)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ri--exit-extend)
        (ri--restore-submode (ri--history-snapshot-submode snapshot))
        (if (ri--history-snapshot-extend-p snapshot)
            (ri--history-restore-extend snapshot)
          (goto-char
           (max (point-min)
                (min (point-max)
                     (ri--history-snapshot-point-position snapshot)))))
        (ri--update-highlight)
        (force-mode-line-update)
        t))))

(defun ri--history-fine-commit (before after)
  "Record a changed same-buffer location from BEFORE to AFTER."
  (with-current-buffer (ri--history-snapshot-buffer before)
    (ri--history-fine-ensure-current)
    (if ri--history-replaying
        (if (ri--history-snapshot-equal-p
             ri--history-fine-current after)
            (ri--history-dispose-snapshot after)
          (ri--history-dispose-snapshot ri--history-fine-current)
          (setq ri--history-fine-current after))
      (unless (ri--history-snapshot-equal-p
               ri--history-fine-current after)
        (push ri--history-fine-current ri--history-fine-back)
        (ri--history-fine-clear-forward)
        (setq ri--history-fine-current after)))
    (ri--history-dispose-snapshot before)))

(defun ri--history-fine-navigate (direction)
  "Navigate fine Move History in DIRECTION, `back' or `forward'."
  (interactive)
  (ri--history-fine-ensure-current)
  (let* ((forward (eq direction 'forward))
         (source (if forward
                     ri--history-fine-forward
                   ri--history-fine-back))
         (target (pop source)))
    (while (and target
                (not (buffer-live-p (ri--history-snapshot-buffer target))))
      (ri--history-dispose-snapshot target)
      (setq target (pop source)))
    (if forward
        (setq ri--history-fine-forward source)
      (setq ri--history-fine-back source))
    (when target
      (let ((current ri--history-fine-current))
        (if forward
            (push current ri--history-fine-back)
          (push current ri--history-fine-forward))
        (setq ri--history-replaying t)
        (ri--history-restore-snapshot target)
        (setq ri--history-fine-current target)))))

(defun ri-history-back ()
  "Move to the previous Ri cursor or selection location."
  (interactive)
  (ri--history-fine-navigate 'back))

(defun ri-history-forward ()
  "Move to the next Ri cursor or selection location."
  (interactive)
  (ri--history-fine-navigate 'forward))

(defun ri--history-coarse-restore (direction)
  "Navigate coarse Move History in DIRECTION, `back' or `forward'."
  (let* ((window (selected-window))
         (state (and (ri--history-eligible-window-p window)
                     (ri--history-window-ensure-current window)))
         (forward (eq direction 'forward))
         (source (and state
                      (if forward
                          (ri--history-window-state-forward state)
                        (ri--history-window-state-back state))))
         (target (and source (pop source))))
    (when state
      (while (and target
                  (or (not (stringp
                            (ri--history-snapshot-file target)))
                      (not (file-exists-p
                            (ri--history-snapshot-file target)))))
        (ri--history-dispose-snapshot target)
        (setq target (pop source)))
      (if forward
          (setf (ri--history-window-state-forward state) source)
        (setf (ri--history-window-state-back state) source))
      (when target
        (let ((current (ri--history-window-state-current state))
              (buffer (ri--history-snapshot-buffer target)))
          (if forward
              (push current (ri--history-window-state-back state))
            (push current (ri--history-window-state-forward state)))
          (setq ri--history-replaying t)
          (unless (eq (current-buffer) buffer)
            (switch-to-buffer
             (or (and (buffer-live-p buffer) buffer)
                 (find-file-noselect
                  (ri--history-snapshot-file target)))))
          (with-current-buffer (window-buffer window)
            (setf (ri--history-snapshot-buffer target) (current-buffer))
            (ri--history-restore-snapshot target)
            (ri--history-dispose-snapshot ri--history-fine-current)
            (setq ri--history-fine-current
                  (ri--history-capture-snapshot)))
          (setf (ri--history-window-state-current state) target))))))

(defun ri-history-coarse-back ()
  "Move to the previous visited Ri file location."
  (interactive)
  (ri--history-coarse-restore 'back))

(defun ri-history-coarse-forward ()
  "Move to the next visited Ri file location."
  (interactive)
  (ri--history-coarse-restore 'forward))

(defun ri--history-pre-command ()
  "Capture the selected Ri location before a command."
  (setq ri--history-before-snapshot nil
        ri--history-before-window nil)
  (let ((window (selected-window)))
    (when (ri--history-eligible-window-p window)
      (setq ri--history-before-window window
            ri--history-before-snapshot
            (with-current-buffer (window-buffer window)
              (ri--history-capture-snapshot))
            ri--history-replaying nil)
      (ri--history-fine-ensure-current)
      (ri--history-window-ensure-current window))))
(defun ri--run-desktop-autosave ()
  "Run Ri's deferred Desktop autosave."
  (setq ri--desktop-autosave-timer nil)
  (when (and (bound-and-true-p desktop-save-mode)
             (fboundp #'desktop-auto-save))
    (desktop-auto-save)))

(defun ri--request-desktop-autosave ()
  "Defer Desktop's native save after a stable Ri location change."
  (when (and (bound-and-true-p desktop-save-mode)
             (fboundp #'desktop-auto-save))
    (when (timerp ri--desktop-autosave-timer)
      (cancel-timer ri--desktop-autosave-timer))
    (setq ri--desktop-autosave-timer
          (run-at-time 0 nil #'ri--run-desktop-autosave))))

(defun ri--history-post-command ()
  "Record the selected Ri location after a command."
  (let ((before ri--history-before-snapshot)
        (before-window ri--history-before-window)
        (after-window (selected-window)))
    (unwind-protect
        (when (and before
                   (window-live-p before-window))
          (if (eq before-window after-window)
              (let* ((after (ri--history-capture-snapshot))
                     (coarse-after (ri--history-capture-snapshot))
                     (location-changed-p
                      (not (ri--history-snapshot-equal-p before after))))
                (if (eq (ri--history-snapshot-buffer before)
                        (window-buffer after-window))
                    (ri--history-fine-commit before after)
                  (ri--history-dispose-snapshot after))
                (let* ((state (ri--history-window-ensure-current after-window))
                       (current (ri--history-window-state-current state)))
                  (if (ri--history-snapshot-file-equal-p
                       current coarse-after)
                      (progn
                        (unless (ri--history-snapshot-equal-p
                                 current coarse-after)
                          (unless ri--history-replaying
                            (ri--history-window-clear-forward state))
                          (ri--history-dispose-snapshot current)
                          (setf (ri--history-window-state-current state)
                                coarse-after))
                        (unless (eq current coarse-after)
                          (ri--history-dispose-snapshot coarse-after)))
                    (push current (ri--history-window-state-back state))
                    (ri--history-window-clear-forward state)
                    (setf (ri--history-window-state-current state)
                          coarse-after)))
                (when (and location-changed-p
                           (not ri--momentary-origin-submode))
                  (ri--request-desktop-autosave)))
            (when (ri--history-eligible-window-p after-window)
              (ri--history-fine-ensure-current)
              (ri--history-window-ensure-current after-window))))
      (setq ri--history-replaying nil
            ri--history-before-snapshot nil
            ri--history-before-window nil))))

(defun ri--selection-active-p ()
  "Return non-nil when the current buffer has an extended selection."
  (and (ri--selection-state-p ri--selection) t))

(cl-defstruct (ri--extend-entry
               (:constructor ri--extend-entry-create))
  "One selection-extension state for undo."
  point
  anchor
  active-edge
  preserved-boundary)

(defun ri--point-at-unit-edge (bounds edge)
  "Return cursor position for EDGE, keeping the end cursor inside BOUNDS."
  (if (and (eq edge 'end) (> (cdr bounds) (car bounds)))
      (1- (cdr bounds))
    (car bounds)))

(defun ri--set-preserved-boundary (state position)
  "Keep STATE's exact active boundary at POSITION."
  (let ((marker (ri--selection-state-preserved-boundary state)))
    (if (markerp marker)
        (set-marker marker position)
      (setf (ri--selection-state-preserved-boundary state)
            (copy-marker position)))))

(defun ri--clear-preserved-boundary (state)
  "Release STATE's exact active boundary override."
  (let ((marker (ri--selection-state-preserved-boundary state)))
    (when (markerp marker)
      (set-marker marker nil))
    (setf (ri--selection-state-preserved-boundary state) nil)))


(defun ri--next-unit-bounds (pos submode)
  "Return bounds of the unit after SUBMODE's unit at POS."
  (when-let* ((current (semantic-region-parse-at submode pos)))
    (let ((next (semantic-region-next current)))
      (while (and next
                  (eq submode 'line)
                  (semantic-region-empty-p next))
        (setq next (semantic-region-next next)))
      (when next
        (cons (semantic-region-beg next) (semantic-region-end next))))))

(defun ri--prev-unit-bounds (pos submode)
  "Return bounds of the unit before SUBMODE's unit at POS."
  (when-let* ((current (semantic-region-parse-at submode pos)))
    (let ((prev (semantic-region-prev current)))
      (while (and prev
                  (eq submode 'line)
                  (semantic-region-empty-p prev))
        (setq prev (semantic-region-prev prev)))
      (when prev
        (cons (semantic-region-beg prev) (semantic-region-end prev))))))

(defun ri--extend-point-boundary ()
  "Return the exact selection boundary represented by point."
  (if (eq (ri--selection-state-active-edge ri--selection) 'end)
      (if (and (eq sr-submode 'paragraph)
               (= (point) (line-beginning-position))
               (semantic-region--blank-line-p))
          (point)
        (min (point-max) (1+ (point))))
    (point)))

(defmacro ri--without-selection-context (&rest body)
  "Evaluate BODY while treating navigation as single-unit movement.
This prevents movement helpers from changing the active selection."
  (declare (indent 0) (debug t))
  `(let ((ri--selection nil))
     ,@body))

(defun ri--selection-bounds ()
  "Return (start . end) of the current selection.
In extend mode, a submode change or cursor swap preserves the exact
selection already established until navigation moves the active edge.
Otherwise, horizontal unit modes keep selection boundaries exact;
WORD, WORD*, SUBWORD, and NODE keep the initial unit in the range while
the current unit crosses it, without changing cursor direction.  NODE
always contributes its complete syntax-node bounds.  For line modes,
only the active edge snaps to a line boundary; the inactive anchor
remains at the exact boundary already established.
In normal mode: current unit bounds."
  (if-let* ((state ri--selection)
            (anchor (ri--selection-state-anchor state)))
      (let* ((anchor-pos (marker-position anchor))
             (preserved-pos
              (when-let* ((marker
                           (ri--selection-state-preserved-boundary state)))
                (marker-position marker)))
             (point-pos (point))
             (point-boundary (ri--extend-point-boundary))
             (raw-start (min anchor-pos point-pos))
             (raw-end (max anchor-pos point-pos))
             (active-edge
              (or (ri--selection-state-active-edge state)
                  (if (< anchor-pos point-pos) 'end 'start))))
        (cond
         ((integerp preserved-pos)
          (cons (min anchor-pos preserved-pos)
                (max anchor-pos preserved-pos)))
         ((and (= raw-start (point-min))
               (= point-boundary (point-max)))
          (cons raw-start point-boundary))
         ((eq sr-submode 'node)
          (let ((current-bounds (sr--get-current-unit-bounds))
                (initial-end
                 (when-let* ((marker
                              (ri--selection-state-initial-end state)))
                   (marker-position marker))))
            (if current-bounds
                (if (eq active-edge 'end)
                    (cons (min anchor-pos (car current-bounds))
                          (max (or initial-end anchor-pos)
                               (cdr current-bounds)))
                  (cons (min anchor-pos (car current-bounds))
                        (max anchor-pos (cdr current-bounds))))
              (cons (min anchor-pos point-boundary)
                    (max (or initial-end anchor-pos) point-boundary)))))
         ((and (sr--wordish-submode-p)
               (eq active-edge 'end)
               (ri--selection-state-initial-end state))
          (let ((current-bounds (sr--get-current-unit-bounds))
                (initial-end
                 (marker-position
                  (ri--selection-state-initial-end state))))
            (if current-bounds
                (cons (min anchor-pos (car current-bounds))
                      (max initial-end (cdr current-bounds)))
              (cons (min anchor-pos point-boundary)
                    (max initial-end point-boundary)))))
         ((sr--horizontal-submode-p)
          (cons (min anchor-pos point-boundary)
                (max anchor-pos point-boundary)))
         ((eq sr-submode 'line-star)
          (let ((start (if (eq active-edge 'start)
                           (save-excursion
                             (goto-char raw-start)
                             (line-beginning-position))
                         raw-start))
                (end (if (eq active-edge 'end)
                         (save-excursion
                           (goto-char raw-end)
                           (line-end-position))
                       raw-end)))
            (cons start end)))
         ((eq sr-submode 'line)
          (save-excursion
            (let ((start raw-start)
                  (end raw-end))
              (when (eq active-edge 'start)
                (goto-char raw-start)
                (setq start (line-beginning-position))
                (goto-char start)
                (skip-chars-forward " \t" (line-end-position))
                (setq start (point)))
              (when (eq active-edge 'end)
                (goto-char raw-end)
                (goto-char (line-end-position))
                (skip-chars-backward " \t" (line-beginning-position))
                (setq end (point)))
              (cons start end))))
         (t
          (cons raw-start raw-end))))
    (sr--get-current-unit-bounds)))

(defun ri--highlight-bounds ()
  "Return the model bounds RI requests for highlighting.
A temporary duplicate takes precedence over the active selection or
current semantic unit."
  (or ri--dup-last-bounds (ri--selection-bounds)))

(defun ri--exit-extend ()
  "Exit selection-extend mode and release its complete state."
  (when-let* ((state ri--selection))
    (dolist (marker (list (ri--selection-state-anchor state)
                          (ri--selection-state-initial-end state)
                          (ri--selection-state-preserved-boundary state)))
      (when (markerp marker)
        (set-marker marker nil))))
  (setq ri--selection nil))

 (defun ri--enter-extend ()
  "Enter selection-extend mode around the current unit.
Return non-nil after establishing a complete selection state.  If the
current submode has no unit at point, leave extension mode inactive.
The initial CHAR selection remains end-active until its first horizontal
move chooses a direction."
  (ri--exit-extend)
  (when-let* ((bounds (sr--get-current-unit-bounds)))
    (setq ri--selection
          (ri--selection-state-create
           :anchor (copy-marker (car bounds))
           :initial-end (copy-marker (cdr bounds))
           :active-edge 'end
           :undo-stack nil))
    (goto-char (ri--point-at-unit-edge bounds 'end))
    t))

(defun ri--snap-to-unit-start (&optional force-start)
  "Snap point to the current unit's active selection edge.
When FORCE-START is non-nil, keep point at the unit start even when
the active extend edge is `end'."
  (unless (eq sr-submode 'char)
    (when-let* ((bounds
                 (if (eq sr-submode 'paragraph)
                     (sr--get-current-unit-bounds)
                   (sr--meaningful-unit-bounds-at (point) sr-submode))))
      (goto-char
       (if (and (not force-start)
                (ri--selection-active-p)
                (eq (ri--selection-state-active-edge ri--selection) 'end))
           (ri--point-at-unit-edge bounds 'end)
         (car bounds))))))

(defun ri--update-highlight ()
  "Refresh highlighting from RI's model through semantic-regions."
  (let ((sr-highlight-bounds-function #'ri--highlight-bounds))
    (sr--update-highlight)))

(defun ri--preserve-selection-for-submode-switch ()
  "Keep exact selection bounds while changing semantic submodes."
  (when-let* ((state ri--selection)
              (anchor (ri--selection-state-anchor state))
              (bounds (ri--selection-bounds)))
    (let* ((anchor-pos (marker-position anchor))
           (active-edge
            (or (ri--selection-state-active-edge state)
                (if (< anchor-pos (point)) 'end 'start))))
      (when-let* ((initial-end
                   (ri--selection-state-initial-end state)))
        (set-marker initial-end nil))
      (setf (ri--selection-state-initial-end state) nil
            (ri--selection-state-active-edge state) active-edge)
      (pcase active-edge
        ('end
         (set-marker anchor (car bounds))
         (goto-char (ri--point-at-unit-edge bounds 'end))
         (ri--set-preserved-boundary state (cdr bounds)))
        ('start
         (set-marker anchor (cdr bounds))
         (goto-char (car bounds))
         (ri--set-preserved-boundary state (car bounds)))))))

(defun ri--extend-record ()
  "Push the cursor-facing selection state onto the extension undo stack.
Do nothing outside extend mode."
  (when-let* ((state ri--selection))
    (push (ri--extend-entry-create
           :point (point)
           :anchor (when-let* ((anchor (ri--selection-state-anchor state)))
                     (marker-position anchor))
           :active-edge (ri--selection-state-active-edge state)
           :preserved-boundary
           (when-let* ((boundary
                        (ri--selection-state-preserved-boundary state)))
             (marker-position boundary)))
          (ri--selection-state-undo-stack state))))

(defun ri--extend-undo ()
  "Contract the selection by one navigation step.
Restore the latest record from the active state's undo stack.  When
the stack is empty, exit extend mode gracefully."
  (interactive)
  (if (and ri--selection
           (ri--selection-state-undo-stack ri--selection))
      (let* ((state ri--selection)
             (record (pop (ri--selection-state-undo-stack state)))
             (point (ri--extend-entry-point record))
             (anchor (ri--extend-entry-anchor record))
             (active-edge (ri--extend-entry-active-edge record))
             (preserved-boundary
              (ri--extend-entry-preserved-boundary record)))
        (goto-char point)
        (when (and (ri--selection-state-anchor state) anchor)
          (set-marker (ri--selection-state-anchor state) anchor))
        (setf (ri--selection-state-active-edge state) active-edge)
        (if preserved-boundary
            (ri--set-preserved-boundary state preserved-boundary)
          (ri--clear-preserved-boundary state))
        (ri--update-highlight))
    (ri--exit-extend)
    (ri--update-highlight)))

(defun ri--undo-at-exhausted-redo-p ()
  "Return non-nil when only an exhausted redo record remains."
  (and (not undo-in-region)
       (or (eq pending-undo-list t)
           (and (consp pending-undo-list)
                (eq (gethash pending-undo-list undo-equiv-table) t)))
       (gethash (ri--first-undo-cell buffer-undo-list)
                undo-equiv-table)))

(defun ri--first-undo-cell (undo-list)
  "Return the first non-boundary cons cell in UNDO-LIST."
  (while (and (consp undo-list) (null (car undo-list)))
    (setq undo-list (cdr undo-list)))
  (and (consp undo-list) undo-list))

(defun ri--split-undo-cell (cell first rest)
  "Replace CELL's entry with FIRST and put REST after a new boundary.
Preserve any redo equivalence mapping for the new REST list."
  (let* ((tail (cdr cell))
         (equivalent (gethash cell undo-equiv-table))
         (rest-cell (cons rest tail)))
    (setcar cell first)
    (setcdr cell (cons nil rest-cell))
    (when equivalent
      (puthash rest-cell equivalent undo-equiv-table))))

(defun ri--split-next-insertion-undo ()
  "Make the next multi-character insertion undo one character only."
  (when-let* ((cell
               (ri--first-undo-cell
                (if (and (eq last-command 'undo)
                         (listp pending-undo-list))
                    pending-undo-list
                  buffer-undo-list))))
    (pcase (car cell)
      (`(,(and beg (pred integerp)) . ,(and end (pred integerp)))
       (when (> (- end beg) 1)
         (ri--split-undo-cell
          cell
          (cons (1- end) end)
          (cons beg (1- end))))))))

(defun ri--split-next-insertion-redo ()
  "Make the next multi-character insertion redo one character only."
  (when-let* ((cell (ri--first-undo-cell buffer-undo-list)))
    (pcase (car cell)
      (`(,(and text (pred stringp)) . ,(and pos (pred integerp)))
       (when (> (length text) 1)
         (let* ((absolute-pos (abs pos))
                (next-pos (1+ absolute-pos)))
           (ri--split-undo-cell
            cell
            (cons (substring text 0 1) pos)
            (cons (substring text 1)
                  (if (< pos 0) (- next-pos) next-pos)))))))))

(defun ri-undo-only ()
  "Undo one buffer change without consuming Extend navigation history.
When Extend is active, preserve point on its active selection edge."
  (interactive)
  (let ((extend-point
         (and (ri--selection-active-p) (copy-marker (point)))))
    (unwind-protect
        (progn
          ;; `undo-only' skips list-valued redo equivalents, but an exhausted
          ;; branch maps to t and would otherwise replay the discarded edit.
          (when (ri--undo-at-exhausted-redo-p)
            (setq last-command 'undo
                  pending-undo-list t))
          (undo-only)
          ;; KKP chord actions run while Emacs is reading the next event,
          ;; before the command loop can delimit the redo record they create.
          (undo-boundary))
      (when extend-point
        (goto-char extend-point)
        (set-marker extend-point nil)))))

(defun ri-smart-undo ()
  "Undo one Extend navigation step, or one buffer change outside Extend."
  (interactive)
  (if (ri--selection-active-p)
      (ri--extend-undo)
    (ri-undo-only)))

(defun ri-smart-redo ()
  "Redo one change and delimit it for a following KKP chord action."
  (interactive)
  (undo-redo)
  (undo-boundary))

(defun ri-fine-undo ()
  "Undo one character of a grouped insertion, or one ordinary undo unit."
  (interactive)
  (if (ri--selection-active-p)
      (ri--extend-undo)
    (ri--split-next-insertion-undo)
    (ri-smart-undo)))

(defun ri-fine-redo ()
  "Redo one character of a grouped insertion, or one ordinary redo unit."
  (interactive)
  (ri--split-next-insertion-redo)
  (ri-smart-redo))

 (defun ri--extend-horizontal-move (direction)
  "Move the active extend edge one content unit in DIRECTION.
When the active edge is `end', point stays on the last character of
the selected unit; moving back over prev expanded units shrinks
the selection.  In WORD, WORD*, and SUBWORD modes, crossing the
initial anchor keeps the cursor direction instead of swapping it."
  (when-let* ((state ri--selection))
    (let* ((edge (or (ri--selection-state-active-edge state) 'end))
           (base-pos (point))
           (target (pcase direction
                     ('left (ri--prev-unit-bounds base-pos sr-submode))
                     ('right (ri--next-unit-bounds base-pos sr-submode))))
           (anchor (ri--selection-state-anchor state))
           (anchor-pos (when anchor (marker-position anchor)))
           (shrinking-p (or (and (eq edge 'end)
                                 (eq direction 'left))
                            (and (eq edge 'start)
                                 (eq direction 'right)))))
      (cond
       ((and (eq sr-submode 'char)
             anchor-pos
             (eq edge 'end)
             (= base-pos anchor-pos)
             (eq direction 'left))
        (when target
          (set-marker anchor (1+ anchor-pos))
          (setf (ri--selection-state-active-edge state) 'start)
          (goto-char (ri--point-at-unit-edge target 'start))))
       ((and (eq sr-submode 'char)
             anchor-pos
             (eq edge 'start)
             (= (1+ base-pos) anchor-pos)
             (eq direction 'right))
        (when target
          (set-marker anchor base-pos)
          (setf (ri--selection-state-active-edge state) 'end)
          (goto-char (ri--point-at-unit-edge target 'end))))
       (t
        (when (and target
                   (or (not shrinking-p)
                       (not anchor-pos)
                       (if (eq edge 'end)
                           (> (cdr target) anchor-pos)
                         (< (car target) anchor-pos))
                       (and (eq edge 'end)
                            (eq direction 'left)
                            (ri--selection-state-initial-end state)
                            (sr--wordish-submode-p))))
          (setf (ri--selection-state-active-edge state) edge)
          (goto-char (ri--point-at-unit-edge target edge))))))))

(defun ri-swap-cursor ()
  "Move point to the opposite end of the current selection or unit.
In extend mode: swap point and anchor marker while preserving the full
selection, including when a WORD edge has crossed its initial anchor.
In normal mode: jump to the opposite end of the current unit."
  (interactive)
  (if-let* ((state ri--selection)
            (anchor (ri--selection-state-anchor state)))
      (let* ((old-edge
              (or (ri--selection-state-active-edge state)
                  (if (< (marker-position anchor) (point))
                      'end
                    'start)))
             (bounds (ri--selection-bounds)))
        (when bounds
          (when-let* ((initial-end
                       (ri--selection-state-initial-end state)))
            (set-marker initial-end nil))
          (setf (ri--selection-state-initial-end state) nil)
          (if (eq old-edge 'end)
              (progn
                (goto-char (car bounds))
                (set-marker anchor (cdr bounds))
                (setf (ri--selection-state-active-edge state) 'start)
                (ri--set-preserved-boundary state (car bounds)))
            (goto-char (if (> (cdr bounds) (car bounds))
                           (1- (cdr bounds))
                         (cdr bounds)))
            (set-marker anchor (car bounds))
            (setf (ri--selection-state-active-edge state) 'end)
            (ri--set-preserved-boundary state (cdr bounds)))))
    (when-let* ((bounds (sr--get-current-unit-bounds)))
      (if (= (point) (car bounds))
          (goto-char (if (> (cdr bounds) (car bounds))
                         (1- (cdr bounds))
                       (cdr bounds)))
        (goto-char (car bounds))))))

(defun ri--select-all-submode-p ()
  "Return non-nil when repeated Extend has a select-all behavior."
  (memq sr-submode
        '(line line-star paragraph char word word-plus word-star)))
(defun ri--select-all-in-extend ()
  "Select the whole buffer or current line according to `sr-submode`."
  (when-let* ((state ri--selection))
    (let ((active-edge 'end)
          (anchor (ri--selection-state-anchor state)))
      (pcase sr-submode
        ((or 'word 'word-plus 'word-star 'line 'line-star 'paragraph)
         (unless anchor
           (setq anchor (copy-marker (point-min)))
           (setf (ri--selection-state-anchor state) anchor))
         (set-marker anchor (point-min))
         (goto-char (point-max)))
        ('char
         (let ((start (line-beginning-position))
               (end (line-end-position)))
           (unless anchor
             (setq anchor (copy-marker start))
             (setf (ri--selection-state-anchor state) anchor))
           (set-marker anchor start)
           (if (> end start)
               (goto-char (1- end))
             (setq active-edge 'start)
             (goto-char start))))
        (_
         (setq active-edge nil)))
      (when-let* ((initial-end (ri--selection-state-initial-end state)))
        (set-marker initial-end nil))
      (ri--clear-preserved-boundary state)
      (setf (ri--selection-state-initial-end state) nil
            (ri--selection-state-active-edge state) active-edge
            (ri--selection-state-undo-stack state) nil))))

(defun ri-toggle-extend ()
  "Toggle selection-extend mode, or select all on repeated `f`.
When entering: select the current unit and put point on its last character.
In WORD, WORD*, LINE, LINE*, and PARAGRAPH modes, repeated `f` selects
the buffer; in CHAR mode, it selects the current line.  In SUBWORD mode,
repeated `f` is a no-op; in NODE mode, it leaves Extend."
  (interactive)
  (unless (and (ri--selection-active-p) (eq sr-submode 'subword))
    (if (ri--selection-active-p)
        (if (ri--select-all-submode-p)
            (ri--select-all-in-extend)
          (ri--exit-extend))
      (ri--enter-extend))
    (ri--update-highlight)
    (force-mode-line-update)))


(defun ri--finish-extend-navigation (origin)
  "Finish extension navigation that started at ORIGIN."
  (when (and ri--selection (/= origin (point)))
    (ri--clear-preserved-boundary ri--selection))
  (ri--update-highlight))

(defun ri--run-extend-navigation (movement)
  "Record the selection, run MOVEMENT, and refresh Extend state."
  (ri--extend-record)
  (let ((origin (point)))
    (funcall movement)
    (when (ri--selection-active-p)
      (ri--snap-to-unit-start))
    (ri--finish-extend-navigation origin)))

(defun ri--run-extend-horizontal-navigation (direction fallback)
  "Extend in DIRECTION, or invoke FALLBACK outside horizontal Extend."
  (ri--extend-record)
  (let ((origin (point)))
    (if (and (ri--selection-active-p) (sr--horizontal-submode-p))
        (ri--extend-horizontal-move direction)
      (funcall fallback))
    (ri--finish-extend-navigation origin)))

(defun ri-extend-nav-left ()
  (interactive)
  (ri--run-extend-horizontal-navigation 'left #'sr-nav-left))
(defun ri-extend-nav-right ()
  (interactive)
  (ri--run-extend-horizontal-navigation 'right #'sr-nav-right))
(defun ri-extend-nav-up () (interactive) (ri--run-extend-navigation #'sr-nav-up))
(defun ri-extend-nav-down () (interactive) (ri--run-extend-navigation #'sr-nav-down))


(defun ri--run-momentary-navigation (setter movement)
  "Record the active submode, switch with SETTER, then run MOVEMENT."
  (unless ri--momentary-origin-submode
    (setq ri--momentary-origin-submode sr-submode))
  (funcall setter)
  (funcall movement))

(defun ri--restore-submode (submode)
  "Switch to SUBMODE without moving point.
Outside Extend, the raw semantic-regions setters do not move point, so
the position left by held navigation is kept.  Returning to NODE retargets
the current node at that position like a mouse click (lowest syntax node)
instead of reapplying the keyboard top-node entry rule; an active Extend
selection keeps its exact preserved bounds."
  (when (ri--selection-active-p)
    (ri--preserve-selection-for-submode-switch))
  (pcase submode
    ('line (sr-set-line-mode))
    ('line-star (sr-set-line-star-mode))
    ('paragraph (sr-set-paragraph-mode))
    ('char (sr-set-character-mode))
    ('word (sr-set-word-mode))
    ('word-plus (sr-set-word-plus-mode))
    ('word-star (sr-set-word-star-mode))
    ('subword (sr-set-subword-mode))
    ('node
     (sr-set-node-mode)
     (unless (ri--selection-active-p)
       (sr-retarget-at-position (point)))))
  (ri--update-highlight))

(defun ri--enter-momentary-submode (submode)
  "Record the current submode and switch to temporary SUBMODE."
  (unless ri--momentary-origin-submode
    (setq ri--momentary-origin-submode sr-submode)
    (ri--restore-submode submode)))

(defun ri--restore-momentary-submode ()
  "Restore the submode active before the current momentary layer."
  (when ri--momentary-origin-submode
    (let ((origin ri--momentary-origin-submode))
      (setq ri--momentary-origin-submode nil)
      (ri--restore-submode origin)
      (ri--request-desktop-autosave)
      (force-mode-line-update))))

(defun ri-momentary-char-left ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-character-mode
                                 #'ri-extend-nav-left))
(defun ri-momentary-char-right ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-character-mode
                                 #'ri-extend-nav-right))
(defun ri-momentary-char-up ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-character-mode
                                 #'ri-extend-nav-up))
(defun ri-momentary-char-down ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-character-mode
                                 #'ri-extend-nav-down))

(defun ri-momentary-line-up ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-line-mode
                                 #'ri-extend-nav-up))
(defun ri-momentary-line-down ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-line-mode
                                 #'ri-extend-nav-down))

(defun ri-momentary-word-plus-left ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-word-plus-mode
                                 #'ri-extend-nav-left))
(defun ri-momentary-word-plus-right ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-word-plus-mode
                                 #'ri-extend-nav-right))
(defun ri-momentary-word-plus-up ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-word-plus-mode
                                 #'ri-extend-nav-up))
(defun ri-momentary-word-plus-down ()
  (interactive)
  (ri--run-momentary-navigation #'sr-set-word-plus-mode
                                 #'ri-extend-nav-down))
(defun ri-extend-nav-prev ()
  (interactive)
  (if (and (ri--selection-active-p) (eq sr-submode 'paragraph))
      (ri--run-extend-horizontal-navigation 'left #'sr-nav-prev)
    (ri--run-extend-navigation #'sr-nav-prev)))
(defun ri-extend-nav-next ()
  (interactive)
  (if (and (ri--selection-active-p) (eq sr-submode 'paragraph))
      (ri--run-extend-horizontal-navigation 'right #'sr-nav-next)
    (ri--run-extend-navigation #'sr-nav-next)))
(defun ri-extend-nav-first () (interactive) (ri--run-extend-navigation #'sr-nav-first))
(defun ri-extend-nav-last () (interactive) (ri--run-extend-navigation #'sr-nav-last))

(defun ri--parent-line-target-bounds (position)
  "Return current submode bounds at parent-line POSITION without moving."
  ;; NODE probing updates `sr--node-current'; keep that speculative state
  ;; local until the movement is known to preserve the active Extend edge.
  (let ((sr--node-current sr--node-current))
    (save-excursion
      (goto-char position)
      (sr--meaningful-unit-bounds-at position sr-submode))))

(defun ri--target-preserves-active-edge-p (target-bounds)
  "Return non-nil when TARGET-BOUNDS preserves the active Extend edge."
  (if (not (ri--selection-active-p))
      t
    (when-let* ((bounds (ri--selection-bounds)))
      (pcase (ri--selection-state-active-edge ri--selection)
        ('start (<= (car target-bounds) (car bounds)))
        ('end (>= (cdr target-bounds) (cdr bounds)))))))

(defun ri--move-to-parent-line ()
  "Move to a parent line without detaching point from its Extend edge."
  (when-let* ((position (sr--parent-line-position)))
    (when (or (not (ri--selection-active-p))
              (when-let* ((target-bounds
                           (ri--parent-line-target-bounds position)))
                (ri--target-preserves-active-edge-p target-bounds)))
      (goto-char position)
      (sr--snap-to-unit-start))))

(defun ri-extend-nav-parent-line ()
  "Move to the nearest parent line while preserving Extend invariants."
  (interactive)
  (sr--require-node-parser "Parent Line")
  (ri--run-extend-navigation #'ri--move-to-parent-line))


(defun ri--set-submode-with-extend (setter &optional persistent-submode)
  "Switch submodes with SETTER without changing an active selection.
Outside Extend, place point at the start of the first traversable unit
at or after its old position.  When PERSISTENT-SUBMODE is non-nil, make
that submode the default for future buffers."
  (let ((extending (ri--selection-active-p)))
    (when extending
      (ri--preserve-selection-for-submode-switch))
    (funcall setter)
    (unless extending
      (ri--snap-to-unit-start))
    (ri--update-highlight)
    (when persistent-submode
      (ri--persist-selection-submode persistent-submode))))
(defun ri-extend-set-line-mode () (interactive) (ri--set-submode-with-extend #'sr-set-line-mode 'line))
(defun ri-extend-set-line-star-mode () (interactive) (ri--set-submode-with-extend #'sr-set-line-star-mode 'line-star))
(defun ri-extend-set-character-mode () (interactive) (ri--set-submode-with-extend #'sr-set-character-mode 'char))
(defun ri-extend-set-word-mode () (interactive) (ri--set-submode-with-extend #'sr-set-word-mode 'word))
(defun ri-extend-set-word-star-mode () (interactive) (ri--set-submode-with-extend #'sr-set-word-star-mode 'word-star))
(defun ri-extend-set-word-plus-mode () (interactive) (ri--set-submode-with-extend #'sr-set-word-plus-mode 'word-plus))
(defun ri-extend-set-subword-mode () (interactive) (ri--set-submode-with-extend #'sr-set-subword-mode 'subword))
(defun ri-extend-set-paragraph-mode () (interactive) (ri--set-submode-with-extend #'sr-set-paragraph-mode 'paragraph))
(defun ri-extend-set-node-mode () (interactive) (ri--set-submode-with-extend #'sr-set-node-mode 'node))


(defun ri-extend-escape ()
  "Exit selection-extend mode on Escape, or fall through to `mini-modal-normal'.
In NORM mode with an active extended selection: exit extend mode.
Otherwise: call `mini-modal-normal'."
  (interactive)
  (if (ri--selection-active-p)
      (progn
        (ri--exit-extend)
        (ri--update-highlight)
        (force-mode-line-update))
    (mini-modal-normal)))
(provide 'ri-extend)
;;; ri-extend.el ends here
