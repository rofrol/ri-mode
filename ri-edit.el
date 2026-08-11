;;; ri-edit.el --- Delete, join, swap, and open operations for ri -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;;; Code:
(require 'cl-lib)
(require 'semantic-regions)
(require 'ri-extend)
(require 'ri-duplicate)
(require 'mini-modal)

(cl-defstruct (ri--range (:constructor ri--range-create)) start end point-after)

(defun ri--line-submode-p () (memq sr-submode '(line line-star)))
(defun ri--direction-before-p (direction) (memq direction '(:left :prev :first :up)))

(defun ri--target-unit-bounds (movement current &optional _preserve-reached)
  "Return semantic-region bounds reached from CURRENT by MOVEMENT."
  (save-excursion
    (let ((ri--selection nil))
      (goto-char (if (memq movement '(:left :prev :first :up))
                     (car current)
                   (max (car current) (1- (cdr current)))))
      (condition-case nil
          (progn
            (pcase movement
              (:left (sr-nav-left)) (:right (sr-nav-right))
              (:prev (sr-nav-prev)) (:next (sr-nav-next))
              (:up (sr-nav-up)) (:down (sr-nav-down))
              (:first (sr-nav-first)) (:last (sr-nav-last)))
            (sr--get-current-unit-bounds))
        ((beginning-of-buffer end-of-buffer) nil)))))

(defun ri--delete-bounds ()
  (when-let* ((bounds (ri--selection-bounds)))
    (if (ri--line-submode-p)
        (cons (car bounds)
              (save-excursion
                (goto-char (cdr bounds))
                (let ((e (line-end-position))) (if (< e (point-max)) (1+ e) e))))
      bounds)))

(defun ri--finish-selection-edit ()
  (ri--exit-extend) (ri--update-highlight) (force-mode-line-update))

(defun ri--delete-range (start end point-after)
  (when (< start end)
    (ri--with-buffer-edit
      (goto-char start) (delete-region start end)
      (goto-char (min point-after (point-max))))))

(defun ri-delete-selection ()
  "Delete current selection/unit and leave Extend."
  (interactive)
  (when-let* ((b (ri--delete-bounds))) (ri--delete-range (car b) (cdr b) (car b)))
  (ri--finish-selection-edit))

(defun ri--range-toward (current target)
  (when (and current target)
    (cond ((>= (car target) (cdr current)) (cons (car current) (car target)))
          ((<= (cdr target) (car current)) (cons (cdr target) (cdr current))))))

(defun ri--delete-with-movement (movement)
  (let* ((cur (ri--selection-bounds))
         (target (and cur (ri--target-unit-bounds movement cur)))
         (range (or (ri--range-toward cur target) (ri--delete-bounds))))
    (when range (ri--delete-range (car range) (cdr range) (car range)))
    (ri--finish-selection-edit)))
(defun ri-eat-left () (interactive) (ri--delete-with-movement :left))
(defun ri-eat-right () (interactive) (ri--delete-with-movement :right))
(defun ri-eat-prev () (interactive) (ri--delete-with-movement :prev))
(defun ri-eat-next () (interactive) (ri--delete-with-movement :next))
(defun ri-eat-first () (interactive) (ri--delete-with-movement :first))
(defun ri-eat-last () (interactive) (ri--delete-with-movement :last))

(defun ri-change-selection ()
  "Delete current selection/unit and enter INST."
  (interactive)
  (when-let* ((b (ri--selection-bounds))) (ri--delete-range (car b) (cdr b) (car b)))
  (ri--exit-extend) (ri--update-highlight) (mini-modal-insert))
(defun ri--cut-bounds ()
  "Return non-empty bounds for the current selection or unit."
  (when-let* ((bounds (ri--selection-bounds)))
    (let ((start (car bounds))
          (end (cdr bounds)))
      (when (= start end)
        (setq end (min (1+ start) (point-max))))
      (when (< start end)
        (cons start end)))))

(defun ri--cut-range (start end point-after)
  "Cut START through END and leave point at POINT-AFTER."
  (when (< start end)
    (ri--with-buffer-edit
      (kill-new (buffer-substring-no-properties start end))
      (goto-char start)
      (delete-region start end)
      (goto-char (min point-after (point-max))))))

(defun ri-cut-selection ()
  "Cut the current selection or unit to the kill ring and leave Extend."
  (interactive)
  (when-let* ((bounds (ri--cut-bounds)))
    (ri--cut-range (car bounds) (cdr bounds) (car bounds)))
  (ri--finish-selection-edit))

(defun ri--cut-with-movement (movement)
  "Cut toward MOVEMENT while preserving the reached unit."
  (let* ((current (ri--cut-bounds))
         (target (and current
                      (ri--target-unit-bounds movement current)))
         (range (or (ri--range-toward current target) current)))
    (when range
      (ri--cut-range (car range) (cdr range) (car range)))
    (ri--finish-selection-edit)))

(defun ri-cut-left ()
  "Cut toward the unit on the left."
  (interactive)
  (ri--cut-with-movement :left))

(defun ri-cut-right ()
  "Cut toward the unit on the right."
  (interactive)
  (ri--cut-with-movement :right))

(defun ri-cut-prev ()
  "Cut toward the previous significant unit."
  (interactive)
  (ri--cut-with-movement :prev))

(defun ri-cut-next ()
  "Cut toward the next significant unit."
  (interactive)
  (ri--cut-with-movement :next))

(defun ri-cut-first ()
  "Cut toward the first unit."
  (interactive)
  (ri--cut-with-movement :first))

(defun ri-cut-last ()
  "Cut toward the last unit."
  (interactive)
  (ri--cut-with-movement :last))


(defun ri--enter-open-insert ()
  (ri--exit-extend) (ri--update-highlight) (mini-modal-insert))
(defun ri--open-with-gap (direction)
  (when-let* ((b (ri--selection-bounds)))
    (let ((gap (ri--compute-gap direction b))
          (pos (if (ri--direction-before-p direction) (car b) (cdr b))))
      (ri--with-buffer-edit
        (goto-char pos) (insert gap)
        (when (ri--direction-before-p direction) (goto-char pos)))
      (ri--enter-open-insert))))
(defun ri-open-left () (interactive) (ri--open-with-gap :left))
(defun ri-open-right () (interactive) (ri--open-with-gap :right))
(defun ri-open-prev () (interactive) (ri--open-with-gap :prev))
(defun ri-open-next () (interactive) (ri--open-with-gap :next))
(defun ri-open-above ()
  (interactive)
  (let* ((ls (line-beginning-position))
         (indent (buffer-substring-no-properties ls (save-excursion (back-to-indentation) (point)))))
    (ri--with-buffer-edit (goto-char ls) (insert indent "\n") (goto-char (+ ls (length indent))))
    (ri--enter-open-insert)))
(defun ri-open-below ()
  (interactive)
  (let* ((le (line-end-position))
         (indent (buffer-substring-no-properties (line-beginning-position)
                                                  (save-excursion (back-to-indentation) (point)))))
    (ri--with-buffer-edit (goto-char le) (insert "\n" indent))
    (ri--enter-open-insert)))

(defun ri-join-lines ()
  "Join the current line to the previous line, removing its indentation."
  (interactive)
  (when-let* ((bounds (ri--selection-bounds)))
    (let* ((line-start
            (save-excursion
              (goto-char (car bounds))
              (line-beginning-position)))
           (line-end
            (save-excursion
              (goto-char (car bounds))
              (line-end-position))))
      (when (> line-start (point-min))
        (let* ((join-start (1- line-start))
               (content-start
                (save-excursion
                  (goto-char line-start)
                  (skip-chars-forward "[:space:]" line-end)
                  (point)))
               (new-text
                (buffer-substring-no-properties content-start line-end))
               (delta (- (length new-text) (- line-end join-start)))
               (active-state (and (ri--selection-active-p) ri--selection))
               (point-position (point))
               (anchor-position nil)
               (boundary-position nil)
               (map-position
                (lambda (position)
                  (cond
                   ((< position join-start) position)
                   ((>= position line-end) (+ position delta))
                   ((>= position content-start)
                    (+ join-start (- position content-start)))
                   (t join-start)))))
          (when active-state
            ;; Freeze the exact selection before the edit so line joining
            ;; cannot reinterpret it through the current semantic submode.
            (ri--preserve-selection-for-submode-switch)
            (setq point-position (point)
                  anchor-position
                  (marker-position
                   (ri--selection-state-anchor active-state))
                  boundary-position
                  (marker-position
                   (ri--selection-state-preserved-boundary active-state))))
          (ri--with-buffer-edit
            (goto-char join-start)
            (delete-region join-start line-end)
            (insert new-text))
          (when active-state
            (set-marker
             (ri--selection-state-anchor active-state)
             (funcall map-position anchor-position))
            (set-marker
             (ri--selection-state-preserved-boundary active-state)
             (funcall map-position boundary-position)))
          (goto-char (funcall map-position point-position))
          (ri--update-highlight)
          (force-mode-line-update))))))

(defun ri--replace-text (start end text) (goto-char start) (delete-region start end) (insert text))
(defun ri--swap-with-movement (movement)
  (let* ((cur (ri--selection-bounds)) (target (and cur (ri--target-unit-bounds movement cur)))
         (cs (and cur (car cur))) (ce (and cur (cdr cur)))
         (ts (and target (car target))) (te (and target (cdr target)))
         (ct (and cur (ri--bounds-text cur))) (tt (and target (ri--bounds-text target)))
         (clen (and cur (- ce cs))) (tlen (and target (- te ts))))
    (when (and cur target ct tt (or (<= te cs) (>= ts ce)))
      (ri--with-buffer-edit
        (atomic-change-group
          (if (< ts cs)
              (progn (ri--replace-text cs ce tt) (ri--replace-text ts te ct))
            (ri--replace-text ts te ct) (ri--replace-text cs ce tt))))
      (let* ((ns (if (< ts cs) ts (+ ts (- tlen clen)))) (nb (cons ns (+ ns clen))))
        (if (ri--selection-active-p)
            (let* ((st ri--selection) (edge (or (ri--selection-state-active-edge st) 'end))
                   (anchor (if (eq edge 'end) (car nb) (cdr nb))))
              (set-marker (ri--selection-state-anchor st) anchor)
              (set-marker (ri--selection-state-initial-end st) (cdr nb))
              (goto-char (ri--point-at-unit-edge nb edge)))
          (goto-char ns))
        (ri--update-highlight)))))
(defun ri-swap-up () (interactive) (ri--swap-with-movement :up))
(defun ri-swap-down () (interactive) (ri--swap-with-movement :down))
(defun ri-swap-left () (interactive) (ri--swap-with-movement :left))
(defun ri-swap-right () (interactive) (ri--swap-with-movement :right))
(defun ri-swap-prev () (interactive) (ri--swap-with-movement :prev))
(defun ri-swap-next () (interactive) (ri--swap-with-movement :next))
(defun ri-swap-first () (interactive) (ri--swap-with-movement :first))
(defun ri-swap-last () (interactive) (ri--swap-with-movement :last))

(provide 'ri-edit)
;;; ri-edit.el ends here
