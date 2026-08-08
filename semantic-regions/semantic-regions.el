;;; semantic-regions.el --- Unit-based navigation and submode system -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, editing
;;
;;; Commentary:
;;
;; Unit-based navigation with semantic submodes: LINE, LINE*, CHAR,
;; WORD, WORD+, WORD*, and SUBWORD.  Each submode defines how the
;; "current unit" is computed, and navigation commands move point
;; by those units while keeping a highlight overlay on the active unit.
;;
;; Every submode shares the `semantic-region-*' API for parsing,
;; traversing, extending, changing units, selecting, inspecting, and
;; deleting regions while retaining its unit-specific bounds.
;;
;;; Code:

(require 'cl-lib)
(require 'pcase)
(require 'subword)

;; ── Customization ────────────────────────────────────────────────────────

(defgroup semantic-regions nil
  "Unit-based navigation with semantic submodes."
  :group 'editing)

(defface sr-highlight-face
  '((t :inherit region :background "#c7e6ff" :extend nil))
  "Face used to highlight the current semantic range."
  :group 'semantic-regions)

(defcustom sr-highlight-predicate nil
  "Optional function controlling whether the current unit is highlighted.
When nil, highlighting is always enabled while `sr-mode' is active.
When non-nil, it is called with no arguments; highlighting is shown only
when it returns non-nil."
  :type '(choice (const :tag "Always" nil) function)
  :group 'semantic-regions)

(defvar-local sr-highlight-bounds-function nil
  "Optional function returning the buffer bounds to highlight.
The function is called without arguments and must return (BEG . END)
or nil.  When nil, highlight the current semantic unit.  This lets a
consumer provide selection bounds without taking ownership of overlays.")

;; ── Submode ──────────────────────────────────────────────────────────────

(defvar-local sr-submode 'line
  "Submode within semantic-regions: `line', `line-star', `char',
`word', `word-plus', `word-star', or `subword'.")

(defconst sr--submode-properties
  '((line      :line t)
    (line-star :line t)
    (char              :horizontal t)
    (word      :wordish t :horizontal t)
    (word-plus :wordish t :horizontal t)
    (word-star :wordish t :horizontal t)
    (subword   :wordish t :horizontal t))
  "Properties of every supported `sr-submode'.")

(defun sr--submode-property-p (property &optional submode)
  "Return non-nil when PROPERTY is present for SUBMODE (default `sr-submode')."
  (plist-get (alist-get (or submode sr-submode) sr--submode-properties)
             property))

(defun sr--line-submode-p (&optional submode)
  "Return non-nil when SUBMODE is line-based."
  (sr--submode-property-p :line (or submode sr-submode)))

(defun sr--wordish-submode-p (&optional submode)
  "Return non-nil when SUBMODE is word-based."
  (sr--submode-property-p :wordish (or submode sr-submode)))

(defun sr--horizontal-submode-p (&optional submode)
  "Return non-nil when SUBMODE supports horizontal navigation."
  (sr--submode-property-p :horizontal (or submode sr-submode)))

;; ── Character classes ────────────────────────────────────────────────────

(defvar sr-word-chars "[[:alnum:]_-]"
  "Regex character class for word characters in Word mode.")

(defvar sr-subword-chars "[[:alnum:]]"
  "Regex character class for meaningful characters in Subword mode.")


(defun sr--subword-bounds-at (pos)
  "Return (START . END) of the subword at POS."
  (save-excursion
    (goto-char pos)
    (let ((bounds (bounds-of-thing-at-point 'word)))
      (if bounds
          bounds
        (let ((end (progn (subword-forward 1) (point))))
          (subword-backward 1)
          (cons (point) end))))))

;; ── Shared semantic-region API ──────────────────────────────────────────

(cl-defstruct (semantic-region
               (:constructor semantic-region--create (unit buffer beg end))
               (:copier nil))
  "A well-formed semantic UNIT region in BUFFER."
  (unit nil :read-only t)
  (buffer nil :read-only t)
  (beg nil :read-only t)
  (end nil :read-only t))

(defun semantic-region--require-unit (unit)
  "Return UNIT when it is supported, otherwise signal an error."
  (unless (assq unit sr--submode-properties)
    (error "Unsupported semantic region unit: %S" unit))
  unit)

(defun semantic-region--require-live (region)
  "Return REGION when it is a semantic region in a live buffer."
  (unless (semantic-region-p region)
    (signal 'wrong-type-argument (list 'semantic-region-p region)))
  (unless (buffer-live-p (semantic-region-buffer region))
    (error "Semantic region buffer is no longer live"))
  region)

(defun semantic-region--build (unit buffer beg end)
  "Build a UNIT region in BUFFER spanning BEG through END."
  (semantic-region--require-unit unit)
  (unless (buffer-live-p buffer)
    (error "Cannot build a semantic region in a dead buffer"))
  (with-current-buffer buffer
    (setq beg (if (markerp beg) (marker-position beg) beg)
          end (if (markerp end) (marker-position end) end))
    (unless (and (integerp beg)
                 (integerp end)
                 (<= (point-min) beg end (point-max)))
      (error "Invalid semantic region bounds: %S through %S" beg end))
    (semantic-region--create unit buffer beg end)))

(defun semantic-region--line-bounds-at (pos)
  "Return trimmed line bounds at POS in the current buffer."
  (save-excursion
    (goto-char pos)
    (let ((bol (line-beginning-position))
          (eol (line-end-position)))
      (goto-char bol)
      (skip-chars-forward " \t" eol)
      (let ((beg (point)))
        (goto-char eol)
        (skip-chars-backward " \t" bol)
        (let ((end (point)))
          (if (> end beg)
              (cons beg end)
            (cons beg beg)))))))

(defun semantic-region--line-star-bounds-at (pos)
  "Return full line bounds at POS in the current buffer."
  (save-excursion
    (goto-char pos)
    (cons (line-beginning-position) (line-end-position))))

(defun semantic-region--char-bounds-at (pos)
  "Return single-character bounds at POS in the current buffer."
  (save-excursion
    (goto-char pos)
    (cons (point) (min (1+ (point)) (point-max)))))

(defun semantic-region--word-bounds-at (pos)
  "Return WORD or WORD+ bounds at POS in the current buffer."
  (save-excursion
    (goto-char pos)
    (let ((char (char-after)))
      (cond
       ((eobp) nil)
       ((and char (string-match-p sr-word-chars (string char)))
        (skip-chars-backward "[:alnum:]_-")
        (let ((beg (point)))
          (skip-chars-forward "[:alnum:]_-")
          (cons beg (point))))
       ((memq char '(?\s ?\t))
        (skip-chars-backward " \t")
        (let ((beg (point)))
          (skip-chars-forward " \t")
          (cons beg (point))))
       ((eq char ?\n)
        (cons (point) (1+ (point))))
       (t
        (cons (point) (1+ (point))))))))

(defun semantic-region--word-star-bounds-at (pos)
  "Return WORD* bounds at POS in the current buffer."
  (save-excursion
    (goto-char pos)
    (let ((char (char-after)))
      (cond
       ((eobp) nil)
       ((eq char ?\n)
        (cons (point) (1+ (point))))
       ((memq char '(?\s ?\t))
        (skip-chars-backward " \t")
        (let ((beg (point)))
          (skip-chars-forward " \t")
          (cons beg (point))))
       (t
        (skip-chars-backward "^ \t\n")
        (let ((beg (point)))
          (skip-chars-forward "^ \t\n")
          (cons beg (point))))))))

(defun semantic-region--bounds-at (unit pos)
  "Return bounds for semantic UNIT at POS in the current buffer."
  (semantic-region--require-unit unit)
  (pcase unit
    ('line (semantic-region--line-bounds-at pos))
    ('line-star (semantic-region--line-star-bounds-at pos))
    ('char (semantic-region--char-bounds-at pos))
    ((or 'word 'word-plus) (semantic-region--word-bounds-at pos))
    ('word-star (semantic-region--word-star-bounds-at pos))
    ('subword (sr--subword-bounds-at pos))))

(defun semantic-region-parse-at (unit pos)
  "Return a semantic UNIT region at POS, or nil when no unit exists."
  (let ((buffer (current-buffer)))
    (when-let* ((bounds (semantic-region--bounds-at unit pos)))
      (semantic-region--build unit buffer (car bounds) (cdr bounds)))))

(defun semantic-region--next-position (region)
  "Return a probe position after REGION, or nil at buffer end."
  (pcase (semantic-region-unit region)
    ((or 'line 'line-star)
     (save-excursion
       (goto-char (semantic-region-end region))
       (forward-line 1)
       (when (< (point) (point-max))
         (point))))
    (_
     (when (< (semantic-region-end region) (point-max))
       (semantic-region-end region)))))

(defun semantic-region--prev-position (region)
  "Return a probe position before REGION, or nil at buffer start."
  (pcase (semantic-region-unit region)
    ((or 'line 'line-star)
     (save-excursion
       (goto-char (semantic-region-beg region))
       (when (> (line-beginning-position) (point-min))
         (forward-line -1)
         (point))))
    (_
     (when (> (semantic-region-beg region) (point-min))
       (1- (semantic-region-beg region))))))

(defun semantic-region--whitespace-p (region)
  "Return non-nil when REGION contains only whitespace."
  (with-current-buffer (semantic-region-buffer region)
    (save-excursion
      (goto-char (semantic-region-beg region))
      (skip-chars-forward " \t\n" (semantic-region-end region))
      (= (point) (semantic-region-end region)))))

(defun semantic-region--separator-p (region)
  "Return non-nil when REGION is skipped by its unit's traversal."
  (pcase (semantic-region-unit region)
    ('word
     (or (semantic-region--whitespace-p region)
         (and (= (1+ (semantic-region-beg region))
                 (semantic-region-end region))
              (with-current-buffer (semantic-region-buffer region)
                (let ((char (char-after (semantic-region-beg region))))
                  (and char
                       (not (string-match-p
                             sr-word-chars
                             (string char)))))))))
    ((or 'word-plus 'word-star 'subword)
     (semantic-region--whitespace-p region))
    (_ nil)))

(defun semantic-region-next (region)
  "Return the next region for REGION's unit, or nil at buffer end.
WORD skips whitespace and symbols.  WORD+, WORD*, and SUBWORD skip
whitespace.  LINE, LINE*, and CHAR traverse adjacent units."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (let ((unit (semantic-region-unit region))
          (lower-bound (semantic-region-end region))
          (probe (semantic-region--next-position region))
          next)
      (while (and probe (not next))
        (let ((candidate (semantic-region-parse-at unit probe)))
          (cond
           ((or (null candidate)
                (< (semantic-region-beg candidate) lower-bound))
            (setq probe (when (< probe (point-max)) (1+ probe))))
           ((semantic-region--separator-p candidate)
            (let ((next-probe (semantic-region--next-position candidate)))
              (setq probe
                    (if (and next-probe (> next-probe probe))
                        next-probe
                      (when (< probe (point-max)) (1+ probe))))))
           (t
            (setq next candidate)))))
      next)))

(defun semantic-region-prev (region)
  "Return the previous region for REGION's unit, or nil at buffer start.
WORD skips whitespace and symbols.  WORD+, WORD*, and SUBWORD skip
whitespace.  LINE, LINE*, and CHAR traverse adjacent units."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (let ((unit (semantic-region-unit region))
          (upper-bound (semantic-region-beg region))
          (probe (semantic-region--prev-position region))
          prev)
      (while (and probe (not prev))
        (let ((candidate (semantic-region-parse-at unit probe)))
          (cond
           ((or (null candidate)
                (> (semantic-region-end candidate) upper-bound))
            (setq probe (when (> probe (point-min)) (1- probe))))
           ((semantic-region--separator-p candidate)
            (let ((prev-probe (semantic-region--prev-position candidate)))
              (setq probe
                    (if (and prev-probe (< prev-probe probe))
                        prev-probe
                      (when (> probe (point-min)) (1- probe))))))
           (t
            (setq prev candidate)))))
      prev)))

(defun semantic-region-extend-next (region)
  "Return REGION extended through its next unit.
Return REGION unchanged when it has no next unit."
  (if-let* ((next (semantic-region-next region)))
      (semantic-region--build
       (semantic-region-unit region)
       (semantic-region-buffer region)
       (semantic-region-beg region)
       (semantic-region-end next))
    region))

(defun semantic-region-extend-prev (region)
  "Return REGION extended through its previous unit.
Return REGION unchanged when it has no previous unit."
  (if-let* ((prev (semantic-region-prev region)))
      (semantic-region--build
       (semantic-region-unit region)
       (semantic-region-buffer region)
       (semantic-region-beg prev)
       (semantic-region-end region))
    region))

(defun semantic-region-change-unit (region unit)
  "Reparse REGION's first position as UNIT."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (semantic-region-parse-at unit (semantic-region-beg region))))

(defun semantic-region-select (region)
  "Select REGION in its buffer and return REGION."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (goto-char (semantic-region-end region))
    (push-mark (semantic-region-beg region) nil t))
  region)

(defun semantic-region-string (region)
  "Return REGION's text without text properties."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (buffer-substring-no-properties
     (semantic-region-beg region)
     (semantic-region-end region))))

(defun semantic-region-length (region)
  "Return REGION's length in characters."
  (semantic-region--require-live region)
  (- (semantic-region-end region) (semantic-region-beg region)))

(defun semantic-region-empty-p (region)
  "Return non-nil when REGION has zero width."
  (zerop (semantic-region-length region)))

(defun semantic-region-delete (region)
  "Delete REGION's text from its buffer."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (delete-region (semantic-region-beg region) (semantic-region-end region))))

;; ── Unit bounds ──────────────────────────────────────────────────────────


(defun sr--unit-bounds-at (pos submode)
  "Return (START . END) of the unit at POS under SUBMODE."
  (semantic-region--bounds-at submode pos))

(defun sr--get-current-unit-bounds ()
  "Return (START . END) of the current unit based on `sr-submode' and point."
  (sr--unit-bounds-at (point) sr-submode))

(defun sr--point-at-unit-edge (bounds edge)
  "Return the START or END of BOUNDS based on EDGE."
  (pcase edge
    ('start (car bounds))
    ('end (cdr bounds))
    (_ (car bounds))))

;; ── Highlight ────────────────────────────────────────────────────────────

(defvar-local sr--highlight-overlays nil
  "Overlays rendering the current semantic highlight.")

(defun sr--render-highlight-bounds (bounds)
  "Render BOUNDS without painting newline glyphs inside a text range.
A range containing only one newline remains visible so CHAR mode can
still represent that unit.  Reuse existing overlays where possible."
  (let ((available sr--highlight-overlays)
        used)
    (cl-labels
        ((render-segment
          (start end)
          (when (< start end)
            (let ((overlay (pop available)))
              (unless overlay
                (setq overlay (make-overlay start end))
                (overlay-put overlay 'face 'sr-highlight-face)
                (overlay-put overlay 'priority 100))
              (move-overlay overlay start end)
              (push overlay used)))))
      (let ((start (car bounds))
            (end (cdr bounds)))
        (if (and (= (- end start) 1)
                 (eq (char-after start) ?\n))
            (render-segment start end)
          (save-excursion
            (goto-char start)
            (while (< start end)
              (let ((line-end (min end (line-end-position))))
                (render-segment start line-end)
                (if (= line-end end)
                    (setq start end)
                  (setq start (1+ line-end))
                  (goto-char start))))))))
    (mapc #'delete-overlay available)
    (setq sr--highlight-overlays (nreverse used))))

(defun sr--update-highlight ()
  "Render the requested bounds through the semantic highlight owner.
Remove the highlight when `sr-highlight-predicate' disallows it or the
configured bounds source returns nil."
  (if (and sr-highlight-predicate
           (not (funcall sr-highlight-predicate)))
      (sr--remove-highlight)
    (let ((bounds
           (if sr-highlight-bounds-function
               (funcall sr-highlight-bounds-function)
             (sr--get-current-unit-bounds))))
      (if bounds
          (sr--render-highlight-bounds bounds)
        (sr--remove-highlight)))))

(defun sr--remove-highlight ()
  "Remove all semantic highlight overlays."
  (mapc #'delete-overlay sr--highlight-overlays)
  (setq sr--highlight-overlays nil))

;; ── Snapping ─────────────────────────────────────────────────────────────

(defun sr--snap-to-unit-start ()
  "Move point to the start of the current unit."
  (let ((bounds (sr--get-current-unit-bounds)))
    (when bounds
      (goto-char (car bounds)))))

;; ── Low-level word movement ──────────────────────────────────────────────

(defun sr-forward-word-all ()
  "Move forward by one word/symbol unit in Word mode."
  (interactive)
  (cond
   ((looking-at sr-word-chars)
    (skip-chars-forward "[:alnum:]_-"))
   ((memq (char-after) '(?\s ?\t))
    (skip-chars-forward " \t"))
   ((eq (char-after) ?\n)
    (forward-char 1))
   (t
    (forward-char 1)))
  (skip-chars-forward " \t\n"))

(defun sr-backward-word-all ()
  "Move backward by one word/symbol unit in Word mode."
  (interactive)
  (skip-chars-backward " \t\n")
  (when (not (bobp))
    (backward-char 1)
    (if (looking-at sr-word-chars)
        (skip-chars-backward "[:alnum:]_-")
      nil)))

(defun sr-forward-word-non-symbol ()
  "Move forward to the next non-symbol word (skip punctuation)."
  (interactive)
  (when (looking-at sr-word-chars)
    (skip-chars-forward "[:alnum:]_-"))
  (let ((found nil))
    (while (not found)
      (skip-chars-forward " \t\n")
      (cond
       ((eobp)
        (setq found t))
       ((looking-at sr-word-chars)
        (setq found t))
       (t
        (forward-char 1))))))

(defun sr-backward-word-non-symbol ()
  "Move backward to the previous non-symbol word (skip punctuation)."
  (interactive)
  (let ((found nil))
    (while (not found)
      (skip-chars-backward " \t\n")
      (cond
       ((bobp)
        (setq found t))
       ((save-excursion
          (backward-char 1)
          (looking-at sr-word-chars))
        (skip-chars-backward "[:alnum:]_-")
        (setq found t))
       (t
        (backward-char 1))))))

(defun sr-forward-bigword-all ()
  "Move forward by one bigword unit in WORD* mode."
  (interactive)
  (unless (eobp)
    (cond
     ((memq (char-after) '(?\s ?\t))
      (skip-chars-forward " \t"))
     ((eq (char-after) ?\n)
      (forward-char 1))
     (t
      (skip-chars-forward "^ \t\n")))
    (skip-chars-forward " \t\n")))

(defun sr-backward-bigword-all ()
  "Move backward by one bigword unit in WORD* mode."
  (interactive)
  (unless (bobp)
    (skip-chars-backward " \t\n")
    (when (not (bobp))
      (skip-chars-backward "^ \t\n"))))

(defun sr-forward-bigword-non-whitespace ()
  "Move forward to the next non-whitespace bigword unit."
  (interactive)
  (unless (eobp)
    (cond
     ((memq (char-after) '(?\s ?\t))
      (skip-chars-forward " \t"))
     ((eq (char-after) ?\n)
      (forward-char 1))
     (t
      (skip-chars-forward "^ \t\n")))))

(defun sr-backward-bigword-non-whitespace ()
  "Move backward to the previous non-whitespace bigword unit."
  (interactive)
  (unless (bobp)
    (backward-char 1)
    (if (memq (char-after) '(?\s ?\t ?\n))
        (progn
          (forward-char 1)
          (skip-chars-backward " \t\n"))
      (when (string-match-p sr-word-chars (string (char-after)))
        (skip-chars-backward "[:alnum:]_-"))
      (backward-char 1))))

(defun sr-forward-subword-all ()
  "Move forward by one subword unit."
  (interactive)
  (unless (eobp)
    (let ((bounds (sr--subword-bounds-at (point))))
      (if (and bounds (> (cdr bounds) (point)))
          (goto-char (cdr bounds))
        (subword-forward 1)
        (let ((bounds (sr--subword-bounds-at (point))))
          (when bounds
            (goto-char (car bounds))))))))

(defun sr-backward-subword-all ()
  "Move backward by one subword unit."
  (interactive)
  (unless (bobp)
    (let ((bounds (sr--subword-bounds-at (1- (point)))))
      (if (and bounds (< (car bounds) (point)))
          (goto-char (car bounds))
        (subword-backward 1)))))

(defun sr-forward-subword-non-symbol ()
  "Move forward by one non-symbol subword unit."
  (interactive)
  (unless (eobp)
    (let ((char (char-after)))
      (cond
       ((and char (string-match-p sr-subword-chars (string char)))
        (subword-forward 1)
        (skip-chars-forward " \t\n"))
       ((memq char '(?\s ?\t))
        (skip-chars-forward " \t"))
       ((eq char ?\n)
        (forward-char 1))
       (t
        (forward-char 1))))))

(defun sr-backward-subword-non-symbol ()
  "Move backward by one non-symbol subword unit."
  (interactive)
  (unless (bobp)
    (skip-chars-backward " \t\n")
    (when (not (bobp))
      (backward-char 1)
      (if (looking-at sr-subword-chars)
          (subword-backward 1)
        (backward-char 1)))))

;; ── Navigation commands ──────────────────────────────────────────────────

(defun sr-nav-up ()
  "Move point up by line, skipping blank lines in LINE and SUBWORD modes."
  (interactive)
  (pcase sr-submode
    ((or 'line 'subword)
     (forward-line -1)
     (while (and (looking-at-p "^[ \t]*$")
                 (not (bobp)))
       (forward-line -1)))
    (_
     (forward-line -1)))
  (sr--snap-to-unit-start)
  (sr--update-highlight))

(defun sr-nav-down ()
  "Move point down by line."
  (interactive)
  (pcase sr-submode
    ('line
     (forward-line 1)
     (while (and (looking-at-p "^[ \t]*$")
                 (not (eobp)))
       (forward-line 1))
     (sr--snap-to-unit-start))
    (_
     (forward-line 1)
     (sr--snap-to-unit-start)))
  (sr--update-highlight))

(defun sr--nav-prev-blank-line ()
  "Move to the previous blank line and skip leading whitespace."
  (let ((found nil))
    (while (and (not (bobp))
                (not found))
      (forward-line -1)
      (when (looking-at-p "^[ \t]*$")
        (setq found t)))
    (if found
        (skip-chars-forward " \t")
      (goto-char (point-min)))))

(defun sr--nav-prev-empty-line ()
  "Move to the previous empty line."
  (let ((found nil))
    (while (and (not (bobp))
                (not found))
      (forward-line -1)
      (when (looking-at-p "^[ \t]*$")
        (setq found t)))
    (unless found
      (goto-char (point-min)))))

(defun sr--nav-next-blank-line ()
  "Move to the next blank line and skip leading whitespace."
  (let ((found nil))
    (while (and (not (eobp))
                (not found))
      (forward-line 1)
      (when (looking-at-p "^[ \t]*$")
        (setq found t)))
    (if found
        (skip-chars-forward " \t")
      (goto-char (point-max)))))

(defun sr--nav-next-empty-line ()
  "Move to the next empty line."
  (let ((found nil))
    (while (and (not (eobp))
                (not found))
      (forward-line 1)
      (when (looking-at-p "^[ \t]*$")
        (setq found t)))
    (unless found
      (goto-char (point-max)))))

(defun sr-nav-prev ()
  "Move to previous significant item."
  (interactive)
  (pcase sr-submode
    ('word
     (sr-backward-word-all))
    ('word-plus
     (sr-backward-word-non-symbol))
    ('word-star
     (sr-backward-bigword-non-whitespace))
    ('subword
     (sr-backward-subword-non-symbol))
    ('line
     (sr--nav-prev-blank-line))
    ('line-star
     (sr--nav-prev-empty-line))
    (_
     (message "Prev/Next navigation (u/o) is for WORD, WORD+, WORD*, Subword, LINE, and LINE* modes.")))
  (sr--update-highlight))

(defun sr-nav-next ()
  "Move to next significant item."
  (interactive)
  (pcase sr-submode
    ('word
     (sr-forward-word-all))
    ('word-plus
     (sr-forward-word-non-symbol))
    ('word-star
     (sr-forward-bigword-non-whitespace))
    ('subword
     (sr-forward-subword-non-symbol))
    ('line
     (sr--nav-next-blank-line))
    ('line-star
     (sr--nav-next-empty-line))
    (_
     (message "Prev/Next navigation (u/o) is for WORD, WORD+, WORD*, Subword, LINE, and LINE* modes.")))
  (sr--update-highlight))

(defun sr-nav-left ()
  "Move point left/backward by one unit."
  (interactive)
  (pcase sr-submode
    ('char (backward-char))
    ('word (sr-backward-word-non-symbol))
    ('word-plus (sr-backward-word-all))
    ('word-star (sr-backward-bigword-all))
    ('subword (sr-backward-subword-all))
    (_ (message "Left/Right navigation (j/l) requires Character, Word, WORD+, WORD*, or Subword mode.")))
  (sr--update-highlight))

(defun sr-nav-right ()
  "Move point right/forward by one unit."
  (interactive)
  (pcase sr-submode
    ('char (forward-char))
    ('word (sr-forward-word-non-symbol))
    ('word-plus (sr-forward-word-all))
    ('word-star (sr-forward-bigword-all))
    ('subword (sr-forward-subword-all))
    (_ (message "Left/Right navigation (j/l) requires Character, Word, WORD+, WORD*, or Subword mode.")))
  (sr--update-highlight))

;; ── First / Last ─────────────────────────────────────────────────────────

(defun sr--goto-first-word ()
  "Move to the first word unit in the buffer."
  (goto-char (point-min))
  (skip-chars-forward " \t\n")
  (unless (eobp)
    (sr--snap-to-unit-start)
    t))

(defun sr--goto-last-word ()
  "Move to the last word unit in the buffer."
  (goto-char (point-max))
  (skip-chars-backward " \t\n")
  (unless (bobp)
    (sr--snap-to-unit-start)
    t))

(defun sr--goto-first-bigword ()
  "Move to the first bigword unit in the buffer."
  (goto-char (point-min))
  (skip-chars-forward " \t\n")
  (unless (eobp)
    t))

(defun sr--goto-last-bigword ()
  "Move to the last bigword unit in the buffer."
  (goto-char (point-max))
  (skip-chars-backward " \t\n")
  (unless (bobp)
    t))

(defun sr-nav-first ()
  "Move to the first item allowed by the current submode."
  (interactive)
  (unless (eq sr-submode 'subword)
    (pcase sr-submode
      ('char
       (goto-char (line-beginning-position)))
      ((or 'line 'line-star)
       (goto-char (point-min))
       (sr--snap-to-unit-start))
      ((or 'word 'word-plus)
       (when (sr--goto-first-word)
         (sr--snap-to-unit-start)))
      ('word-star
       (when (sr--goto-first-bigword)
         (sr--snap-to-unit-start))))
    (sr--update-highlight)))

(defun sr-nav-last ()
  "Move to the last item allowed by the current submode."
  (interactive)
  (unless (eq sr-submode 'subword)
    (pcase sr-submode
      ('char
       (goto-char (line-end-position)))
      ((or 'line 'line-star)
       (goto-char (point-max))
       (sr--snap-to-unit-start))
      ((or 'word 'word-plus)
       (when (sr--goto-last-word)
         (sr--snap-to-unit-start)))
      ('word-star
       (when (sr--goto-last-bigword)
         (sr--snap-to-unit-start))))
    (sr--update-highlight)))

;; ── Submode setters ──────────────────────────────────────────────────────

(defun sr--set-submode (submode human-name)
  "Set `sr-submode' to SUBMODE and show HUMAN-NAME in the echo area."
  (setq sr-submode submode)
  (sr--update-highlight)
  (message "semantic-regions: %s" human-name))

(defun sr-set-line-mode ()
  "Switch to LINE submode."
  (interactive)
  (sr--set-submode 'line "Line Mode"))

(defun sr-set-line-star-mode ()
  "Switch to LINE* submode."
  (interactive)
  (sr--set-submode 'line-star "LINE* Mode"))

(defun sr-set-character-mode ()
  "Switch to CHAR submode."
  (interactive)
  (sr--set-submode 'char "Character Mode"))

(defun sr-set-word-mode ()
  "Switch to WORD submode."
  (interactive)
  (sr--set-submode 'word "Word Mode"))

(defun sr-set-word-star-mode ()
  "Switch to WORD* submode."
  (interactive)
  (sr--set-submode 'word-star "WORD* Mode"))

(defun sr-set-subword-mode ()
  "Switch to SUBWORD submode."
  (interactive)
  (sr--set-submode 'subword "Subword Mode"))

(defun sr-set-word-plus-mode ()
  "Switch to WORD+ submode."
  (interactive)
  (sr--set-submode 'word-plus "WORD+ Mode"))

;; ── Minor mode ───────────────────────────────────────────────────────────

;; ── Deferred highlight after file open ──────────────────────────────────

(defun sr--on-find-file ()
  "Call `sr--update-highlight' when `sr-mode' is enabled.
Intended for `find-file-hook'."
  (when sr-mode
    (sr--update-highlight)))

;;;###autoload
(define-minor-mode sr-mode
  "Enable semantic-regions highlight overlay in the current buffer.
The overlay tracks the current unit as point moves."
  :lighter nil
  :group 'semantic-regions
  (if sr-mode
      (progn
        (add-hook 'post-command-hook #'sr--update-highlight nil t)
        (add-hook 'find-file-hook #'sr--on-find-file)
        (sr--update-highlight))
    (sr--remove-highlight)
    (remove-hook 'post-command-hook #'sr--update-highlight t)
    (remove-hook 'find-file-hook #'sr--on-find-file)))

(provide 'semantic-regions)
;;; semantic-regions.el ends here
