;;; ri-mouse.el --- Mouse positioning for RI normal mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Roman Frołow
;; Author: Roman Frołow
;; Version: 0.2.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: convenience, editing, mouse
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;;
;; Mouse integration for RI normal mode.
;;
;; The package deliberately separates transport from semantics:
;;
;; - terminal Emacs uses the standard `xterm-mouse-mode' decoder;
;; - a completed primary click is positioned by `mouse-set-point';
;; - only after native point movement succeeds does RI retarget the current
;;   semantic unit (including direct lowest-node targeting in NODE mode).
;;
;; RI does not parse terminal escape sequences and does not take over drag,
;; wheel, mode-line, fringe, scroll-bar, or tab-bar events.

;;; Code:

(require 'mini-modal)
(require 'semantic-regions)
(require 'mouse)

(declare-function ri--exit-extend "ri-extend")

(defvar ri-mouse--terminal-support-enabled nil
  "Non-nil after RI has enabled standard terminal mouse reporting.")

(defun ri-mouse--text-position (event)
  "Return EVENT's buffer text position, or nil for non-text UI events."
  (condition-case nil
      (let* ((posn (event-end event))
             (position (and posn (posn-point posn))))
        (and (integer-or-marker-p position) position))
    (error nil)))

(defun ri-mouse--target-window (event)
  "Return the live window targeted by EVENT, or nil."
  (condition-case nil
      (let ((window (posn-window (event-end event))))
        (and (window-live-p window) window))
    (error nil)))

(defun ri-mouse--ri-norm-buffer-p ()
  "Return non-nil when current buffer should receive RI click semantics."
  (and (bound-and-true-p mini-modal-mode)
       (bound-and-true-p sr-mode)
       (not (minibufferp))
       (not (derived-mode-p 'special-mode))))

(defun ri-mouse-enable-terminal-support ()
  "Enable Emacs' standard terminal mouse decoder when RI runs on a TTY.
Return non-nil when no extra terminal support is needed or when terminal
mouse reporting is active.  RI never parses terminal mouse escape sequences
itself."
  (interactive)
  (cond
   ((display-graphic-p) t)
   ((not (fboundp 'xterm-mouse-mode)) nil)
   (t
    (unless (bound-and-true-p xterm-mouse-mode)
      (xterm-mouse-mode 1))
    (setq ri-mouse--terminal-support-enabled
          (bound-and-true-p xterm-mouse-mode))
    ri-mouse--terminal-support-enabled)))

(defun ri-mouse-set-point (event)
  "Move point for completed primary-click EVENT and retarget RI semantics.

Native Emacs mouse positioning runs first.  Semantic retargeting runs exactly
once, after the click, and only for buffer-text clicks in an RI NORM buffer.
Non-text UI events are left to their own keymaps and are not semantically
retargeted."
  (interactive "e")
  (when (and (ri-mouse--target-window event)
             (ri-mouse--text-position event))
    ;; `mouse-set-point' handles selecting another window, wrapped lines, and
    ;; the exact buffer position.  Do not duplicate its event decoding here.
    (mouse-set-point event)
    (when (ri-mouse--ri-norm-buffer-p)
      ;; A plain click starts a fresh semantic selection rather than extending
      ;; an old RI selection across the buffer.
      (when (fboundp 'ri--exit-extend)
        (ri--exit-extend))
      (sr-retarget-at-position (point))
      (force-mode-line-update))))

(defun ri-mouse-effective-bindings ()
  "Return diagnostic information about RI mouse transport and dispatch.
This is intended for interactive troubleshooting in the exact Emacs frontend
where a physical click is failing."
  (interactive)
  (let ((info
         (list
          :window-system window-system
          :graphic (display-graphic-p)
          :xterm-mouse-mode (bound-and-true-p xterm-mouse-mode)
          :mini-modal-mode (bound-and-true-p mini-modal-mode)
          :sr-mode (bound-and-true-p sr-mode)
          :map-mouse-1 (lookup-key mini-modal-map [mouse-1])
          :effective-mouse-1 (key-binding [mouse-1] t)
          :map-down-mouse-1 (lookup-key mini-modal-map [down-mouse-1])
          :effective-down-mouse-1 (key-binding [down-mouse-1] t))))
    (when (called-interactively-p 'interactive)
      (message "%S" info))
    info))

(defun ri-mouse-read-key ()
  "Read one translated key for mouse-transport diagnosis.
Unlike `read-event', `read-key' applies terminal input decoding, including
`xterm-mouse-mode' translation.  Invoke this command and physically click in
the failing frontend to see the event that reaches command lookup."
  (interactive)
  (let ((event (read-key "RI mouse diagnostic: click mouse-1 now: ")))
    (message "RI translated input: %S" event)
    event))

(defun ri-mouse-setup ()
  "Install RI primary-click positioning and terminal mouse support.

Only the completed `mouse-1' event is owned by RI.  Press, drag, wheel, and
other mouse gestures keep their normal Emacs bindings."
  (ri-mouse-enable-terminal-support)
  (define-key mini-modal-map [mouse-1] #'ri-mouse-set-point)
  ;; Undo the previous implementation if it was loaded in this Emacs session.
  ;; A press must not run the full semantic click action.
  (when (eq (lookup-key mini-modal-map [down-mouse-1]) #'ri-mouse-set-point)
    (define-key mini-modal-map [down-mouse-1] nil)))

(provide 'ri-mouse)
;;; ri-mouse.el ends here
