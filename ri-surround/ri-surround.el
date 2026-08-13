;;; ri-surround.el --- Ki-style surround operations for ri -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;;; Commentary:
;; Ki-style enclosure operations used by `ri-mode'.
;;; Code:

(require 'cl-lib)
(require 'ri-extend)
(require 'ri-duplicate)

(defconst ri-surround-enclosures
  '((paren    :key "m" :open "(" :close ")" :label "( )")
    (bracket  :key "," :open "[" :close "]" :label "[ ]")
    (brace    :key "." :open "{" :close "}" :label "{ }")
    (angle    :key "/" :open "<" :close ">" :label "< >")
    (single   :key "j" :open "'" :close "'" :label "' '")
    (double   :key "k" :open "\"" :close "\"" :label "\" \"")
    (backtick :key "l" :open "`" :close "`" :label "` `"))
  "Enclosures and spatial keys matching Ki Editor.")

(defun ri-surround--spec (kind)
  "Return enclosure specification for KIND."
  (or (assq kind ri-surround-enclosures)
      (error "Unknown surround kind: %S" kind)))

(defun ri-surround--open (kind)
  "Return opening delimiter for KIND."
  (plist-get (cdr (ri-surround--spec kind)) :open))

(defun ri-surround--close (kind)
  "Return closing delimiter for KIND."
  (plist-get (cdr (ri-surround--spec kind)) :close))

(defun ri-surround--escaped-p (position)
  "Return non-nil when character at POSITION is backslash-escaped."
  (let ((slashes 0)
        (pos (1- position)))
    (while (and (>= pos (point-min))
                (eq (char-after pos) ?\\))
      (setq slashes (1+ slashes)
            pos (1- pos)))
    (= (% slashes 2) 1)))

(defun ri-surround--asymmetric-pairs (open close)
  "Return all balanced OPEN/CLOSE pairs in the accessible buffer."
  (let ((open-char (string-to-char open))
        (close-char (string-to-char close))
        stack pairs)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (regexp-opt (list open close)) nil t)
        (let ((pos (match-beginning 0))
              (char (char-after (match-beginning 0))))
          (cond
           ((eq char open-char)
            (push pos stack))
           ((and (eq char close-char) stack)
            (push (cons (pop stack) pos) pairs))))))
    pairs))

(defun ri-surround--symmetric-pairs (delimiter)
  "Return simple unescaped pairs for symmetric DELIMITER."
  (let ((char (string-to-char delimiter))
        open pairs)
    (save-excursion
      (goto-char (point-min))
      (while (search-forward delimiter nil t)
        (let ((pos (1- (point))))
          (when (and (eq (char-after pos) char)
                     (not (ri-surround--escaped-p pos)))
            (if open
                (progn
                  (push (cons open pos) pairs)
                  (setq open nil))
              (setq open pos))))))
    pairs))

(defun ri-surround--find-pair (kind &optional bounds)
  "Return the smallest KIND pair surrounding BOUNDS or point.
The returned cons contains delimiter character positions."
  (let* ((open (ri-surround--open kind))
         (close (ri-surround--close kind))
         (target (or bounds (cons (point) (point))))
         (start (car target))
         (end (cdr target))
         (pairs (if (equal open close)
                    (ri-surround--symmetric-pairs open)
                  (ri-surround--asymmetric-pairs open close))))
    (car
     (sort
      (cl-remove-if-not
       (lambda (pair)
         (and (<= (car pair) start)
              (>= (cdr pair) (max start (1- end)))))
       pairs)
      (lambda (a b)
        (< (- (cdr a) (car a))
           (- (cdr b) (car b))))))))

(defun ri-surround--target-bounds ()
  "Return current RI selection or semantic-unit bounds."
  (or (ri--selection-bounds)
      (user-error "No RI selection or semantic unit at point")))

(defun ri-surround--set-exact-selection (start end)
  "Create an exact RI Extend selection from START to END."
  (ri--exit-extend)
  (let ((state (ri--selection-state-create
                :anchor (copy-marker start)
                :initial-end nil
                :active-edge 'end
                :undo-stack nil)))
    (setq ri--selection state)
    (ri--set-preserved-boundary state end)
    (goto-char (ri--point-at-unit-edge (cons start end) 'end))
    (ri--update-highlight)
    (force-mode-line-update)))

(defun ri-surround-add (kind)
  "Surround the current RI selection/unit with enclosure KIND."
  (interactive)
  (let* ((bounds (ri-surround--target-bounds))
         (start (car bounds))
         (end (cdr bounds))
         (open (ri-surround--open kind))
         (close (ri-surround--close kind)))
    (ri--with-buffer-edit
      (atomic-change-group
        (goto-char end)
        (insert close)
        (goto-char start)
        (insert open)
        (goto-char (+ start (length open)))))
    (ri--finish-edit-command)))

(defun ri-surround-add-tag (tag)
  "Surround the current RI selection/unit with HTML/XML TAG."
  (interactive "sTag: ")
  (unless (string-match-p "\\`[[:alnum:]_:-]+\\'" tag)
    (user-error "Invalid tag name: %s" tag))
  (let* ((bounds (ri-surround--target-bounds))
         (start (car bounds))
         (end (cdr bounds))
         (open (format "<%s>" tag))
         (close (format "</%s>" tag)))
    (ri--with-buffer-edit
      (atomic-change-group
        (goto-char end)
        (insert close)
        (goto-char start)
        (insert open)
        (goto-char (+ start (length open)))))
    (ri--finish-edit-command)))

(defun ri-surround-delete (kind)
  "Delete the nearest surrounding enclosure KIND."
  (interactive)
  (let* ((bounds (ri-surround--target-bounds))
         (pair (ri-surround--find-pair kind bounds)))
    (unless pair
      (user-error "No surrounding %s enclosure"
                  (plist-get (cdr (ri-surround--spec kind)) :label)))
    (let* ((open-pos (car pair))
           (close-pos (cdr pair))
           (open (ri-surround--open kind))
           (close (ri-surround--close kind)))
      (ri--with-buffer-edit
        (atomic-change-group
          (goto-char close-pos)
          (delete-region close-pos (+ close-pos (length close)))
          (goto-char open-pos)
          (delete-region open-pos (+ open-pos (length open)))
          (goto-char open-pos)))
      (ri--finish-edit-command))))

(defun ri-surround-change (from to)
  "Change nearest surrounding enclosure FROM to TO."
  (interactive)
  (let* ((bounds (ri-surround--target-bounds))
         (pair (ri-surround--find-pair from bounds)))
    (unless pair
      (user-error "No surrounding %s enclosure"
                  (plist-get (cdr (ri-surround--spec from)) :label)))
    (let* ((open-pos (car pair))
           (close-pos (cdr pair))
           (old-open (ri-surround--open from))
           (old-close (ri-surround--close from))
           (new-open (ri-surround--open to))
           (new-close (ri-surround--close to)))
      (ri--with-buffer-edit
        (atomic-change-group
          ;; Replace the right delimiter first so the left replacement cannot
          ;; invalidate its position.
          (goto-char close-pos)
          (delete-region close-pos (+ close-pos (length old-close)))
          (insert new-close)
          (goto-char open-pos)
          (delete-region open-pos (+ open-pos (length old-open)))
          (insert new-open)
          (goto-char (+ open-pos (length new-open)))))
      (ri--finish-edit-command))))

(defun ri-surround-select-inside (kind)
  "Enter Extend selecting inside the nearest enclosure KIND."
  (interactive)
  (let* ((bounds (ri-surround--target-bounds))
         (pair (ri-surround--find-pair kind bounds)))
    (unless pair
      (user-error "No surrounding enclosure"))
    (ri-surround--set-exact-selection
     (+ (car pair) (length (ri-surround--open kind)))
     (cdr pair))))

(defun ri-surround-select-around (kind)
  "Enter Extend selecting around the nearest enclosure KIND."
  (interactive)
  (let* ((bounds (ri-surround--target-bounds))
         (pair (ri-surround--find-pair kind bounds)))
    (unless pair
      (user-error "No surrounding enclosure"))
    (ri-surround--set-exact-selection
     (car pair)
     (+ (cdr pair) (length (ri-surround--close kind))))))

(provide 'ri-surround)
;;; ri-surround.el ends here
