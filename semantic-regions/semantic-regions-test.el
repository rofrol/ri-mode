;;; semantic-regions-test.el --- Tests for semantic-regions.el -*- lexical-binding: t; -*-

;; The first battery exercises the shared LINE/CHAR region API:
;; parsing, navigation, extension, unit changes, and buffer interaction.
;;
;; The second battery protects the ri-mode integration.  LINE and CHAR
;; use the shared API; LINE*, WORD, WORD+, WORD*, and SUBWORD retain
;; their existing bounds behavior.  A frozen copy of the old bounds
;; implementation remains below as the regression oracle.

(require 'ert)
(require 'subword)
(require 'semantic-regions)

(defmacro semantic-region-test--with-buffer (text &rest body)
  "Run BODY in a temp buffer with TEXT already inserted, point at start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

;;; parse-at: construction is always valid --------------------------------

(ert-deftest semantic-region-test-parse-line ()
  (semantic-region-test--with-buffer "  foo bar  \n"
    (let ((r (semantic-region-parse-at 'line 1)))
      (should r)
      (should (eq (semantic-region-unit r) 'line))
      (should (equal (semantic-region-string r) "foo bar")))))

(ert-deftest semantic-region-test-parse-char ()
  (semantic-region-test--with-buffer "abc"
    (let ((r (semantic-region-parse-at 'char 2)))
      (should r)
      (should (equal (semantic-region-string r) "b"))
      (should (= (semantic-region-length r) 1)))))

(ert-deftest semantic-region-test-parse-empty-char-is-zero-width ()
  (semantic-region-test--with-buffer ""
    (let ((r (semantic-region-parse-at 'char 1)))
      (should r)
      (should (= (semantic-region-beg r) (point-min)))
      (should (= (semantic-region-end r) (point-min)))
      (should (semantic-region-empty-p r)))))

(ert-deftest semantic-region-test-parse-unknown-unit-errors ()
  (semantic-region-test--with-buffer "foo"
    (should-error (semantic-region-parse-at 'word 1))
    (should-error (semantic-region-parse-at 'line-star 1))
    (should-error (semantic-region-parse-at 'not-a-real-unit 1))))

;; Every region ever produced must satisfy beg <= end and buffer bounds;
;; since there is no public raw constructor, this is really testing that
;; `semantic-region--build' is the only path and that path is sound.
(ert-deftest semantic-region-test-always-well-formed ()
  (semantic-region-test--with-buffer "foo bar\nbaz qux\n"
    (dolist (unit '(line char))
      (dolist (pos (list (point-min) 5 (point-max)))
        (let ((r (semantic-region-parse-at unit pos)))
          (should (<= (semantic-region-beg r) (semantic-region-end r)))
          (should (<= (point-min) (semantic-region-beg r)))
          (should (<= (semantic-region-end r) (point-max))))))))

;;; next / prev -------------------------------------------------------------

(ert-deftest semantic-region-test-next-line ()
  (semantic-region-test--with-buffer "one\ntwo\nthree\n"
    (let* ((l1 (semantic-region-parse-at 'line 1))
           (l2 (semantic-region-next l1))
           (l3 (semantic-region-next l2)))
      (should (equal (semantic-region-string l1) "one"))
      (should (equal (semantic-region-string l2) "two"))
      (should (equal (semantic-region-string l3) "three"))
      (should (null (semantic-region-next l3))))))

(ert-deftest semantic-region-test-next-char ()
  (semantic-region-test--with-buffer "abc"
    (let* ((c1 (semantic-region-parse-at 'char 1))
           (c2 (semantic-region-next c1))
           (c3 (semantic-region-next c2)))
      (should (equal (semantic-region-string c1) "a"))
      (should (equal (semantic-region-string c2) "b"))
      (should (equal (semantic-region-string c3) "c"))
      (should (null (semantic-region-next c3))))))

(ert-deftest semantic-region-test-prev-line ()
  (semantic-region-test--with-buffer "one\ntwo\nthree\n"
    (let* ((l3 (semantic-region-parse-at 'line 9))
           (l2 (semantic-region-prev l3))
           (l1 (semantic-region-prev l2)))
      (should (equal (semantic-region-string l3) "three"))
      (should (equal (semantic-region-string l2) "two"))
      (should (equal (semantic-region-string l1) "one"))
      (should (null (semantic-region-prev l1))))))

(ert-deftest semantic-region-test-prev-char ()
  (semantic-region-test--with-buffer "abc"
    (let* ((c3 (semantic-region-parse-at 'char 3))
           (c2 (semantic-region-prev c3))
           (c1 (semantic-region-prev c2)))
      (should (equal (semantic-region-string c3) "c"))
      (should (equal (semantic-region-string c2) "b"))
      (should (equal (semantic-region-string c1) "a"))
      (should (null (semantic-region-prev c1))))))

;;; extend-next / extend-prev: shared by LINE and CHAR ----------------------

(ert-deftest semantic-region-test-extend-next-line ()
  (semantic-region-test--with-buffer "one\ntwo\nthree\n"
    (let* ((r (semantic-region-parse-at 'line 1))
           (extended (semantic-region-extend-next r)))
      (should (equal (semantic-region-string extended) "one\ntwo")))))

(ert-deftest semantic-region-test-extend-next-at-end-is-noop ()
  (semantic-region-test--with-buffer "foo"
    (let* ((r (semantic-region-parse-at 'char 3))
           (extended (semantic-region-extend-next r)))
      (should (equal (semantic-region-string extended) "o")))))

(ert-deftest semantic-region-test-extend-prev-line-and-char ()
  (semantic-region-test--with-buffer "one\nabc"
    (let* ((line (semantic-region-parse-at 'line 5))
           (char (semantic-region-parse-at 'char 7)))
      (should (equal (semantic-region-string (semantic-region-extend-prev line))
                     "one\nabc"))
      (should (equal (semantic-region-string (semantic-region-extend-prev char))
                     "bc")))))

;;; change-unit: the shared LINE <-> CHAR operation -------------------------

(ert-deftest semantic-region-test-change-unit-line-to-char ()
  (semantic-region-test--with-buffer "foo bar\nbaz qux\n"
    (let* ((line (semantic-region-parse-at 'line 1))
           (char (semantic-region-change-unit line 'char)))
      (should (equal (semantic-region-string line) "foo bar"))
      (should (eq (semantic-region-unit char) 'char))
      (should (equal (semantic-region-string char) "f")))))

(ert-deftest semantic-region-test-change-unit-char-to-line ()
  (semantic-region-test--with-buffer "foo bar\nbaz qux\n"
    (let* ((char (semantic-region-parse-at 'char 5))
           (line (semantic-region-change-unit char 'line)))
      (should (eq (semantic-region-unit line) 'line))
      (should (equal (semantic-region-string line) "foo bar")))))

(ert-deftest semantic-region-test-change-unit-same-operations-line-char ()
  "The same operations work after changing only the unit."
  (semantic-region-test--with-buffer "aaa\nbbb\n"
    (let* ((line (semantic-region-parse-at 'line 1))
           (char (semantic-region-change-unit line 'char)))
      (should (equal (semantic-region-string (semantic-region-next line))
                     "bbb"))
      (should (equal (semantic-region-string (semantic-region-next char))
                     "a"))
      (should (equal (semantic-region-string (semantic-region-extend-next line))
                     "aaa\nbbb"))
      (should (equal (semantic-region-string (semantic-region-extend-next char))
                     "aa")))))

;;; select / string / length / empty-p / delete -----------------------------

(ert-deftest semantic-region-test-select-sets-point-and-mark ()
  (semantic-region-test--with-buffer "foo bar baz"
    (let ((r (semantic-region-parse-at 'char 5)))
      (semantic-region-select r)
      (should (= (point) (semantic-region-end r)))
      (should (= (mark) (semantic-region-beg r))))))

(ert-deftest semantic-region-test-length-and-empty-p ()
  (semantic-region-test--with-buffer "foo bar"
    (let ((r (semantic-region-parse-at 'char 1)))
      (should (= (semantic-region-length r) 1))
      (should-not (semantic-region-empty-p r)))))

(ert-deftest semantic-region-test-delete ()
  (semantic-region-test--with-buffer "foo bar baz"
    (let ((r (semantic-region-parse-at 'char 5)))
      (semantic-region-delete r)
      (should (equal (buffer-string) "foo ar baz")))))

;;; Integration regression tests --------------------------------------------
;; The shared engine is intentionally limited to LINE and CHAR.

;;; Frozen oracle: verbatim copy of the pre-integration implementation ----

(defun sr-test--old-subword-bounds-at (pos)
  (save-excursion
    (goto-char pos)
    (let ((bounds (bounds-of-thing-at-point 'word)))
      (if bounds
          bounds
        (let ((end (progn (subword-forward 1) (point))))
          (subword-backward 1)
          (cons (point) end))))))

(defun sr-test--old-unit-bounds-at (pos submode)
  (save-excursion
    (goto-char pos)
    (pcase submode
      ('line
       (save-excursion
         (let ((bol (line-beginning-position))
               (eol (line-end-position)))
           (goto-char bol)
           (skip-chars-forward " \t" eol)
           (let ((s (point)))
             (goto-char eol)
             (skip-chars-backward " \t" bol)
             (let ((e (point)))
               (if (> e s) (cons s e) (cons s s)))))))
      ('line-star
       (cons (line-beginning-position) (line-end-position)))
      ('char
       (cons pos (min (1+ pos) (point-max))))
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
       (sr-test--old-subword-bounds-at pos)))))

;;; Fixtures ------------------------------------------------------------

(defconst sr-test--fixtures
  (list
   "foo bar baz"
   "  leading and trailing spaces  "
   "foo_bar-baz qux123"
   "one\ntwo\nthree\n"
   "\n\nblank lines\n\n\nmore\n"
   "   \n\t\n   "
   "camelCaseWord anotherCamelCase snake_case kebab-case"
   "punct!@#$%^&*() mixed, with; symbols."
   ""
   "x"
   "single-line-no-newline-at-end")
  "Buffers exercised by the parity tests below.")

(defconst sr-test--submodes
  '(line line-star char word word-plus word-star subword))

;;; Parity: every position, every submode, every fixture ------------------

(ert-deftest sr-test-unit-bounds-at-matches-old-implementation ()
  "The old and new bounds implementations agree for every submode."
  (dolist (text sr-test--fixtures)
    (with-temp-buffer
      (insert text)
      (dolist (submode sr-test--submodes)
        (let ((sr-submode submode))
          (cl-loop for pos from (point-min) to (point-max) do
                   (let ((old (sr-test--old-unit-bounds-at pos submode))
                         (new (sr--unit-bounds-at pos submode)))
                     (should (equal old new)))))))))

;;; Sanity checks on a few known cases (documents intended behavior) ------

(ert-deftest sr-test-line-trims-whitespace ()
  (with-temp-buffer
    (insert "  hello world  \n")
    (should (equal (sr--unit-bounds-at 1 'line) (cons 3 14)))))

(ert-deftest sr-test-line-star-keeps-whitespace ()
  (with-temp-buffer
    (insert "  hello world  \n")
    (should (equal (sr--unit-bounds-at 1 'line-star) (cons 1 16)))))

(ert-deftest sr-test-word-and-word-plus-share-bounds ()
  (with-temp-buffer
    (insert "foo bar")
    (should (equal (sr--unit-bounds-at 1 'word) (sr--unit-bounds-at 1 'word-plus)))))

(ert-deftest sr-test-word-star-spans-punctuation ()
  (with-temp-buffer
    (insert "foo-bar.baz qux")
    ;; WORD* is a maximal *non-whitespace* run, so punctuation doesn't split it.
    (should (equal (sr--unit-bounds-at 1 'word-star) (cons 1 12)))))

(ert-deftest sr-test-char-is-single-character ()
  (with-temp-buffer
    (insert "abc")
    (should (equal (sr--unit-bounds-at 2 'char) (cons 2 3)))))

(ert-deftest sr-test-subword-falls-back-to-whole-word-without-subword-mode ()
  "Document actual behavior: `sr--subword-bounds-at' tries
`bounds-of-thing-at-point' 'word first, which is *not* camelCase-aware
unless the buffer-local `subword-mode' minor mode is active (it
rebinds `forward-word'/`backward-word', which `bounds-of-thing-at-point'
uses internally).  Nothing in this project turns `subword-mode' on, so
in practice SUBWORD currently behaves like WORD's syntactic bounds for
a plain buffer.  Verified identical to the pre-integration behavior by
`sr-test-unit-bounds-at-matches-old-implementation' -- this is a
pre-existing property of the old code, not something the
`semantic-region.el' integration changed."
  (with-temp-buffer
    (insert "camelCase")
    (should (equal (sr--unit-bounds-at 1 'subword) (cons 1 10)))
    ;; Enabling `subword-mode' does make it camelCase-aware.
    (subword-mode 1)
    (should (equal (sr--unit-bounds-at 1 'subword) (cons 1 6)))    ; "camel"
    (should (equal (sr--unit-bounds-at 6 'subword) (cons 6 10))))) ; "Case"

(ert-deftest sr-test-empty-buffer-returns-nil ()
  (with-temp-buffer
    (dolist (submode sr-test--submodes)
      ;; `line'/`line-star'/`char' always have *some* zero-width bounds
      ;; on an empty buffer; only word-ish submodes return nil at eobp.
      (when (memq submode '(word word-plus word-star))
        (should (null (sr--unit-bounds-at 1 submode)))))))

(provide 'semantic-regions-test)
;;; semantic-regions-test.el ends here
