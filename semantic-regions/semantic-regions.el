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
;; LINE and CHAR also share the `semantic-region-*' API for parsing,
;; traversing, extending, changing units, selecting, inspecting, and
;; deleting regions.  Other submodes keep their specialized behavior.
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
  "Face used to highlight the current unit."
  :group 'semantic-regions)

(defcustom sr-highlight-predicate nil
  "Optional function controlling whether the current unit is highlighted.
When nil, highlighting is always enabled while `sr-mode' is active.
When non-nil, it is called with no arguments; highlighting is shown only
when it returns non-nil."
  :type '(choice (const :tag "Always" nil) function)
  :group 'semantic-regions)

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


;; ── Shared LINE/CHAR region API ─────────────────────────────────────────

(cl-defstruct (semantic-region
               (:constructor semantic-region--create (unit buffer beg end))
               (:copier nil))
  "A well-formed LINE or CHAR region in BUFFER."
  (unit nil :read-only t)
  (buffer nil :read-only t)
  (beg nil :read-only t)
  (end nil :read-only t))

(defun semantic-region--require-unit (unit)
  "Return UNIT when it is supported, otherwise signal an error."
  (unless (memq unit '(line char))
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

(defun semantic-region--char-bounds-at (pos)
  "Return single-character bounds at POS in the current buffer."
  (save-excursion
    (goto-char pos)
    (cons (point) (min (1+ (point)) (point-max)))))

(defun semantic-region--bounds-at (unit pos)
  "Return bounds for LINE or CHAR UNIT at POS in the current buffer."
  (semantic-region--require-unit unit)
  (pcase unit
    ('line (semantic-region--line-bounds-at pos))
    ('char (semantic-region--char-bounds-at pos))))

(defun semantic-region-parse-at (unit pos)
  "Return a LINE or CHAR semantic region at POS in the current buffer."
  (let ((buffer (current-buffer))
        (bounds (semantic-region--bounds-at unit pos)))
    (semantic-region--build unit buffer (car bounds) (cdr bounds))))

(defun semantic-region--next-position (region)
  "Return the position of the unit after REGION, or nil at buffer end."
  (pcase (semantic-region-unit region)
    ('char
     (when (< (semantic-region-end region) (point-max))
       (semantic-region-end region)))
    ('line
     (save-excursion
       (goto-char (semantic-region-end region))
       (forward-line 1)
       (when (< (point) (point-max))
         (point))))))

(defun semantic-region--prev-position (region)
  "Return the position of the unit before REGION, or nil at buffer start."
  (pcase (semantic-region-unit region)
    ('char
     (when (> (semantic-region-beg region) (point-min))
       (1- (semantic-region-beg region))))
    ('line
     (save-excursion
       (goto-char (semantic-region-beg region))
       (when (> (line-beginning-position) (point-min))
         (forward-line -1)
         (point))))))

(defun semantic-region-next (region)
  "Return the unit after REGION, or nil when REGION is the last unit."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (when-let* ((pos (semantic-region--next-position region)))
      (semantic-region-parse-at (semantic-region-unit region) pos))))

(defun semantic-region-prev (region)
  "Return the unit before REGION, or nil when REGION is the first unit."
  (semantic-region--require-live region)
  (with-current-buffer (semantic-region-buffer region)
    (when-let* ((pos (semantic-region--prev-position region)))
      (semantic-region-parse-at (semantic-region-unit region) pos))))

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
  "Reparse REGION's first position as LINE or CHAR UNIT."
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

(defun sr--unit-bounds-at (pos submode)
  "Return (START . END) of the unit at POS under SUBMODE."
  (save-excursion
    (goto-char pos)
    (pcase submode
      ((or 'line 'char)
       (semantic-region--bounds-at submode pos))
      ('line-star
       (cons (line-beginning-position) (line-end-position)))
      ((or 'word 'word-plus)
       (save-excursion
         (let ((char (char-after)))
           (cond
            ((eobp) nil)
            ((and char (string-match-p sr-word-chars (string char)))
             (skip-chars-backward "[:alnum:]_-")
             (let ((s (point)))
               (skip-chars-forward "[:alnum:]_-")
               (cons s (point))))
            ((memq char '(?\s ?\t))
             (skip-chars-backward " \t")
             (let ((s (point)))
               (skip-chars-forward " \t")
               (cons s (point))))
            ((eq char ?\n)
             (cons (point) (1+ (point))))
            (t
             (cons (point) (1+ (point))))))))
      ('word-star
       (save-excursion
         (let ((char (char-after)))
           (cond
            ((eobp) nil)
            ((eq char ?\n)
             (cons (point) (1+ (point))))
            ((memq char '(?\s ?\t))
             (skip-chars-backward " \t")
             (let ((s (point)))
               (skip-chars-forward " \t")
               (cons s (point))))
            (t
             (skip-chars-backward "^ \t\n")
             (let ((s (point)))
               (skip-chars-forward "^ \t\n")
               (cons s (point))))))))
      ('subword
       (sr--subword-bounds-at pos)))))

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

(defvar-local sr--highlight-overlay nil
  "Overlay used for highlighting the current unit.")

(defun sr--update-highlight ()
  "Update the highlight overlay to the unit at point.
Remove it when `sr-highlight-predicate' disallows highlighting."
  (if (and sr-highlight-predicate
           (not (funcall sr-highlight-predicate)))
      (sr--remove-highlight)
    (let ((bounds (sr--get-current-unit-bounds)))
      (when bounds
        (unless sr--highlight-overlay
          (setq sr--highlight-overlay (make-overlay (point) (point)))
          (overlay-put sr--highlight-overlay 'face 'sr-highlight-face)
          (overlay-put sr--highlight-overlay 'priority 100))
        (move-overlay sr--highlight-overlay (car bounds) (cdr bounds))))))

(defun sr--remove-highlight ()
  "Remove the highlight overlay."
  (when sr--highlight-overlay
    (delete-overlay sr--highlight-overlay)
    (setq sr--highlight-overlay nil)))

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
