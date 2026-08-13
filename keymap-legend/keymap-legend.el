;;; keymap-legend.el --- Render keymap legends as keyboard diagrams -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: convenience, help
;; URL: https://github.com/romanfrolow/keymap-legend
;;
;;; Commentary:
;;
;; `keymap-legend' renders temporary, text-only keyboard diagrams displayed
;; above the source window's mode line — similar to Ki editor's
;; `KeymapLegend'.  Bindings are laid out on a physical QWERTY grid with
;; normal, Shift, and Alt slots.  The rendering adapts to window width.
;;
;; Usage:
;;
;;   (keymap-legend-show "Title" my-keymap '(:title "Title"))
;;   (keymap-legend-hide)
;;
;;; Code:

(require 'cl-lib)
(require 'face-remap)

(defgroup keymap-legend nil
  "Keymap legends for `keymap-legend'."
  :group 'convenience)

(defconst keymap-legend-buffer-name "*keymap-legend*"
  "Name of the buffer used to display a `KeymapLegend'.")

(defconst keymap-legend-qwerty-layout
  '((("q" "Q") ("w" "W") ("e" "E") ("r" "R") ("t" "T")
     ("y" "Y") ("u" "U") ("i" "I") ("o" "O") ("p" "P"))
    (("a" "A") ("s" "S") ("d" "D") ("f" "F") ("g" "G")
     ("h" "H") ("j" "J") ("k" "K") ("l" "L") (";" ":"))
    (("z" "Z") ("x" "X") ("c" "C") ("v" "V") ("b" "B")
     ("n" "N") ("m" "M") ("," "<") ("." ">") ("/" "?")))
  "Default physical QWERTY layout for keymap legends.")

(defcustom keymap-legend-layout
  keymap-legend-qwerty-layout
  "Physical keyboard layout used by keymap legends."
  :type '(repeat (repeat (list string string)))
  :group 'keymap-legend)

(defcustom keymap-legend-max-label-width
  11
  "Maximum display width of one binding label in a keymap legend.
Longer labels are truncated with an ellipsis before rendering."
  :type 'integer
  :group 'keymap-legend)

(defvar keymap-legend--state nil
  "Complete state of the active `KeymapLegend', or nil.")

(defvar keymap-legend--window nil
  "Window currently displaying the `KeymapLegend'.

This compatibility variable mirrors the window in
`keymap-legend--state'.")

(defvar keymap-legend--source-state nil
  "State needed to restore the source window's mode line.

This compatibility variable mirrors the source state in
`keymap-legend--state'.")

(defvar keymap-legend--cleanup-running nil
  "Non-nil while legend cleanup is running.")

(defun keymap-legend--layout-user-error (format-string &rest args)
  "Signal a readable layout error using FORMAT-STRING and ARGS."
  (apply #'user-error
         (concat "Invalid keymap-legend-layout: " format-string)
         args))

(defun keymap-legend--parse-layout-event (description row column slot)
  "Parse one layout DESCRIPTION at ROW, COLUMN, and SLOT."
  (unless (stringp description)
    (keymap-legend--layout-user-error
     "cell %d,%d %s is not a string"
     (1+ row) (1+ column) slot))
  (condition-case nil
      (let ((key (kbd description)))
        (unless (or (and (stringp key) (= (length key) 1))
                    (and (vectorp key) (= (length key) 1)))
          (keymap-legend--layout-user-error
           "cell %d,%d %s must describe exactly one event"
           (1+ row) (1+ column) slot))
        (aref key 0))
    (error
     (keymap-legend--layout-user-error
      "cell %d,%d %s is not a valid kbd description: %S"
      (1+ row) (1+ column) slot description))))

(defun keymap-legend--validate-layout (&optional layout)
  "Validate and normalize LAYOUT, returning physical cell metadata.

The returned value is independent of the user option and is safe for pure
normalization and rendering functions to consume."
  (let* ((layout (or layout keymap-legend-layout))
         (row-count (condition-case nil (length layout) (error nil))))
    (unless (and (listp layout) (= row-count 3))
      (keymap-legend--layout-user-error
       "expected exactly three rows"))
    (let ((rows nil)
          (seen-events (make-hash-table :test #'equal))
          (seen-normal-basics (make-hash-table :test #'equal)))
      (cl-loop for row in layout
               for row-index from 0
               do
               (let ((column-count
                      (condition-case nil (length row) (error nil))))
                 (unless (and (listp row) (= column-count 10))
                   (keymap-legend--layout-user-error
                    "row %d must contain exactly ten cells"
                    (1+ row-index)))
                 (let (cells)
                   (cl-loop for cell in row
                            for column-index from 0
                            do
                            (unless (and (listp cell) (= (length cell) 2))
                              (keymap-legend--layout-user-error
                               "cell %d,%d must contain normal and Shift descriptions"
                               (1+ row-index) (1+ column-index)))
                            (let* ((normal
                                    (keymap-legend--parse-layout-event
                                     (nth 0 cell) row-index column-index :normal))
                                   (shift
                                    (keymap-legend--parse-layout-event
                                     (nth 1 cell) row-index column-index :shift))
                                   (normal-basic (event-basic-type normal)))
                              (when (or (gethash normal seen-events)
                                        (gethash shift seen-events))
                                (keymap-legend--layout-user-error
                                 "event in cell %d,%d is duplicated"
                                 (1+ row-index) (1+ column-index)))
                              (when (gethash normal-basic seen-normal-basics)
                                (keymap-legend--layout-user-error
                                 "normal physical event in cell %d,%d is duplicated"
                                 (1+ row-index) (1+ column-index)))
                              (puthash normal t seen-events)
                              (puthash shift t seen-events)
                              (puthash normal-basic t seen-normal-basics)
                              (push (list :row row-index
                                          :column column-index
                                          :normal-event normal
                                          :shift-event shift)
                                    cells)))
                   (push (nreverse cells) rows))))
      (list :rows (nreverse rows)))))

(defun keymap-legend--layout-cells (layout-data)
  "Return the cells in LAYOUT-DATA in physical order."
  (apply #'append (plist-get layout-data :rows)))

(defun keymap-legend--empty-matrix ()
  "Return a fresh empty three-by-ten cell matrix."
  (mapcar (lambda (_row) (make-list 10 nil)) (number-sequence 1 3)))

(defun keymap-legend--event-key (event)
  "Return the one-event key sequence for EVENT."
  (vector event))

(defun keymap-legend--ki-style-key-description (event)
  "Return a ki-style key description for EVENT.

Converts Emacs event representation to match ki editor's
convention: lowercase names without angle brackets,
\"space\"/\"enter\"/\"esc\", and \"alt+\"/\"ctrl+\"/\"shift+\" modifiers."
  (let* ((modifiers (event-modifiers event))
         (basic (event-basic-type event))
         (name
          (pcase basic
            ((pred characterp)
             (pcase basic
               (?\s "space")
               (?\t "tab")
               (?\r "enter")
               (_ (char-to-string basic))))
            ('return "enter")
            ('escape "esc")
            ('prior "pageup")
            ('next "pagedown")
            ((pred (lambda (s) (and (symbolp s) (string-prefix-p "f" (symbol-name s)))))
             (upcase (symbol-name basic)))
            (_ (downcase (symbol-name basic)))))
         (sorted-mods
          (sort (copy-sequence modifiers)
                (lambda (a b)
                  (< (or (cl-position a '(control meta alt shift super hyper)) 99)
                     (or (cl-position b '(control meta alt shift super hyper)) 99)))))
         (prefix
          (mapconcat
           (lambda (mod)
             (pcase mod
               ((or 'meta 'alt) "alt")
               ('control "ctrl")
               ('shift "shift")
               ('super "super")
               ('hyper "hyper")
               (_ (symbol-name mod))))
           sorted-mods "+"))
         (prefix (if (string-empty-p prefix) "" (concat prefix "+"))))
    (concat prefix name)))

(defun keymap-legend--entry-key-description (event)
  "Return the key description for one EVENT, in ki-editor style."
  (keymap-legend--ki-style-key-description event))

(defun keymap-legend--canonical-event (event)
  "Normalize EVENT to its function-key form for display and cell matching.

Emacs keymaps often contain two entries for the same physical key: the
ASCII control character (e.g. ?\\r) and the function-key symbol
(e.g. `return').  This function maps common ASCII equivalents to their
canonical function-key representation so that `map-keymap' duplicates
are deduplicated and layout cells match both forms."
  (pcase event
    (?\r 'return)
    (?\t 'tab)
    (?\e 'escape)
    ((or ?\d ?\C-h) 'backspace)
    (_ event)))

(defun keymap-legend--menu-item-p (binding)
  "Return non-nil when BINDING is a directly described menu item."
  (and (consp binding)
       (eq (car binding) 'menu-item)
       (stringp (nth 1 binding))))

(defun keymap-legend--visible-entry (keymap event key binding index)
  "Return a visible entry for EVENT and direct menu-item BINDING.

KEY is the actual key sequence passed to `lookup-key'."
  (let ((command (lookup-key keymap key)))
    (when command
      (list :event event
            :key (keymap-legend--entry-key-description event)
            :description (nth 1 binding)
            :command command
            :index index))))


(defun keymap-legend--command-description (command)
  "Return a short human-readable label for COMMAND."
  (if (and (symbolp command) (fboundp command))
      (let* ((name (symbol-name command))
             (stripped (cond ((string-prefix-p "ri--" name)
                              (substring name 4))
                             ((string-prefix-p "ri-" name)
                              (substring name 3))
                             (t name))))
        (capitalize (replace-regexp-in-string "-" " " stripped)))
    (format "%s" command)))
(defun keymap-legend--entries (keymap &optional source-window source-buffer)
  "Collect visible menu-item entries directly from KEYMAP.

When supplied, SOURCE-WINDOW and SOURCE-BUFFER are used as the Emacs
context for both `map-keymap' and each single `lookup-key' call."
  (let* ((source-window (or source-window (selected-window)))
         (source-buffer (or source-buffer (window-buffer source-window)))
         (entries nil)
         (index 0)
         (seen (make-hash-table :test #'equal)))
    (unless (and (window-live-p source-window)
                 (buffer-live-p source-buffer))
      (user-error "Cannot inspect a dead keymap legend source"))
    (with-selected-window source-window
      (with-current-buffer source-buffer
        (map-keymap
         (lambda (event binding)
           (cond
            ((keymap-legend--menu-item-p binding)
             (let ((canonical (keymap-legend--canonical-event event)))
               (when-let* ((entry
                            (keymap-legend--visible-entry
                             keymap canonical
                             (keymap-legend--event-key event)
                             binding index)))
                 (unless (gethash (cons canonical (plist-get entry :command)) seen)
                   (puthash (cons canonical (plist-get entry :command)) t seen)
                   (push entry entries)
                   (setq index (1+ index))))))
            ;; Emacs stores a simple M- event entered with `define-key'
            ;; below the ESC prefix.  Treat only that canonical Meta prefix
            ;; as one physical event; arbitrary prefix maps stay excluded.
            ((and (eq event ?\e) (keymapp binding))
             (map-keymap
              (lambda (child-event child-binding)
                (cond
                 ((keymap-legend--menu-item-p child-binding)
                  (let ((canonical
                         (keymap-legend--canonical-event
                          (event-convert-list (list 'meta child-event)))))
                    (when-let* ((entry
                                 (keymap-legend--visible-entry
                                  keymap canonical
                                  (vector event child-event)
                                  child-binding index)))
                      (unless (gethash (cons canonical (plist-get entry :command)) seen)
                        (puthash (cons canonical (plist-get entry :command)) t seen)
                        (push entry entries)
                        (setq index (1+ index))))))
                 ((and (not (keymapp child-binding))
                       (commandp child-binding))
                  (let ((canonical
                         (keymap-legend--canonical-event
                          (event-convert-list (list 'meta child-event)))))
                    (when-let* ((entry
                                 (keymap-legend--visible-entry
                                  keymap canonical
                                  (vector event child-event)
                                  (list 'menu-item
                                        (keymap-legend--command-description child-binding)
                                        child-binding)
                                  index)))
                      (unless (gethash (cons canonical (plist-get entry :command)) seen)
                        (puthash (cons canonical (plist-get entry :command)) t seen)
                        (push entry entries)
                        (setq index (1+ index))))))))
              binding))
            ((and (not (keymapp binding)) (commandp binding))
             (let ((canonical (keymap-legend--canonical-event event)))
               (when-let* ((entry
                            (keymap-legend--visible-entry
                             keymap canonical
                             (keymap-legend--event-key event)
                             (list 'menu-item
                                   (keymap-legend--command-description binding)
                                   binding)
                             index)))
                 (unless (gethash (cons canonical (plist-get entry :command)) seen)
                   (puthash (cons canonical (plist-get entry :command)) t seen)
                   (push entry entries)
                   (setq index (1+ index))))))))
         keymap)))
    (nreverse entries)))

(defun keymap-legend--only-modifier-p (modifiers modifier)
  "Return non-nil when MODIFIERS contains only MODIFIER."
  (and (= (length modifiers) 1)
       (eq (car modifiers) modifier)))

(defun keymap-legend--cell-for-event (cells event property)
  "Find in CELLS the cell whose PROPERTY event equals EVENT."
  (cl-find-if (lambda (cell)
                (equal event (plist-get cell property)))
              cells))

(defun keymap-legend--cell-for-normal-basic (cells basic)
  "Find the normal cell in CELLS whose basic event is BASIC."
  (cl-find-if (lambda (cell)
                (equal basic
                       (event-basic-type (plist-get cell :normal-event))))
              cells))

(defun keymap-legend--normalize-entry (entry cells)
  "Return physical placement for ENTRY, or nil when it is overflow.

The result is a plist containing `:row', `:column', and `:slot'."
  (let* ((event (plist-get entry :event))
         (modifiers (event-modifiers event))
         (basic (event-basic-type event))
         (cell nil)
         (slot nil))
    (cond
     ((null modifiers)
      (when-let* ((normal-cell
                  (keymap-legend--cell-for-event
                   cells event :normal-event)))
        (setq cell normal-cell
              slot :normal))
      (unless cell
        (when-let* ((shift-cell
                    (keymap-legend--cell-for-event
                     cells event :shift-event)))
          (setq cell shift-cell
                slot :shift))))
     ((keymap-legend--only-modifier-p modifiers 'shift)
      (when-let* ((normal-cell
                  (keymap-legend--cell-for-normal-basic cells basic)))
        (setq cell normal-cell
              slot :shift)))
     ((or (keymap-legend--only-modifier-p modifiers 'meta)
          (keymap-legend--only-modifier-p modifiers 'alt))
      (when-let* ((normal-cell
                   (keymap-legend--cell-for-normal-basic cells basic)))
        (setq cell normal-cell
              slot :alt))))
    (when cell
      (list :row (plist-get cell :row)
            :column (plist-get cell :column)
            :slot slot))))

(defun keymap-legend--entry-with-placement (entry placement)
  "Return ENTRY copied with PLACEMENT metadata."
  (let ((copy (copy-sequence entry)))
    (plist-put copy :placement placement)))

(defun keymap-legend--entry-placement-key (placement)
  "Return a hash key for PLACEMENT."
  (list (plist-get placement :row)
        (plist-get placement :column)
        (plist-get placement :slot)))

(defun keymap-legend--entry-sort-by-key (left right)
  "Sort entries LEFT and RIGHT by key description and source index."
  (let ((left-key (plist-get left :key))
        (right-key (plist-get right :key)))
    (or (string-lessp left-key right-key)
        (and (string= left-key right-key)
             (< (or (plist-get left :index) 0)
                (or (plist-get right :index) 0))))))

(defun keymap-legend--normalize-entries (entries layout-data release)
  "Build a pure physical model from ENTRIES and LAYOUT-DATA.

RELEASE is retained for the final release-hold block.  Collisions never
replace an existing slot: every colliding entry is retained in overflow."
  (let ((matrix (keymap-legend--empty-matrix))
        (cells nil)
        (overflow nil)
        (all-entries nil)
        (collisions (make-hash-table :test #'equal)))
    (dolist (layout-cell (keymap-legend--layout-cells layout-data))
      (let ((cell (copy-sequence layout-cell)))
        (dolist (slot '(:normal :shift :alt))
          (setq cell (plist-put cell slot nil)))
        (setf (nth (plist-get cell :column)
                   (nth (plist-get cell :row) matrix)) cell)
        (push cell cells)))
    (dolist (entry entries)
      (let* ((placement (keymap-legend--normalize-entry entry cells))
             (placed (keymap-legend--entry-with-placement
                      entry placement)))
        (push placed all-entries)
        (if (not placement)
            (push placed overflow)
          (let* ((row (plist-get placement :row))
                 (column (plist-get placement :column))
                 (slot (plist-get placement :slot))
                 (cell (nth column (nth row matrix)))
                 (collision-key
                  (keymap-legend--entry-placement-key placement))
                 (current (plist-get cell slot)))
            (if (or current (gethash collision-key collisions))
                (progn
                  (when current
                    (push current overflow))
                  (puthash collision-key t collisions)
                  (push placed overflow)
                  (setf (plist-get cell slot) nil))
              (setf (plist-get cell slot) placed))))))
    (setq overflow (sort overflow #'keymap-legend--entry-sort-by-key))
    (list :layout-data layout-data
          :matrix matrix
          :entries (nreverse all-entries)
          :overflow overflow
          :release release)))

(defun keymap-legend--build-model (keymap legend-spec source-window source-buffer)
  "Collect KEYMAP in SOURCE-WINDOW and SOURCE-BUFFER and normalize it."
  (let* ((layout-data (keymap-legend--validate-layout))
         (entries (keymap-legend--entries
                   keymap source-window source-buffer)))
    (keymap-legend--normalize-entries
     entries layout-data (plist-get legend-spec :release))))
(defun keymap-legend--escape-mode-line-percents (string)
  "Double every `%' in STRING, preserving text properties.
The result is safe to return from an `:eval' mode-line construct
whose value Emacs will parse for `%'-constructs again."
  (replace-regexp-in-string
   "%" (lambda (match) (concat match match))
   string t t))

(defun keymap-legend--source-mode-line ()
  "Render the saved source window's mode line in the legend window."
  (let* ((state keymap-legend--source-state)
         (window (plist-get state :window))
         (buffer (plist-get state :buffer))
         (format (plist-get state :mode-line-format)))
    (when (and format
               (not (eq format 'none))
               (window-live-p window)
               (buffer-live-p buffer))
      ;; Redisplay may temporarily reset a non-selected source window's
      ;; point while evaluating this mode line.  Restore the source
      ;; buffer's point so position fields such as `%l' stay accurate.
      (let ((source-point
             (with-current-buffer buffer
               (point))))
        (set-window-point window source-point)
        (keymap-legend--escape-mode-line-percents
         (format-mode-line format t window buffer))))))

(defun keymap-legend--header-line (title)
  "Render TITLE on a full-width gray header line."
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (let* ((width (max 1 (window-body-width window)))
           (text (truncate-string-to-width (or title "") width))
           (padding
            (make-string
             (max 0 (- width (string-width text)))
             ?\s)))
      (propertize
       (concat text padding)
       'face '(:foreground "#ffffff" :background "#aaaaaa"
               :box nil :underline nil)))))

(defun keymap-legend--capture-source-state (window buffer)
  "Capture mode-line and face state for WINDOW displaying BUFFER."
  (let ((window-format (window-parameter window 'mode-line-format)))
    (list :window window
          :buffer buffer
          :window-mode-line-format window-format
          :buffer-mode-line-format
          (buffer-local-value 'mode-line-format buffer)
          :mode-line-format
          (if window-format
              window-format
            (buffer-local-value 'mode-line-format buffer))
          :face-remapping-alist
          (copy-tree (buffer-local-value 'face-remapping-alist buffer)))))

(defun keymap-legend--mode-line-face-remappings (buffer)
  "Return fresh mode-line face remappings from BUFFER."
  (let (result)
    (dolist (entry (buffer-local-value 'face-remapping-alist buffer)
                   (nreverse result))
      (when (memq (car-safe entry)
                  '(mode-line mode-line-active mode-line-inactive))
        (push (copy-tree entry) result)))))

(defun keymap-legend--display-window (buffer)
  "Return the bottom side window displaying `KeymapLegend' BUFFER."
  (display-buffer-in-side-window
   buffer
   '((side . bottom)
     (slot . 0)
     (window-height . fit-window-to-buffer))))

(defun keymap-legend--limit-label (label)
  "Truncate LABEL to `keymap-legend-max-label-width' display columns."
  (truncate-string-to-width
   (or label "")
   (max 1 keymap-legend-max-label-width)
   0 nil "…"))

(defun keymap-legend--cell-entry-text (entry)
  "Return the bounded display description from ENTRY or an empty string."
  (if entry
      (keymap-legend--limit-label
       (or (plist-get entry :description) ""))
    ""))

(defun keymap-legend--table-cell-widths (matrix columns)
  "Return natural display widths for COLUMNS in MATRIX."
  (mapcar
   (lambda (column)
     (+ 2
        (cl-loop for row in matrix
                 maximize
                 (cl-loop for slot in '(:alt :shift :normal)
                          maximize
                          (string-width
                           (keymap-legend--cell-entry-text
                            (plist-get (nth column row) slot))))
                 into maximum
                 finally return (or maximum 0))))
   columns))

(defun keymap-legend--table-segments (columns cell-widths modifier-index)
  "Return table segments for COLUMNS and CELL-WIDTHS.

MODIFIER-INDEX is the number of physical cells before the modifier column."
  (let ((cells nil)
        (index 0))
    (dolist (column columns)
      (push (list :kind :cell
                  :column column
                  :width (nth index cell-widths))
            cells)
      (setq index (1+ index)))
    (setq cells (nreverse cells))
    (append (cl-subseq cells 0 modifier-index)
            (list (list :kind :modifier :width 3))
            (cl-subseq cells modifier-index))))

(defun keymap-legend--table-width (matrix columns modifier-index)
  "Return the natural width of a table over MATRIX and COLUMNS."
  (let* ((cell-widths (keymap-legend--table-cell-widths matrix columns))
         (segments (keymap-legend--table-segments
                    columns cell-widths modifier-index)))
    (+ 2
       (cl-loop for segment in segments
                sum (plist-get segment :width))
       (1- (length segments)))))

(defun keymap-legend--center-text (text width)
  "Center TEXT in a fixed WIDTH, putting odd padding on the right."
  (let* ((text (or text ""))
         (text-width (string-width text))
         (available (max 0 (- width 2)))
         (left (/ (max 0 (- available text-width)) 2))
         (right (max 0 (- available text-width left))))
    (concat (make-string (1+ left) ?\s)
            text
            (make-string (1+ right) ?\s))))

(defun keymap-legend--border-line (segments left junction right character)
  "Build a border from SEGMENTS using CHARACTER and the given glyphs."
  (let ((line left)
        (first t))
    (dolist (segment segments)
      (unless first
        (setq line (concat line junction)))
      (setq first nil)
      (setq line
            (concat line
                    (make-string (plist-get segment :width) character))))
    (concat line right)))

(defun keymap-legend--table-group-rows (matrix row columns)
  "Return modifier groups for physical ROW of MATRIX and COLUMNS."
  (let ((cells (mapcar (lambda (column) (nth column (nth row matrix))) columns))
        groups)
    (when (cl-some (lambda (cell) (plist-get cell :alt)) cells)
      (push (list :slot :alt :modifier "⌥") groups))
    (when (cl-some (lambda (cell) (plist-get cell :shift)) cells)
      (push (list :slot :shift :modifier "⇧") groups))
    (push (list :slot :normal :modifier "∅") groups)
    (nreverse groups)))

(defun keymap-legend--table-content-line (matrix row _columns segments group)
  "Render GROUP for ROW using table SEGMENTS."
  (let* ((slot (plist-get group :slot))
         (modifier (plist-get group :modifier))
         (parts
          (mapcar
           (lambda (segment)
             (if (eq (plist-get segment :kind) :modifier)
                 (keymap-legend--center-text
                  modifier (plist-get segment :width))
               (keymap-legend--center-text
                (keymap-legend--cell-entry-text
                 (plist-get (nth (plist-get segment :column)
                                 (nth row matrix))
                            slot))
                (plist-get segment :width))))
           segments)))
    (concat "│" (mapconcat #'identity parts "┆") "│")))
(defun keymap-legend--render-table (matrix columns modifier-index)
  "Render a pure fixed-pitch table from MATRIX over COLUMNS."
  (let* ((cell-widths (keymap-legend--table-cell-widths matrix columns))
         (segments (keymap-legend--table-segments
                    columns cell-widths modifier-index))
         (lines
          (list
           (keymap-legend--border-line
            segments "╭" "┬" "╮" ?─))))
    (dotimes (row 3)
      (dolist (group (keymap-legend--table-group-rows matrix row columns))
        (setq lines
              (append lines
                      (list
                       (keymap-legend--table-content-line
                        matrix row columns segments group)))))
      (when (< row 2)
        (setq lines
              (append lines
                      (list
                       (keymap-legend--border-line
                        segments "├" "┼" "┤" ?╌))))))
    (setq lines
          (append lines
                  (list
                   (keymap-legend--border-line
                    segments "╰" "┴" "╯" ?─))))
    (propertize (mapconcat #'identity lines "\n") 'face 'fixed-pitch)))

(defun keymap-legend--render-half (matrix columns side)
  "Render one pure table half from MATRIX and COLUMNS.
SIDE is either `left' or `right' and controls modifier placement."
  (keymap-legend--render-table
   matrix columns (if (eq side 'left) (length columns) 0)))

(defun keymap-legend--entry-slot-order (slot)
  "Return the compact ordering number for SLOT."
  (or (cl-position slot '(:normal :shift :alt)) 99))

(defun keymap-legend--compact-entry-less-p (left right)
  "Sort compact entries LEFT and RIGHT by physical position."
  (let ((left-placement (plist-get left :placement))
        (right-placement (plist-get right :placement)))
    (cond
     ((and left-placement right-placement)
      (or (< (plist-get left-placement :row)
             (plist-get right-placement :row))
          (and (= (plist-get left-placement :row)
                  (plist-get right-placement :row))
               (or (< (plist-get left-placement :column)
                      (plist-get right-placement :column))
                   (and (= (plist-get left-placement :column)
                           (plist-get right-placement :column))
                        (or (< (keymap-legend--entry-slot-order
                                (plist-get left-placement :slot))
                               (keymap-legend--entry-slot-order
                                (plist-get right-placement :slot)))
                            (and (= (keymap-legend--entry-slot-order
                                     (plist-get left-placement :slot))
                                    (keymap-legend--entry-slot-order
                                     (plist-get right-placement :slot)))
                                 (keymap-legend--entry-sort-by-key
                                  left right))))))))
     (left-placement t)
     (right-placement nil)
     (t (keymap-legend--entry-sort-by-key left right)))))

(defun keymap-legend--wrap-text-internal
    (text width indent &optional indent-first)
  "Wrap TEXT to WIDTH, using INDENT on continuation lines.

When INDENT-FIRST is non-nil, use INDENT on the first line as well."
  (let ((remaining (or text ""))
        (lines nil)
        (first t)
        (width (max 1 width)))
    (if (= (length remaining) 0)
        (list "")
      (while (> (length remaining) 0)
        (let* ((raw-indent
                (if (or indent-first (not first)) (or indent "") ""))
               (indent (if (< (string-width raw-indent) width)
                           raw-indent
                         (truncate-string-to-width
                          raw-indent (max 0 (1- width)))))
               (capacity (max 1 (- width (string-width indent))))
               (piece-and-rest
                (keymap-legend--take-segment remaining capacity))
               (piece (car piece-and-rest)))
          (push (concat indent piece) lines)
          (setq remaining (cdr piece-and-rest)
                first nil))))
    (nreverse lines)))
(defun keymap-legend--take-segment (text width)
  "Take a width-limited prefix of TEXT, preferring word boundaries."
  (if (= (length text) 0)
      (cons "" "")
    (let* ((width (max 1 width))
           (candidate (truncate-string-to-width text width))
           (candidate (if (= (length candidate) 0)
                          (substring text 0 1)
                        candidate))
           (truncated (< (length candidate) (length text)))
           (next-character
            (and truncated
                 (aref text (length candidate))))
           (next-is-space
            (and next-character
                 (string-match-p
                  "[[:space:]]+" (char-to-string next-character))))
           (last-space nil)
           (position 0))
      (while (string-match "[[:space:]]+" candidate position)
        (setq last-space (match-end 0)
              position (match-end 0)))
      (when (and truncated
                 (not next-is-space)
                 last-space
                 (> last-space 0)
                 (< last-space (length candidate)))
        (setq candidate (substring candidate 0 last-space)))
      (let ((rest (substring text (length candidate))))
        (when (and truncated next-is-space)
          (setq rest (replace-regexp-in-string
                      "\\`[[:space:]]+" "" rest)))
        (cons candidate rest)))))
(defun keymap-legend--wrap-text (text width)
  "Wrap TEXT to WIDTH without continuation indentation."
  (keymap-legend--wrap-text-internal text width ""))

(defun keymap-legend--wrap-text-with-indent (text width indent)
  "Wrap TEXT to WIDTH with INDENT on every line."
  (keymap-legend--wrap-text-internal text width indent t))

(defun keymap-legend--wrap-labeled (prefix description width)
  "Wrap DESCRIPTION after PREFIX to WIDTH without losing either string."
  (let ((prefix (or prefix ""))
        (description (or description ""))
        (width (max 1 width)))
    (if (>= (string-width prefix) width)
        (append
         (keymap-legend--wrap-text prefix width)
         (if (> (length description) 0)
             (keymap-legend--wrap-text-with-indent
              description width
              (make-string
               (min (string-width prefix) (max 0 (1- width)))
               ?\s))
           nil))
      (let* ((capacity (max 1 (- width (string-width prefix))))
             (piece-and-rest
              (keymap-legend--take-segment description capacity))
             (piece (car piece-and-rest))
             (rest (cdr piece-and-rest))
             (lines (list (concat prefix piece))))
        (when (> (length rest) 0)
          (setq lines
                (append lines
                        (keymap-legend--wrap-text-with-indent
                         rest width
                         (make-string (string-width prefix) ?\s)))))
        lines))))

(defun keymap-legend--render-overflow (overflow width)
  "Render sorted OVERFLOW entries and its heading within WIDTH."
  (if (null overflow)
      ""
    (let* ((parts (mapcar (lambda (entry)
                            (concat (plist-get entry :key) " — "
                                    (keymap-legend--limit-label
                                     (plist-get entry :description))))
                          overflow))
           (text (concat "Other bindings: " (mapconcat #'identity parts ", "))))
      (mapconcat #'identity
                 (keymap-legend--wrap-text text width)
                 "\n"))))

(defun keymap-legend--render-compact (entries release width)
  "Render all ENTRIES as a compact list, followed by RELEASE if present."
  (let ((lines nil))
    (dolist (entry (sort (copy-sequence entries)
                         #'keymap-legend--compact-entry-less-p))
      (setq lines
            (append lines
                    (keymap-legend--wrap-labeled
                     (concat (plist-get entry :key) " — ")
                     (keymap-legend--limit-label
                      (plist-get entry :description))
                     width))))
    (when release
      (setq lines
            (append lines
                    (keymap-legend--wrap-text
                     (format "Release hold: %s"
                             (keymap-legend--limit-label release))
                     width))))
    (mapconcat #'identity lines "\n")))

(defun keymap-legend--render-for-width (model width)
  "Select and render MODEL for WIDTH, returning mode and text metadata."
  (let* ((matrix (plist-get model :matrix))
         (columns (number-sequence 0 9))
         (left-columns (number-sequence 0 4))
         (right-columns (number-sequence 5 9))
         (width (max 1 width))
         (full-width (keymap-legend--table-width matrix columns 5))
         (left-width (keymap-legend--table-width matrix left-columns 5))
         (right-width (keymap-legend--table-width matrix right-columns 0))
         (mode (cond
                ((<= full-width width) 'full)
                ((and (<= left-width width) (<= right-width width)) 'split)
                (t 'compact)))
         (blocks nil))
    (pcase mode
      ('full
       (push (keymap-legend--render-table matrix columns 5) blocks))
      ('split
       (push (keymap-legend--render-half matrix left-columns 'left) blocks)
       (push (keymap-legend--render-half matrix right-columns 'right) blocks))
      ('compact
       (setq blocks
             (list
              (keymap-legend--render-compact
               (plist-get model :entries)
               (plist-get model :release)
               width)))))
    (when (and (not (eq mode 'compact))
               (plist-get model :overflow))
      (push (keymap-legend--render-overflow
             (plist-get model :overflow) width)
            blocks))
    (when (and (not (eq mode 'compact))
               (plist-get model :release))
      (push (mapconcat #'identity
                       (keymap-legend--wrap-text
                        (format "Release hold: %s"
                                (keymap-legend--limit-label
                                 (plist-get model :release)))
                        width)
                       "\n")
            blocks))
    (setq blocks (nreverse blocks))
    (list :mode mode
          :text (mapconcat #'identity blocks "\n")
          :natural-width full-width
          :left-width left-width
          :right-width right-width)))

(defun keymap-legend--render (model width)
  "Render pure MODEL for the supplied WIDTH."
  (plist-get (keymap-legend--render-for-width model width) :text))

(defun keymap-legend--window-for-buffer (buffer)
  "Return the live `KeymapLegend' window for BUFFER, if any."
  (let ((window (or (and keymap-legend--state
                         (plist-get keymap-legend--state :window))
                    keymap-legend--window)))
    (when (and (window-live-p window)
               (buffer-live-p buffer)
               (eq (window-buffer window) buffer))
      window)))

;;;###autoload
(defun keymap-legend-window ()
  "Return the live window displaying the active keymap legend, or nil."
  (when-let* ((state keymap-legend--state)
              (window (plist-get state :window))
              (buffer (plist-get state :buffer)))
    (and (window-live-p window)
         (buffer-live-p buffer)
         (eq (window-buffer window) buffer)
         window)))

(defun keymap-legend--restore-source-state (source-state)
  "Restore the source mode line and face remappings from SOURCE-STATE."
  (let ((window (plist-get source-state :window))
        (buffer (plist-get source-state :buffer)))
    (when (window-live-p window)
      (set-window-parameter
       window 'mode-line-format
       (plist-get source-state :window-mode-line-format)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (plist-member source-state :buffer-mode-line-format)
          (setq-local mode-line-format
                      (plist-get source-state :buffer-mode-line-format)))
        (when (plist-member source-state :face-remapping-alist)
          (setq-local face-remapping-alist
                      (copy-tree
                       (plist-get source-state :face-remapping-alist))))))))

(defun keymap-legend--cleanup (&optional kill-buffer buffer window)
  "Restore source state and remove the legend, idempotently.

When KILL-BUFFER is non-nil, kill BUFFER after deleting WINDOW."
  (when (or keymap-legend--state buffer window)
  (let* ((state keymap-legend--state)
         (source-state (or (plist-get state :source-state)
                           keymap-legend--source-state))
         (buffer (or buffer
                     (plist-get state :buffer)
                     (get-buffer keymap-legend-buffer-name)))
         (window (or window
                     (plist-get state :window)
                     keymap-legend--window
                     (and (buffer-live-p buffer)
                          (get-buffer-window buffer t)))))
    (setq keymap-legend--state nil
          keymap-legend--window nil
          keymap-legend--source-state nil)
    (let ((keymap-legend--cleanup-running t))
      (unwind-protect
          (progn
            (when source-state
              (ignore-errors
                (keymap-legend--restore-source-state source-state)))
            (when (window-live-p window)
              (ignore-errors (delete-window window)))
            (when (and kill-buffer (buffer-live-p buffer))
              (ignore-errors (kill-buffer buffer))))
        (setq keymap-legend--state nil
              keymap-legend--window nil
              keymap-legend--source-state nil))))))

(defun keymap-legend--buffer-killed ()
  "Restore the source when the legend buffer is killed externally."
  (unless keymap-legend--cleanup-running
    (keymap-legend--cleanup nil (current-buffer)
                               (or (and keymap-legend--state
                                        (plist-get keymap-legend--state :window))
                                   keymap-legend--window))))

(defun keymap-legend--render-state (&optional window force)
  "Rerender the active legend in WINDOW, optionally ignoring its width cache."
  (let* ((state keymap-legend--state)
         (window (or window (plist-get state :window)))
         (buffer (plist-get state :buffer))
         (last-width (plist-get state :last-width)))
    (when (and state
               (window-live-p window)
               (buffer-live-p buffer)
               (or force
                   (not (equal (max 1 (window-body-width window)) last-width))))
      (let ((width (max 1 (window-body-width window))))
        (setf (plist-get state :last-width) width)
        (unless (plist-get state :rendering)
          (setf (plist-get state :rendering) t)
          (unwind-protect
              (let* ((source-state (plist-get state :source-state))
                     (model
                      (keymap-legend--build-model
                       (plist-get state :keymap)
                       (plist-get state :legend-spec)
                       (plist-get source-state :window)
                       (plist-get source-state :buffer)))
                     (text (keymap-legend--render model width)))
                (with-current-buffer buffer
                  (let ((inhibit-read-only t))
                    (erase-buffer)
                    (insert text)
                    (goto-char (point-min))))
                (when (window-live-p window)
                  (fit-window-to-buffer window)))
            (setf (plist-get state :rendering) nil)))))))

(defun keymap-legend--window-size-change (window)
  "Rerender the legend when WINDOW's body width changes."
  (when (and (window-live-p window)
             keymap-legend--state
             (eq window (plist-get keymap-legend--state :window)))
    (with-current-buffer (window-buffer window)
      (keymap-legend--render-state window nil))))

;;;###autoload
(defun keymap-legend-show (title keymap legend-spec)
  "Show a bottom `KeymapLegend' above the source window's mode line.
TITLE labels the legend.  KEYMAP supplies its described bindings, and
LEGEND-SPEC controls its title and optional release line."
  (keymap-legend-hide)
  (let* ((source-window (selected-window))
         (source-buffer (window-buffer source-window))
         (source-state
          (keymap-legend--capture-source-state
           source-window source-buffer))
         (buffer nil)
         (window nil)
         (success nil))
    ;; Validate before changing the source window's mode line.
    (keymap-legend--validate-layout)
    (setq buffer (get-buffer-create keymap-legend-buffer-name))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (special-mode)
            (setq-local
             face-remapping-alist
             (keymap-legend--mode-line-face-remappings source-buffer))
            (let ((inhibit-read-only t))
              (erase-buffer))
            (setq-local mode-line-format nil)
            (setq-local header-line-format
                        `(:eval (keymap-legend--header-line ,title)))
            (setq-local truncate-lines nil)
            (setq-local word-wrap nil)
            (setq-local cursor-type nil)
            (setq-local window-size-change-functions nil)
            (add-hook 'kill-buffer-hook
                      #'keymap-legend--buffer-killed nil t)
            (goto-char (point-min)))
          (setq window (keymap-legend--display-window buffer))
          (unless (window-live-p window)
            (user-error "Could not create the keymap legend window"))
          (setq keymap-legend--state
                (list :title title
                      :keymap keymap
                      :legend-spec legend-spec
                      :source-state source-state
                      :source-window source-window
                      :source-buffer source-buffer
                      :buffer buffer
                      :window window
                      :last-width nil
                      :rendering nil)
                keymap-legend--window window
                keymap-legend--source-state source-state)
          (set-window-dedicated-p window t)
          (set-window-parameter window 'no-other-window t)
          (set-window-parameter window 'no-delete-other-windows t)
          (set-window-parameter source-window 'mode-line-format 'none)
          (set-window-parameter
           window 'mode-line-format
           (if (let ((format (plist-get source-state :mode-line-format)))
                 (and format (not (eq format 'none))))
               '(:eval (keymap-legend--source-mode-line))
             'none))
          ;; The side window exists before the first width-dependent render.
          (keymap-legend--render-state window t)
          (with-current-buffer buffer
            (add-hook 'window-size-change-functions
                      #'keymap-legend--window-size-change nil t))
          (when (window-live-p window)
            (fit-window-to-buffer window))
          (setq success t))
      (unless success
        (keymap-legend--cleanup t buffer window)))))

;;;###autoload
(defun keymap-legend-hide ()
  "Hide the current `KeymapLegend' and restore the source mode line."
  (keymap-legend--cleanup t))

(provide 'keymap-legend)
;;; keymap-legend.el ends here
