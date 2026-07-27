;;; modal-cursor.el --- Cursor style switching for modal editing -*- lexical-binding: t; -*-

;; Author: Roman Frolow
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, editing
;; URL: https://github.com/rofrol/modal-cursor

;;; Commentary:

;; Switches `cursor-type' between normal and insert states for modal
;; editing.  By default it watches `mini-modal-mode', but any minor
;; mode whose hook signals normal/insert transitions works.
;;
;; Normal mode (mini-modal-mode on):  `box' cursor
;; Insert mode (mini-modal-mode off): thin bar `(bar . 1)'
;;
;; On text terminals the package also manages cursor blinking:
;; the insert cursor starts steady, blinks after idle, and turns
;; steady again while typing.

;;; Code:

(defgroup modal-cursor nil
  "Cursor style switching for modal editing."
  :group 'convenience
  :prefix "modal-cursor-")

(defcustom modal-cursor-normal-type 'box
  "Cursor type used when the watched mode signals normal state."
  :type '(choice (const :tag "Box" box)
                 (const :tag "Bar" bar)
                 (cons :tag "Bar with width" (const bar) integer))
  :group 'modal-cursor)

(defcustom modal-cursor-insert-type '(bar . 1)
  "Cursor type used when the watched mode signals insert state."
  :type '(choice (const :tag "Box" box)
                 (const :tag "Bar" bar)
                 (cons :tag "Bar with width" (const bar) integer))
  :group 'modal-cursor)

(defcustom modal-cursor-watched-mode 'mini-modal-mode
  "Minor mode whose on/off state drives the cursor switch.
When this mode is enabled the cursor uses `modal-cursor-normal-type';
when disabled it uses `modal-cursor-insert-type'."
  :type 'symbol
  :group 'modal-cursor)

(defvar-local modal-cursor--blink-timer nil
  "Idle timer used to restart insert cursor blinking on a TTY.")

(defvar-local modal-cursor--blink-hooks-installed nil
  "Non-nil when pre/post-command and kill-buffer hooks are active.")

;; ---------------------------------------------------------------------------
;; TTY detection

(defun modal-cursor--tty-p ()
  "Return non-nil when the selected display is a live text terminal."
  (and (not noninteractive)
       (not (display-graphic-p))))

;; ---------------------------------------------------------------------------
;; Cursor blink helpers (TTY only)

(defun modal-cursor--blink-cancel ()
  "Cancel the buffer's pending insert cursor blink timer."
  (when (timerp modal-cursor--blink-timer)
    (cancel-timer modal-cursor--blink-timer)
    (setq modal-cursor--blink-timer nil)))

(defun modal-cursor--blink-set (blinking)
  "Set the TTY insert cursor to BLINKING or steady."
  (when (modal-cursor--tty-p)
    ;; DECSCUSR carries both shape and blink state.  Keep DEC Mode 12
    ;; out of this path so the terminal cannot restore its block default.
    (send-string-to-terminal
     (if blinking "\e[5 q" "\e[6 q"))))

(defun modal-cursor--blink-on-idle (buffer)
  "Enable insert cursor blinking when BUFFER has been idle."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq modal-cursor--blink-timer nil)
      (when (and (not (and (boundp modal-cursor-watched-mode)
                           (symbol-value modal-cursor-watched-mode)))
                 (modal-cursor--tty-p)
                 (eq (window-buffer (selected-window)) buffer))
        (modal-cursor--blink-set t)))))

(defun modal-cursor--blink-schedule ()
  "Schedule insert cursor blinking after the next idle interval."
  (when (and (not (and (boundp modal-cursor-watched-mode)
                       (symbol-value modal-cursor-watched-mode)))
             (modal-cursor--tty-p))
    (modal-cursor--blink-cancel)
    (setq modal-cursor--blink-timer
          (run-with-idle-timer
           (max 0.2 (or (and (boundp 'blink-cursor-delay)
                             blink-cursor-delay)
                        0.5))
           nil #'modal-cursor--blink-on-idle (current-buffer)))))

(defun modal-cursor--blink-pre-command ()
  "Stop insert cursor blinking before handling a command."
  (when (not (and (boundp modal-cursor-watched-mode)
                  (symbol-value modal-cursor-watched-mode)))
    (modal-cursor--blink-cancel)
    (modal-cursor--blink-set nil)))

(defun modal-cursor--blink-post-command ()
  "Restart the insert cursor idle timer after a command."
  (when (not (and (boundp modal-cursor-watched-mode)
                  (symbol-value modal-cursor-watched-mode)))
    (modal-cursor--blink-schedule)))

(defun modal-cursor--blink-kill-buffer ()
  "Cancel the insert cursor timer before killing this buffer."
  (modal-cursor--blink-cancel))

;; ---------------------------------------------------------------------------
;; Cursor type

(defun modal-cursor--set-type (type)
  "Set buffer-local `cursor-type' to TYPE and sync TTY cursor shape."
  (setq cursor-type type)
  (when (modal-cursor--tty-p)
    ;; Emacs re-applies the terminal's "very visible" cursor after
    ;; redisplay when `visible-cursor' is non-nil.  That can reset the
    ;; explicit cursor shape below, so let this function own the shape.
    (setq visible-cursor nil)
    (send-string-to-terminal
     (if (eq type 'box) "\e[2 q" "\e[6 q"))))

;; ---------------------------------------------------------------------------
;; Blink hook management

(defun modal-cursor--blink-hooks-install ()
  "Install insert-state cursor blink hooks buffer-locally."
  (unless modal-cursor--blink-hooks-installed
    (add-hook 'pre-command-hook #'modal-cursor--blink-pre-command nil t)
    (add-hook 'post-command-hook #'modal-cursor--blink-post-command nil t)
    (add-hook 'kill-buffer-hook #'modal-cursor--blink-kill-buffer nil t)
    (setq modal-cursor--blink-hooks-installed t)))

(defun modal-cursor--blink-hooks-remove ()
  "Remove insert-state cursor blink hooks buffer-locally."
  (when modal-cursor--blink-hooks-installed
    (remove-hook 'pre-command-hook #'modal-cursor--blink-pre-command t)
    (remove-hook 'post-command-hook #'modal-cursor--blink-post-command t)
    (remove-hook 'kill-buffer-hook #'modal-cursor--blink-kill-buffer t)
    (modal-cursor--blink-cancel)
    (setq modal-cursor--blink-hooks-installed nil)))

;; ---------------------------------------------------------------------------
;; Mode transition

(defun modal-cursor--update ()
  "Update cursor type and blink hooks for the current modal state."
  ;; Ensure this buffer watches the mode.  Idempotent; also handles
  ;; buffers created after `modal-cursor-mode' was enabled.
  (let ((hook (intern (format "%s-hook" modal-cursor-watched-mode))))
    (add-hook hook #'modal-cursor--update nil t))
  (if (and (boundp modal-cursor-watched-mode)
           (symbol-value modal-cursor-watched-mode))
      ;; Normal mode: box cursor, no blink hooks.
      (progn
        (modal-cursor--blink-hooks-remove)
        (modal-cursor--set-type modal-cursor-normal-type))
    ;; Insert mode: thin cursor, manage blink hooks.
    (modal-cursor--set-type modal-cursor-insert-type)
    (modal-cursor--blink-hooks-install)
    (modal-cursor--blink-schedule)))

;; ---------------------------------------------------------------------------
;; Minor mode

;;;###autoload
(define-minor-mode modal-cursor-mode
  "Automatically switch cursor style between normal and insert states.

When the mode specified by `modal-cursor-watched-mode' is enabled
\(normal state), the cursor uses `modal-cursor-normal-type' (default
`box').  When it is disabled (insert state), the cursor uses
`modal-cursor-insert-type' (default a thin bar).

On text terminals, insert-mode cursor blinking is also managed:
steady while typing, blinking after idle."
  :global t
  :group 'modal-cursor
  (if modal-cursor-mode
      (progn
        (add-hook 'after-change-major-mode-hook #'modal-cursor--update)
        (dolist (buf (buffer-list))
          (when (and (buffer-live-p buf)
                     (not (minibufferp buf)))
            (with-current-buffer buf
              (let ((hook (intern (format "%s-hook" modal-cursor-watched-mode))))
                (add-hook hook #'modal-cursor--update nil t))
              (modal-cursor--update)))))
    (remove-hook 'after-change-major-mode-hook #'modal-cursor--update)
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((hook (intern (format "%s-hook" modal-cursor-watched-mode))))
            (remove-hook hook #'modal-cursor--update t))
          (modal-cursor--blink-hooks-remove))))))

(provide 'modal-cursor)
;;; modal-cursor.el ends here
