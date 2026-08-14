;;; ri-pick.el --- Floating picker UI for Ri -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow

;;; Commentary:

;; One-window fuzzy picker displayed through `display-buffer-in-child-frame'.
;; It owns only that child-frame surface, not the surrounding menu UI.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'ri-tabs)
(require 'seq)
(require 'subr-x)

(defgroup ri-pick nil
  "Floating picker UI for Ri."
  :group 'ri
  :prefix "ri-pick-")

(defcustom ri-pick-width 0.7
  "Fraction of the usable parent-frame width occupied by a picker."
  :type 'number)

(defcustom ri-pick-height 0.55
  "Fraction of the usable parent-frame height occupied by a picker."
  :type 'number)

(defcustom ri-pick-min-width 48
  "Preferred minimum picker width in terminal columns."
  :type 'integer)

(defcustom ri-pick-min-height 8
  "Preferred minimum picker height in terminal rows."
  :type 'integer)

(defcustom ri-pick-query-delay 0.12
  "Idle delay before invoking a dynamic picker provider."
  :type 'number)

(defface ri-pick-selected
  '((t (:inherit highlight :background "#d0d0d0" :extend t)))
  "Face used for the selected picker result."
  :group 'ri-pick)

(defface ri-pick-annotation
  '((t (:inherit shadow)))
  "Face used for picker result annotations."
  :group 'ri-pick)

(cl-defstruct (ri-pick-item (:constructor ri-pick-item-create))
  "One selectable picker item."
  label annotation search target)

(cl-defstruct (ri-pick--session (:constructor ri-pick--session-create))
  title
  source-frame source-window source-buffer source-point
  buffer window
  query-start query-end
  items filtered index offset status
  accept provider cancel-request timer generation
  on-close)

(defvar ri-pick--session nil
  "The active picker session, or nil.")

(defvar ri-pick--cleanup-running nil
  "Non-nil while picker cleanup is in progress.")

(defvar-local ri-pick--buffer-session nil
  "Picker session owning the current picker buffer.")

(defun ri-pick--active-session ()
  "Return the active live picker session, or nil."
  (and (ri-pick--session-p ri-pick--session) ri-pick--session))

(defun ri-pick--ensure-query-markers (session)
  "Ensure SESSION has query boundary markers in its picker buffer."
  (let ((buffer (ri-pick--session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless (markerp (ri-pick--session-query-start session))
          (setf (ri-pick--session-query-start session) (make-marker)))
        (unless (markerp (ri-pick--session-query-end session))
          (setf (ri-pick--session-query-end session) (make-marker)))
        (let ((start (ri-pick--session-query-start session))
              (end (ri-pick--session-query-end session)))
          (unless (eq (marker-buffer start) buffer)
            (set-marker start (point-min) buffer))
          (unless (eq (marker-buffer end) buffer)
            (set-marker end (point-min) buffer))
          (set-marker-insertion-type start nil)
          (set-marker-insertion-type end t))))))

(defun ri-pick--query-bounds (&optional session)
  "Return the editable query bounds for SESSION or the active picker."
  (when-let* ((session (or session (ri-pick--active-session)))
              (buffer (ri-pick--session-buffer session))
              ((buffer-live-p buffer))
              (start-marker (ri-pick--session-query-start session))
              (end-marker (ri-pick--session-query-end session))
              ((eq (marker-buffer start-marker) buffer))
              ((eq (marker-buffer end-marker) buffer))
              (start (marker-position start-marker))
              (end (marker-position end-marker))
              ((<= start end)))
    (cons start end)))

(defun ri-pick--query ()
  "Return the query from the active picker buffer."
  (when-let* ((session (ri-pick--active-session))
              (buffer (ri-pick--session-buffer session))
              (bounds (ri-pick--query-bounds session)))
    (with-current-buffer buffer
      (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(defun ri-pick--subsequence-score (query candidate)
  "Score QUERY against CANDIDATE, or return nil when it does not match."
  (let* ((query (downcase query))
         (candidate (downcase candidate))
         (query-length (length query))
         (candidate-length (length candidate)))
    (cond
     ((zerop query-length) 0)
     ((string= query candidate) 100000)
     ((string-prefix-p query candidate)
      (- 80000 candidate-length))
     ((string-match-p (regexp-quote query) candidate)
      (let ((start (string-match (regexp-quote query) candidate)))
        (- 60000 (* 10 start) candidate-length)))
     (t
      (let ((query-index 0)
            (candidate-index 0)
            (first nil)
            (previous nil)
            (gaps 0)
            (boundary-bonus 0))
        (while (and (< query-index query-length)
                    (< candidate-index candidate-length))
          (if (eq (aref query query-index)
                  (aref candidate candidate-index))
              (progn
                (unless first (setq first candidate-index))
                (when (and (> candidate-index 0)
                           (memq (aref candidate (1- candidate-index))
                                 '(?/ ?- ?_ ?. ?\s)))
                  (cl-incf boundary-bonus))
                (when previous
                  (cl-incf gaps (1- (- candidate-index previous))))
                (setq previous candidate-index)
                (cl-incf query-index)))
          (cl-incf candidate-index))
        (when (= query-index query-length)
          (+ 20000
             (* 100 boundary-bonus)
             (- (* 10 (or first 0)))
             (- (* 3 gaps))
             (- candidate-length))))))))

(defun ri-pick--filter-items (query items)
  "Return ITEMS matching QUERY in stable score order."
  (let (scored)
    (cl-loop for item in items
             for source-index from 0
             for candidate = (or (ri-pick-item-search item)
                                 (ri-pick-item-label item))
             for score = (ri-pick--subsequence-score query candidate)
             when score
             do (push (list score source-index item) scored))
    (mapcar
     #'caddr
     (sort scored
           (lambda (left right)
             (if (= (car left) (car right))
                 (< (cadr left) (cadr right))
               (> (car left) (car right))))))))

(defun ri-pick--visible-count (session)
  "Return the number of result rows visible for SESSION."
  (let ((window (ri-pick--session-window session)))
    (max 1 (- (if (window-live-p window)
                  (window-body-height window)
                ri-pick-min-height)
              4))))

(defun ri-pick--clamp-selection (session)
  "Clamp SESSION's selection and scroll offset to its filtered items."
  (let* ((count (length (ri-pick--session-filtered session)))
         (visible (ri-pick--visible-count session))
         (index (if (zerop count)
                    0
                  (min (max 0 (ri-pick--session-index session))
                       (1- count))))
         (offset (max 0 (ri-pick--session-offset session))))
    (when (< index offset)
      (setq offset index))
    (when (>= index (+ offset visible))
      (setq offset (1+ (- index visible))))
    (when (> offset (max 0 (- count visible)))
      (setq offset (max 0 (- count visible))))
    (setf (ri-pick--session-index session) index
          (ri-pick--session-offset session) offset)))

(defun ri-pick--result-text (item selected width)
  "Return rendered ITEM text for WIDTH, using SELECTED styling when non-nil."
  (let* ((label (or (ri-pick-item-label item) ""))
         (annotation (or (ri-pick-item-annotation item) ""))
         (separator (if (string-empty-p annotation) "" "  "))
         (annotation-width (min (string-width annotation)
                                (max 0 (/ width 2))))
         (label-width (max 1 (- width (string-width separator)
                                annotation-width)))
         (label (truncate-string-to-width label label-width nil nil "…"))
         (annotation (truncate-string-to-width
                      annotation annotation-width nil nil "…"))
         (padding (make-string
                   (max 0 (- width (string-width label)
                             (string-width separator)
                             (string-width annotation)))
                   ?\s))
         (text (concat label padding separator
                       (propertize annotation 'face 'ri-pick-annotation))))
    (when selected
      (add-face-text-property 0 (length text) 'ri-pick-selected t text))
    text))

(defun ri-pick--border-line (width left right)
  "Return a WIDTH-column border between LEFT and RIGHT."
  (concat left (make-string (max 0 (- width 2)) ?─) right))

(defun ri-pick--title-line (title width)
  "Return a WIDTH-column rounded top border containing TITLE."
  (let* ((inside-width (max 0 (- width 2)))
         (title-width (max 0 (- inside-width 3)))
         (title (truncate-string-to-width (or title "") title-width
                                          nil nil "…"))
         (prefix (if (and (> inside-width 2) (not (string-empty-p title)))
                     (concat "─ " title " ")
                   ""))
         (rest (max 0 (- inside-width (string-width prefix)))))
    (concat "╭" prefix (make-string rest ?─) "╮")))

(defun ri-pick--render (session)
  "Render SESSION as a rounded box without moving its query point."
  (when-let* ((buffer (ri-pick--session-buffer session))
              ((buffer-live-p buffer)))
    (ri-pick--ensure-query-markers session)
    (ri-pick--clamp-selection session)
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             (bounds (ri-pick--query-bounds session))
             (query (if bounds
                        (buffer-substring-no-properties
                         (car bounds) (cdr bounds))
                      ""))
             (query-offset
              (if bounds
                  (min (length query)
                       (max 0 (- (point) (car bounds))))
                0))
             (items (ri-pick--session-filtered session))
             (index (ri-pick--session-index session))
             (offset (ri-pick--session-offset session))
             (visible (ri-pick--visible-count session))
             (window (ri-pick--session-window session))
             ;; Emacs reserves the final column for its truncation glyph.
             (width (max 4 (1- (if (window-live-p window)
                                   (window-body-width window)
                                 ri-pick-min-width))))
             (content-width (- width 4))
             (status (ri-pick--session-status session))
             (rows 0)
             query-start query-end)
        (erase-buffer)
        (insert (ri-pick--title-line
                 (ri-pick--session-title session) width)
                "\n│ ")
        (setq query-start (point))
        (insert query)
        (setq query-end (point))
        (insert (make-string
                 (max 0 (- content-width (string-width query))) ?\s)
                " │\n"
                (ri-pick--border-line width "├" "┤")
                "\n")
        (cl-labels
            ((insert-row
              (text &optional item)
              (let* ((text (truncate-string-to-width
                            (or text "") content-width nil nil "…"))
                     (text-width (string-width text)))
                (insert "│ ")
                (let ((content-start (point)))
                  (insert text
                          (make-string
                           (max 0 (- content-width text-width)) ?\s))
                  (when item
                    (add-text-properties content-start (point)
                                         (list 'ri-pick-item item))))
                (insert " │\n")
                (cl-incf rows))))
          (cond
           (status
            (insert-row (propertize status 'face 'ri-pick-annotation)))
           ((null items)
            (insert-row
             (propertize "No matches" 'face 'ri-pick-annotation)))
           (t
            (cl-loop for item in (seq-subseq
                                  items offset (min (length items)
                                                    (+ offset visible)))
                     for row from offset
                     do (insert-row
                         (ri-pick--result-text
                          item (= row index) content-width)
                         item))))
          (while (< rows visible)
            (insert-row "")))
        (insert (ri-pick--border-line width "╰" "╯"))
        (add-face-text-property (point-min) (point-max) 'fixed-pitch t)
        (add-text-properties (point-min) (point-max)
                             '(read-only t rear-nonsticky t))
        (remove-text-properties query-start query-end '(read-only nil))
        (let ((start-marker (ri-pick--session-query-start session))
              (end-marker (ri-pick--session-query-end session)))
          (set-marker start-marker query-start buffer)
          (set-marker end-marker query-end buffer)
          (set-marker-insertion-type start-marker nil)
          (set-marker-insertion-type end-marker t))
        (goto-char (+ query-start query-offset))
        (when (window-live-p window)
          (set-window-point window (point))
          (set-window-start window (point-min)))))))

(defun ri-pick--cancel-pending (session)
  "Cancel SESSION's timer and provider request."
  (when-let* ((timer (ri-pick--session-timer session)))
    (cancel-timer timer)
    (setf (ri-pick--session-timer session) nil))
  (when-let* ((cancel (ri-pick--session-cancel-request session)))
    (setf (ri-pick--session-cancel-request session) nil)
    (ignore-errors (funcall cancel))))

(defun ri-pick--provider-success (session generation items)
  "Install provider ITEMS for SESSION when GENERATION is still current."
  (when (and (eq session (ri-pick--active-session))
             (= generation (ri-pick--session-generation session)))
    (setf (ri-pick--session-cancel-request session) nil
          (ri-pick--session-items session) items
          (ri-pick--session-filtered session) items
          (ri-pick--session-index session) 0
          (ri-pick--session-offset session) 0
          (ri-pick--session-status session) nil)
    (ri-pick--render session)))

(defun ri-pick--provider-error (session generation error)
  "Render provider ERROR when SESSION GENERATION is still current."
  (when (and (eq session (ri-pick--active-session))
             (= generation (ri-pick--session-generation session)))
    (setf (ri-pick--session-cancel-request session) nil
          (ri-pick--session-filtered session) nil
          (ri-pick--session-status session)
          (format "Error: %s" error))
    (ri-pick--render session)))

(defun ri-pick--run-provider (session query generation)
  "Run SESSION's dynamic provider for QUERY and GENERATION."
  (when (and (eq session (ri-pick--active-session))
             (= generation (ri-pick--session-generation session)))
    (setf (ri-pick--session-timer session) nil)
    (condition-case error
        (setf (ri-pick--session-cancel-request session)
              (funcall
               (ri-pick--session-provider session)
               query
               (lambda (items)
                 (ri-pick--provider-success session generation items))
               (lambda (provider-error)
                 (ri-pick--provider-error
                  session generation provider-error))))
      (error
       (ri-pick--provider-error
        session generation (error-message-string error))))))

(defun ri-pick--query-changed ()
  "Refilter or refresh the active picker after query input changed."
  (when-let* ((session (ri-pick--active-session)))
    (let ((query (or (ri-pick--query) "")))
      (setf (ri-pick--session-index session) 0
            (ri-pick--session-offset session) 0)
      (if-let* ((provider (ri-pick--session-provider session)))
          (progn
            (ignore provider)
            (ri-pick--cancel-pending session)
            (cl-incf (ri-pick--session-generation session))
            (setf (ri-pick--session-filtered session) nil
                  (ri-pick--session-status session) "Loading…"
                  (ri-pick--session-timer session)
                  (run-at-time
                   ri-pick-query-delay nil #'ri-pick--run-provider
                   session query (ri-pick--session-generation session)))
            (ri-pick--render session))
        (setf (ri-pick--session-filtered session)
              (ri-pick--filter-items query
                                     (ri-pick--session-items session))
              (ri-pick--session-status session) nil)
        (ri-pick--render session)))))

(defun ri-pick-self-insert (count)
  "Insert the typed character COUNT times into the picker query."
  (interactive "p")
  (let ((inhibit-read-only t))
    (self-insert-command count))
  (ri-pick--query-changed))

(defun ri-pick-delete-backward ()
  "Delete one query character before point."
  (interactive)
  (when-let* ((bounds (ri-pick--query-bounds))
              ((> (point) (car bounds))))
    (let ((inhibit-read-only t))
      (delete-char -1))
    (ri-pick--query-changed)))

(defun ri-pick-delete-forward ()
  "Delete one query character after point."
  (interactive)
  (when-let* ((bounds (ri-pick--query-bounds))
              ((< (point) (cdr bounds))))
    (let ((inhibit-read-only t))
      (delete-char 1))
    (ri-pick--query-changed)))

(defun ri-pick-yank ()
  "Yank single-line text into the query and refresh results."
  (interactive)
  (let ((text (replace-regexp-in-string
               "[\n\r]+" " " (current-kill 0 t)))
        (inhibit-read-only t))
    (insert text))
  (ri-pick--query-changed))

(defun ri-pick-move (delta)
  "Move the picker selection by DELTA results."
  (when-let* ((session (ri-pick--active-session))
              (items (ri-pick--session-filtered session)))
    (setf (ri-pick--session-index session)
          (min (1- (length items))
               (max 0 (+ (ri-pick--session-index session) delta))))
    (ri-pick--render session)))

(defun ri-pick-next ()
  "Select the next picker result."
  (interactive)
  (ri-pick-move 1))

(defun ri-pick-previous ()
  "Select the previous picker result."
  (interactive)
  (ri-pick-move -1))

(defun ri-pick-page-down ()
  "Move one visible picker page down."
  (interactive)
  (when-let* ((session (ri-pick--active-session)))
    (ri-pick-move (ri-pick--visible-count session))))

(defun ri-pick-page-up ()
  "Move one visible picker page up."
  (interactive)
  (when-let* ((session (ri-pick--active-session)))
    (ri-pick-move (- (ri-pick--visible-count session)))))

(defun ri-pick-query-beginning ()
  "Move to the beginning of the picker query."
  (interactive)
  (when-let* ((bounds (ri-pick--query-bounds)))
    (goto-char (car bounds))))

(defun ri-pick-query-end ()
  "Move to the end of the picker query."
  (interactive)
  (when-let* ((bounds (ri-pick--query-bounds)))
    (goto-char (cdr bounds))))

(defvar ri-pick-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'ri-pick-self-insert)
    (define-key map (kbd "DEL") #'ri-pick-delete-backward)
    (define-key map (kbd "<backspace>") #'ri-pick-delete-backward)
    (define-key map (kbd "C-d") '(menu-item "Page Down" ri-pick-page-down))
    (define-key map (kbd "C-u") '(menu-item "Page Up" ri-pick-page-up))
    (define-key map (kbd "C-j") '(menu-item "Next" ri-pick-next))
    (define-key map (kbd "C-k") '(menu-item "Previous" ri-pick-previous))
    (define-key map (kbd "<down>") #'ri-pick-next)
    (define-key map (kbd "<up>") #'ri-pick-previous)
    (define-key map (kbd "<delete>") #'ri-pick-delete-forward)
    (define-key map (kbd "C-a") #'ri-pick-query-beginning)
    (define-key map (kbd "C-e") #'ri-pick-query-end)
    (define-key map (kbd "C-y") #'ri-pick-yank)
    (define-key map (kbd "RET") '(menu-item "Open" ri-pick-accept))
    (define-key map (kbd "<return>") '(menu-item "Open" ri-pick-accept))
    (define-key map (kbd "C-g") '(menu-item "Cancel" ri-pick-cancel))
    (define-key map (kbd "<escape>") '(menu-item "Cancel" ri-pick-cancel))
    map)
  "Keymap used by an active picker.")

(define-derived-mode ri-pick-mode special-mode "Ri-Pick"
  "Major mode for the editable query and read-only results of an Ri picker."
  (setq-local buffer-read-only nil
              truncate-lines t
              cursor-type 'bar
              mode-line-format nil
              tab-line-format nil
              header-line-format nil
              display-line-numbers nil)
  ;; `special-mode-map' binds printable characters such as `q', `-' and
  ;; digits.  Stay derived from Special so global modal setup skips this
  ;; buffer, but leave every printable local key to self insertion.
  (set-keymap-parent ri-pick-mode-map nil)
  (when (fboundp 'mini-modal-mode)
    (mini-modal-mode -1)))

(defun ri-pick--top-reserved-edge (frame)
  "Return the first usable row below top side windows in FRAME."
  (let ((top 0))
    (walk-windows
     (lambda (window)
       (when (eq (window-parameter window 'window-side) 'top)
         (setq top (max top (nth 3 (window-edges window))))))
     'nomini frame)
    top))

(defun ri-pick--bottom-usable-edge (frame)
  "Return the bottom usable row in FRAME above its minibuffer."
  (- (frame-height frame)
     (if-let* ((minibuffer (minibuffer-window frame))
               ((window-live-p minibuffer)))
         (window-total-height minibuffer)
       0)))

(defun ri-pick--geometry (frame)
  "Return (LEFT TOP WIDTH HEIGHT) for a picker inside FRAME."
  (let* ((left-edge 0)
         (right-edge (frame-width frame))
         (top-edge (ri-pick--top-reserved-edge frame))
         (bottom-edge (max (1+ top-edge)
                           (ri-pick--bottom-usable-edge frame)))
         (available-width (max 1 (- right-edge left-edge)))
         (available-height (max 1 (- bottom-edge top-edge)))
         (width (min available-width
                     (max 1 ri-pick-min-width
                          (round (* available-width ri-pick-width)))))
         (height (min available-height
                      (max 1 ri-pick-min-height
                           (round (* available-height ri-pick-height)))))
         (left (+ left-edge (/ (- available-width width) 2)))
         (top (+ top-edge (/ (- available-height height) 2))))
    (list left top width height)))

(defun ri-pick--frame-parameters (parent)
  "Return child-frame parameters for a picker attached to PARENT."
  (pcase-let ((`(,left ,top ,width ,height) (ri-pick--geometry parent)))
    `((name . "ri-pick")
      (title . "ri-pick")
      (parent-frame . ,parent)
      (minibuffer . ,(minibuffer-window parent))
      (share-child-frame . ri-pick)
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
      (internal-border-width . 0)
      (child-frame-border-width . 0)
      (undecorated . t)
      (cursor-type . bar)
      (tty-non-selected-cursor . nil)
      (no-special-glyphs . t)
      (skip-taskbar . t)
      (width . ,width)
      (height . ,height)
      (left . ,left)
      (top . ,top))))

(defun ri-pick--update-geometry (&optional frame)
  "Resize the active picker when its parent FRAME changes."
  (when-let* ((session (ri-pick--active-session))
              (parent (ri-pick--session-source-frame session))
              (window (ri-pick--session-window session))
              ((window-live-p window))
              ((or (null frame) (eq frame parent))))
    (pcase-let ((`(,left ,top ,width ,height) (ri-pick--geometry parent))
                (picker-frame (window-frame window)))
      (modify-frame-parameters
       picker-frame
       `((width . ,width) (height . ,height)
         (left . ,left) (top . ,top)))
      (ri-pick--render session))))

(defun ri-pick--picker-buffer-killed ()
  "Clean up when the active picker buffer is killed externally."
  (unless ri-pick--cleanup-running
    (ri-pick--cleanup nil t)))

(defun ri-pick--frame-deleted (frame)
  "Clean up when picker FRAME is deleted externally."
  (when-let* ((session (ri-pick--active-session))
              (window (ri-pick--session-window session)))
    (when (eq frame (window-frame window))
      (ri-pick--cleanup nil t))))

(defun ri-pick--select-source (session restore-point)
  "Select SESSION's source context and optionally RESTORE-POINT."
  (let ((frame (ri-pick--session-source-frame session))
        (window (ri-pick--session-source-window session))
        (buffer (ri-pick--session-source-buffer session))
        (marker (ri-pick--session-source-point session)))
    (when (and (frame-live-p frame) (window-live-p window))
      (select-frame frame)
      (select-window window)
      (when (buffer-live-p buffer)
        (unless (eq (window-buffer window) buffer)
          (set-window-buffer window buffer))
        (when (and restore-point (marker-position marker))
          (with-current-buffer buffer
            (goto-char marker))
          (set-window-point window marker))))))

(defun ri-pick--cleanup (accepted &optional buffer-already-killing)
  "Close the picker; ACCEPTED distinguishes selection from cancellation.
When BUFFER-ALREADY-KILLING is non-nil, do not ask `quit-window' to kill it."
  (when-let* ((session (ri-pick--active-session)))
    (unless ri-pick--cleanup-running
      (let ((ri-pick--cleanup-running t)
            (window (ri-pick--session-window session))
            (buffer (ri-pick--session-buffer session))
            (on-close (ri-pick--session-on-close session)))
        (setq ri-pick--session nil)
        (ri-pick--cancel-pending session)
        (remove-hook 'window-size-change-functions #'ri-pick--update-geometry)
        (remove-hook 'delete-frame-functions #'ri-pick--frame-deleted)
        (when (window-live-p window)
          (ignore-errors (quit-window (not buffer-already-killing) window)))
        (when (and (not buffer-already-killing) (buffer-live-p buffer))
          (kill-buffer buffer))
        (ri-pick--select-source session (not accepted))
        (when-let* ((marker (ri-pick--session-source-point session)))
          (set-marker marker nil))
        (when on-close
          (funcall on-close accepted))))))

(defun ri-pick-cancel ()
  "Cancel the active picker and restore its exact source context."
  (interactive)
  (ri-pick--cleanup nil))

(defun ri-pick-accept ()
  "Accept the selected picker result."
  (interactive)
  (when-let* ((session (ri-pick--active-session)))
    (let* ((items (ri-pick--session-filtered session))
           (item (nth (ri-pick--session-index session) items))
           (accept (ri-pick--session-accept session)))
      (unless item
        (user-error "No picker result selected"))
      (ri-pick--cleanup t)
      (funcall accept item))))

(cl-defun ri-pick-start (title items accept
                               &key provider on-close)
  "Open a floating picker titled TITLE.
ITEMS is a list of `ri-pick-item' values.  ACCEPT receives the selected item.
PROVIDER, when non-nil, receives QUERY, SUCCESS and ERROR callbacks and may
return a cancellation function.  ON-CLOSE receives non-nil after acceptance."
  (when (ri-pick--active-session)
    (ri-pick-cancel))
  (let* ((source-frame (selected-frame))
         (source-window (selected-window))
         (source-buffer (current-buffer))
         (source-point (copy-marker (point)))
         (buffer (generate-new-buffer " *ri-pick*"))
         (session
          (ri-pick--session-create
           :title title
           :source-frame source-frame
           :source-window source-window
           :source-buffer source-buffer
           :source-point source-point
           :buffer buffer
           :items items
           :filtered items
           :index 0
           :offset 0
           :accept accept
           :provider provider
           :generation 0
           :on-close on-close))
         (success nil))
    (setq ri-pick--session session)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (ri-pick-mode)
            (display-line-numbers-mode -1)
            (setq-local ri-pick--buffer-session session)
            (let ((inhibit-read-only t))
              (erase-buffer))
            (ri-pick--ensure-query-markers session)
            (add-hook 'kill-buffer-hook
                      #'ri-pick--picker-buffer-killed nil t))
          (let ((window
                 (display-buffer
                  buffer
                  `((display-buffer-in-child-frame)
                    (inhibit-same-window . t)
                    (child-frame-parameters
                     . ,(ri-pick--frame-parameters source-frame))))))
            (unless (window-live-p window)
              (user-error "Could not create the picker window"))
            (setf (ri-pick--session-window session) window)
            (set-window-dedicated-p window t)
            (set-window-parameter window 'no-other-window t)
            (add-hook 'window-size-change-functions #'ri-pick--update-geometry)
            (add-hook 'delete-frame-functions #'ri-pick--frame-deleted)
            (if provider
                (ri-pick--query-changed)
              (setf (ri-pick--session-filtered session)
                    (ri-pick--filter-items "" items))
              (ri-pick--render session))
            (select-window window)
            (with-current-buffer buffer
              (goto-char
               (car (ri-pick--query-bounds session))))
            (setq success t)
            window))
      (unless success
        (ri-pick--cleanup nil)))))

(defun ri-pick--git-environment-p ()
  "Return non-nil when an explicit Git repository environment is active."
  (seq-some
   (lambda (variable)
     (let ((value (getenv variable)))
       (and value (not (string-empty-p value)))))
   '("GIT_DIR" "GIT_WORK_TREE")))

(defun ri-pick--project-context ()
  "Return (PROJECT ROOT GIT-DIRECTORY) for the current buffer.
GIT-DIRECTORY is non-nil when explicit Git environment variables select the
candidate source instead of PROJECT."
  (let* ((directory
          (file-name-as-directory (expand-file-name default-directory)))
         (git-root
          (and (ri-pick--git-environment-p)
               (ri-tabs-git-work-tree-root directory)))
         (project (and (not git-root) (project-current nil)))
         (root (or git-root
                   (and project (project-root project))
                   directory)))
    (list project
          (file-name-as-directory (expand-file-name root))
          (and git-root directory))))

(defun ri-pick--display-path (file root)
  "Return a concise display path for FILE relative to ROOT when possible."
  (let ((file (expand-file-name file))
        (root (file-name-as-directory (expand-file-name root))))
    (if (string-prefix-p root file)
        (file-relative-name file root)
      (abbreviate-file-name file))))

(defun ri-pick--buffer-items (root)
  "Return picker items for open file buffers, displaying paths from ROOT."
  (mapcar
   (lambda (buffer)
     (let* ((file (buffer-file-name buffer))
            (label (ri-pick--display-path file root))
            (annotation (if (buffer-modified-p buffer) "modified" "")))
       (ri-pick-item-create
        :label label :annotation annotation :search label :target buffer)))
   (ri-tabs-file-buffer-list)))

(defun ri-pick--accept-buffer (item)
  "Switch to the buffer targeted by ITEM."
  (let ((buffer (ri-pick-item-target item)))
    (unless (buffer-live-p buffer)
      (user-error "Selected buffer no longer exists"))
    (switch-to-buffer buffer)))

(defun ri-pick-open-buffers (&optional on-close)
  "Pick an open file buffer and call ON-CLOSE after the picker closes."
  (interactive)
  (pcase-let ((`(,_project ,root ,_git-directory)
               (ri-pick--project-context)))
    (ri-pick-start "Buffer" (ri-pick--buffer-items root)
                   #'ri-pick--accept-buffer :on-close on-close)))

(defun ri-pick--fallback-files (root)
  "Return regular files recursively below ROOT, skipping VCS metadata."
  (directory-files-recursively
   root "." nil
   (lambda (directory)
     (not (member (file-name-nondirectory (directory-file-name directory))
                  '(".git" ".hg" ".svn"))))))

(defun ri-pick--git-files (directory)
  "Return Git files across the work tree resolved from DIRECTORY."
  (let ((default-directory directory))
    (with-temp-buffer
      (condition-case error
          (let ((status
                 (process-file
                  "git" nil t nil
                  "ls-files" "-z" "--full-name"
                  "--cached" "--others" "--exclude-standard"
                  "--" ":/")))
            (unless (eq status 0)
              (user-error "Could not list files in the Git work tree"))
            (split-string (buffer-string) "\0" t))
        (file-error
         (user-error "Could not list files in the Git work tree: %s"
                     (error-message-string error)))))))

(defun ri-pick--file-items (project root git-directory)
  "Return file picker items from PROJECT, Git, or fallback ROOT traversal.
GIT-DIRECTORY selects direct Git enumeration when non-nil."
  (mapcar
   (lambda (file)
     (let* ((absolute (expand-file-name file root))
            (label (file-relative-name absolute root)))
       (ri-pick-item-create
        :label label :annotation "" :search label :target absolute)))
   (cond
    (git-directory (ri-pick--git-files git-directory))
    (project (project-files project))
    (t (ri-pick--fallback-files root)))))

(defun ri-pick--accept-file (item)
  "Visit the file targeted by ITEM."
  (find-file (ri-pick-item-target item)))

(defun ri-pick-open-files (&optional on-close)
  "Pick a project file and call ON-CLOSE after the picker closes."
  (interactive)
  (pcase-let ((`(,project ,root ,git-directory)
               (ri-pick--project-context)))
    (ri-pick-start "File"
                   (ri-pick--file-items project root git-directory)
                   #'ri-pick--accept-file :on-close on-close)))

(provide 'ri-pick)
;;; ri-pick.el ends here
