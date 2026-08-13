;;; status-frame.el --- TTY child frame above the mode line -*- lexical-binding: t; -*-

;; Version: 0.3.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: convenience, frames, terminals
;; URL: https://github.com/USER/status-frame

;;; Commentary:
;;
;; Minimal status frame for `emacs -nw'.
;;
;; This package intentionally uses the same low-level Emacs primitives used by
;; posframe: `make-frame', frame parameters, a dedicated buffer and a child
;; frame attached through `parent-frame'.  It does not depend on posframe.
;;
;; It requires an Emacs build with TTY child-frame support:
;;
;;   (featurep 'tty-child-frames)
;;
;; Example:
;;
;;   (status-frame-show " build: ok | tests: 42 ")
;;   (status-frame-set-text " branch: main ")
;;   (status-frame-hide)
;;   (status-frame-delete)

;;; Code:

(defgroup status-frame nil
  "TTY child frame panel above the bottom mode line."
  :group 'convenience
  :prefix "status-frame-")

(defcustom status-frame-height 4
  "Height of the status frame in terminal rows."
  :type 'integer)

(defcustom status-frame-border-width 0
  "TTY child-frame border width.
A non-zero value lets Emacs draw a terminal child-frame border."
  :type 'integer)

(defvar status-frame--frame nil)
(defvar status-frame--parent-frame nil)
(defconst status-frame--buffer-name " *status-frame*")

(defun status-frame--workable-p (&optional frame)
  "Return non-nil when FRAME supports TTY child frames."
  (let ((frame (or frame (selected-frame))))
    (and (not (display-graphic-p frame))
         (featurep 'tty-child-frames)
         (not (eq (frame-parameter frame 'minibuffer) 'only)))))

(defun status-frame--minibuffer-height (parent)
  "Return PARENT's minibuffer height in terminal rows."
  (let ((window (minibuffer-window parent)))
    (if (window-live-p window)
        (window-total-height window)
      0)))

(defun status-frame--bottom-mode-line-height (parent)
  "Return the height of the bottom mode line of PARENT in rows.
For a normal TTY mode line this is either zero or one row."
  (with-selected-frame parent
    (let* ((mini-height (status-frame--minibuffer-height parent))
           (row (- (frame-height parent) mini-height 1))
           (window (and (>= row 0) (window-at 0 row parent))))
      (if (and (window-live-p window)
               (window-mode-line-height window))
          1
        0))))

(defun status-frame--geometry (parent)
  "Return (LEFT TOP WIDTH HEIGHT) for a status frame in PARENT."
  (let* ((height (max 1 status-frame-height))
         (mini-height (status-frame--minibuffer-height parent))
         (mode-height (status-frame--bottom-mode-line-height parent))
         (top (- (frame-height parent)
                 mini-height
                 mode-height
                 height)))
    (list 0
          (max 0 top)
          (frame-width parent)
          height)))

(defun status-frame--create (parent)
  "Create a TTY child frame attached to PARENT."
  (let* ((buffer (get-buffer-create status-frame--buffer-name))
         (after-make-frame-functions nil)
         (border (max 0 status-frame-border-width))
         (frame
          (make-frame
           `((name . "status-frame")
             (title . "status-frame")
             (parent-frame . ,parent)
             (minibuffer . ,(minibuffer-window parent))
             (visibility . nil)
             (no-accept-focus . t)
             (no-other-frame . t)
             (unsplittable . t)
             (desktop-dont-save . t)
             (menu-bar-lines . 0)
             (tool-bar-lines . 0)
             (tab-bar-lines . 0)
             (tab-bar-lines-keep-state . t)
             (vertical-scroll-bars . nil)
             (horizontal-scroll-bars . nil)
             (left-fringe . 0)
             (right-fringe . 0)
             (border-width . 0)
             (internal-border-width . ,border)
             (child-frame-border-width . ,border)
             ;; Posframe uses `undecorated' on TTY child frames when no
             ;; explicit border is requested.
             (undecorated . ,(= border 0))
             (cursor-type . nil)
             (tty-non-selected-cursor . nil)
             (no-special-glyphs . t)
             (skip-taskbar . t)
             (width . 1)
             (height . 1)
             (left . 0)
             (top . 0)))))
    (with-current-buffer buffer
      (setq-local mode-line-format nil
                  header-line-format nil
                  tab-line-format nil
                  cursor-type nil
                  truncate-lines t
                  display-line-numbers nil))
    (let ((window (frame-root-window frame)))
      (set-window-parameter window 'mode-line-format 'none)
      (set-window-parameter window 'header-line-format 'none)
      (set-window-buffer window buffer)
      (set-window-dedicated-p window t))
    frame))

(defun status-frame--update-geometry (&optional _frame)
  "Resize and reposition the status frame.
_FRAME is ignored so this function can be installed in size hooks."
  (when (and (frame-live-p status-frame--frame)
             (frame-live-p status-frame--parent-frame))
    (pcase-let ((`(,left ,top ,width ,height)
                 (status-frame--geometry status-frame--parent-frame)))
      ;; For TTY child frames, update size before position.  Emacs' TTY
      ;; child-frame implementation uses the new size when resolving `top'
      ;; and `left'.
      (modify-frame-parameters
       status-frame--frame
       `((width . ,width)
         (height . ,height)
         (left . ,left)
         (top . ,top))))))

(defun status-frame--put-text (string)
  "Replace status-frame buffer contents with STRING."
  (with-current-buffer (get-buffer-create status-frame--buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert string))))

;;;###autoload
(defun status-frame-show (&optional string)
  "Show STRING in a TTY child frame panel above the bottom mode line."
  (interactive "sStatus: ")
  (let ((parent (selected-frame)))
    (unless (status-frame--workable-p parent)
      (user-error
       "status-frame requires emacs -nw with TTY child-frame support"))
    (unless (and (frame-live-p status-frame--frame)
                 (eq status-frame--parent-frame parent))
      (status-frame-delete)
      (setq status-frame--parent-frame parent
            status-frame--frame (status-frame--create parent)))
    (status-frame--put-text (or string ""))
    (status-frame--update-geometry)
    (make-frame-visible status-frame--frame)
    status-frame--frame))

;;;###autoload
(defun status-frame-set-text (string)
  "Replace the text displayed by the status frame with STRING."
  (interactive "sStatus: ")
  (if (frame-live-p status-frame--frame)
      (progn
        (status-frame--put-text string)
        (status-frame--update-geometry)
        status-frame--frame)
    (status-frame-show string)))

;;;###autoload
(defun status-frame-set-height (height)
  "Set status frame HEIGHT in terminal rows and update its geometry."
  (interactive "nHeight: ")
  (setq status-frame-height (max 1 height))
  (status-frame--update-geometry)
  status-frame-height)

;;;###autoload
(defun status-frame-hide ()
  "Hide the TTY status child frame."
  (interactive)
  (when (frame-live-p status-frame--frame)
    (make-frame-invisible status-frame--frame)))

;;;###autoload
(defun status-frame-delete ()
  "Delete the TTY status child frame and its buffer."
  (interactive)
  (when (frame-live-p status-frame--frame)
    (let ((delete-frame-functions nil))
      (delete-frame status-frame--frame)))
  (setq status-frame--frame nil
        status-frame--parent-frame nil)
  (when-let* ((buffer (get-buffer status-frame--buffer-name)))
    (kill-buffer buffer)))

(defun status-frame--parent-deleted (frame)
  "Delete the status frame when its parent FRAME is deleted."
  (when (eq frame status-frame--parent-frame)
    (status-frame-delete)))

(add-hook 'window-size-change-functions #'status-frame--update-geometry)
(add-hook 'delete-frame-functions #'status-frame--parent-deleted)

(provide 'status-frame)

;;; status-frame.el ends here
