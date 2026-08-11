;;; semantic-regions-test.el --- Tests for semantic-regions.el -*- lexical-binding: t; -*-

;; The first battery exercises the shared semantic-region API for every
;; supported unit: parsing, navigation, extension, unit changes, and
;; buffer interaction.
;;
;; The second battery verifies that every submode preserves its bounds
;; behavior while using the shared engine.  A frozen copy of the old
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

(defmacro semantic-region-test--with-json-buffer (text &rest body)
  "Run BODY in a temporary JSON buffer backed by tree-sitter."
  (declare (indent 1))
  `(semantic-region-test--with-buffer ,text
     (unless (and (treesit-available-p)
                  (treesit-language-available-p 'json))
       (ert-skip "JSON tree-sitter grammar unavailable"))
     (treesit-parser-create 'json)
     ,@body))

(defun semantic-region-test--highlighted-p (pos)
  "Return non-nil when POS has the semantic highlight face."
  (cl-some
   (lambda (overlay)
     (eq (overlay-get overlay 'face) 'sr-highlight-face))
   (overlays-at pos)))

(defconst semantic-region-test--units
  '(line line-star paragraph char word word-plus word-star subword node)
  "Units supported by the shared semantic-region API.")

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

(ert-deftest semantic-region-test-parse-other-units ()
  (semantic-region-test--with-buffer "  alpha beta  \n"
    (dolist (case '((line-star 1 "  alpha beta  ")
                    (word 3 "alpha")
                    (word-plus 3 "alpha")
                    (word-star 3 "alpha")
                    (subword 3 "alpha")))
      (pcase-let ((`(,unit ,pos ,expected) case))
        (let ((region (semantic-region-parse-at unit pos)))
          (should region)
          (should (eq (semantic-region-unit region) unit))
          (should (equal (semantic-region-string region) expected)))))))

(ert-deftest semantic-region-test-parse-paragraph-matches-ki ()
  (semantic-region-test--with-buffer "foo\nbar\n\n \t\nbaz\nqux"
    (let ((first (semantic-region-parse-at 'paragraph 1))
          (empty (semantic-region-parse-at 'paragraph 9))
          (whitespace (semantic-region-parse-at 'paragraph 11))
          (second (semantic-region-parse-at 'paragraph (point-max))))
      (should (equal (semantic-region-string first) "foo\nbar\n"))
      (should (equal (cons (semantic-region-beg first)
                           (semantic-region-end first))
                     (cons 1 9)))
      (should (semantic-region-empty-p empty))
      (should (= (semantic-region-beg empty) 9))
      (should (semantic-region-empty-p whitespace))
      (should (= (semantic-region-beg whitespace) 10))
      (should (equal (semantic-region-string second) "baz\nqux")))))

(ert-deftest semantic-region-test-parse-empty-paragraph-returns-nil ()
  (semantic-region-test--with-buffer ""
    (should-not (semantic-region-parse-at 'paragraph (point-min)))))

(ert-deftest semantic-region-test-parse-empty-word-units-return-nil ()
  (semantic-region-test--with-buffer ""
    (dolist (unit '(word word-plus word-star))
      (should-not (semantic-region-parse-at unit (point-min))))))

(ert-deftest semantic-region-test-parse-empty-char-is-zero-width ()
  (semantic-region-test--with-buffer ""
    (let ((r (semantic-region-parse-at 'char 1)))
      (should r)
      (should (= (semantic-region-beg r) (point-min)))
      (should (= (semantic-region-end r) (point-min)))
      (should (semantic-region-empty-p r)))))

(ert-deftest semantic-region-test-parse-unknown-unit-errors ()
  (semantic-region-test--with-buffer "foo"
    (should-error (semantic-region-parse-at 'not-a-real-unit 1))))

;; Every region ever produced must satisfy beg <= end and buffer bounds;
;; since there is no public raw constructor, this is really testing that
;; `semantic-region--build' is the only path and that path is sound.
(ert-deftest semantic-region-test-always-well-formed ()
  (semantic-region-test--with-buffer "foo bar\nbaz qux\n"
    (dolist (unit semantic-region-test--units)
      (dolist (pos (list (point-min) 5 (point-max)))
        (when-let* ((region (semantic-region-parse-at unit pos)))
          (should (<= (semantic-region-beg region)
                      (semantic-region-end region)))
          (should (<= (point-min) (semantic-region-beg region)))
          (should (<= (semantic-region-end region) (point-max))))))))

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

(ert-deftest semantic-region-test-next-prev-line-units-include-blank-line ()
  (semantic-region-test--with-buffer "one\n   \ntwo"
    (dolist (case '((line "") (line-star "   ")))
      (pcase-let ((`(,unit ,blank-text) case))
        (let* ((one (semantic-region-parse-at unit 1))
               (blank (semantic-region-next one))
               (two (semantic-region-next blank)))
          (should (equal (semantic-region-string blank) blank-text))
          (should (equal (semantic-region-string two) "two"))
          (should (equal
                   (semantic-region-string (semantic-region-prev two))
                   blank-text)))))))

(ert-deftest semantic-region-test-next-prev-paragraph-skip-empty-lines ()
  (semantic-region-test--with-buffer "foo\nbar\n\n \t\nbaz\nqux"
    (let* ((first (semantic-region-parse-at 'paragraph 1))
           (second (semantic-region-next first))
           (extended (semantic-region-extend-next first)))
      (should (equal (semantic-region-string second) "baz\nqux"))
      (should (eq (semantic-region-unit second) 'paragraph))
      (should (equal (semantic-region-string (semantic-region-prev second))
                     "foo\nbar\n"))
      (should (equal (semantic-region-string extended)
                     (buffer-string)))
      (should-not (semantic-region-next second))
      (should-not (semantic-region-prev first)))))

(ert-deftest semantic-region-test-next-prev-wordish-units ()
  (semantic-region-test--with-buffer "foo + bar"
    (dolist (case '((word "bar")
                    (word-plus "+")
                    (word-star "+")
                    (subword "bar")))
      (pcase-let ((`(,unit ,next-text) case))
        (let* ((current (semantic-region-parse-at unit 1))
               (next (semantic-region-next current))
               (prev (semantic-region-prev next)))
          (should (eq (semantic-region-unit next) unit))
          (should (equal (semantic-region-string next) next-text))
          (should (equal (semantic-region-string prev) "foo")))))))

(ert-deftest semantic-region-test-next-prev-subword-camel-case ()
  (semantic-region-test--with-buffer "camelCase tail"
    (subword-mode 1)
    (let* ((camel (semantic-region-parse-at 'subword 1))
           (case (semantic-region-next camel))
           (tail (semantic-region-next case)))
      (should (equal (semantic-region-string camel) "camel"))
      (should (equal (semantic-region-string case) "Case"))
      (should (equal (semantic-region-string tail) "tail"))
      (should (equal
               (semantic-region-string (semantic-region-prev case))
               "camel")))))

;;; extend-next / extend-prev: shared by every unit -------------------------

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

(ert-deftest semantic-region-test-extend-next-wordish-units ()
  (semantic-region-test--with-buffer "foo + bar"
    (dolist (case '((word "foo + bar")
                    (word-plus "foo +")
                    (word-star "foo +")
                    (subword "foo + bar")))
      (pcase-let ((`(,unit ,expected) case))
        (let* ((region (semantic-region-parse-at unit 1))
               (extended (semantic-region-extend-next region)))
          (should (equal (semantic-region-string extended) expected)))))))

;;; change-unit: shared by every unit ---------------------------------------

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

(ert-deftest semantic-region-test-change-unit-supports-every-unit ()
  (semantic-region-test--with-buffer "  foo bar  \n"
    (let ((source (semantic-region-parse-at 'char 3)))
      (dolist (case '((line "foo bar")
                      (line-star "  foo bar  ")
                      (paragraph "  foo bar  \n")
                      (char "f")
                      (word "foo")
                      (word-plus "foo")
                      (word-star "foo")
                      (subword "foo")))
        (pcase-let ((`(,unit ,expected) case))
          (let ((changed (semantic-region-change-unit source unit)))
            (should (eq (semantic-region-unit changed) unit))
            (should (equal (semantic-region-string changed) expected))))))))

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

(ert-deftest semantic-region-test-subword-right-skips-symbol-separator ()
  (semantic-region-test--with-buffer "Unit-based"
    (setq sr-submode 'subword)
    (sr-nav-right)
    (should (= (point) 6))
    (should (equal (sr--get-current-unit-bounds) (cons 6 11)))
    (dolist (pos '(1 2 3 4 5))
      (should-not (semantic-region-test--highlighted-p pos)))
    (dolist (pos '(6 7 8 9 10))
      (should (semantic-region-test--highlighted-p pos)))))


(ert-deftest semantic-region-test-subword-vertical-skips-symbol-only-lines ()
  (semantic-region-test--with-buffer
      ";; deleting regions while retaining its unit-specific bounds.\n;;\n;;; Code:\n"
    (search-forward "Code")
    (goto-char (match-beginning 0))
    (setq sr-submode 'subword)
    (sr-nav-up)
    (should (= (line-number-at-pos) 1))
    (should (equal (buffer-substring-no-properties
                    (car (sr--get-current-unit-bounds))
                    (cdr (sr--get-current-unit-bounds)))
                   "deleting"))
    (sr-nav-down)
    (should (= (line-number-at-pos) 3))
    (should (equal (buffer-substring-no-properties
                    (car (sr--get-current-unit-bounds))
                    (cdr (sr--get-current-unit-bounds)))
                   "Code"))))

(ert-deftest semantic-region-test-wordish-vertical-skips-leading-whitespace ()
  (semantic-region-test--with-buffer "  alpha\n  beta\n"
    (dolist (submode '(word word-plus word-star subword))
      (goto-char 11)
      (setq sr-submode submode)
      (sr-nav-up)
      (should (= (point) 3))
      (should (equal (semantic-region-string
                      (semantic-region-parse-at submode (point)))
                     "alpha"))
      (sr-nav-down)
      (should (= (point) 11))
      (should (equal (semantic-region-string
                      (semantic-region-parse-at submode (point)))
                     "beta")))))

(ert-deftest semantic-region-test-paragraph-navigation-matches-ki ()
  (semantic-region-test--with-buffer "foo\n\n\nbar\n\nbaz"
    (setq sr-submode 'paragraph)
    (sr-nav-next)
    (should (= (line-number-at-pos) 2))
    (should (semantic-region-empty-p
             (semantic-region-parse-at 'paragraph (point))))
    (sr-nav-next)
    (should (= (line-number-at-pos) 3))
    (sr-nav-next)
    (should (equal
             (semantic-region-string
              (semantic-region-parse-at 'paragraph (point)))
             "bar\n"))
    (sr-nav-prev)
    (should (= (line-number-at-pos) 3))
    (sr-nav-left)
    (should (equal
             (semantic-region-string
              (semantic-region-parse-at 'paragraph (point)))
             "foo\n"))
    (sr-nav-right)
    (should (equal
             (semantic-region-string
              (semantic-region-parse-at 'paragraph (point)))
             "bar\n"))
    (sr-nav-last)
    (should (equal
             (semantic-region-string
              (semantic-region-parse-at 'paragraph (point)))
             "baz"))
    (sr-nav-first)
    (should (equal
             (semantic-region-string
              (semantic-region-parse-at 'paragraph (point)))
             "foo\n"))))

(ert-deftest semantic-region-test-paragraph-first-last-skip-edge-separators ()
  (semantic-region-test--with-buffer "\nfoo\n\nbar\n\n"
    (setq sr-submode 'paragraph)
    (sr-nav-last)
    (should (equal
             (semantic-region-string
              (semantic-region-parse-at 'paragraph (point)))
             "bar\n"))
    (sr-nav-first)
    (should (equal
             (semantic-region-string
              (semantic-region-parse-at 'paragraph (point)))
             "foo\n"))))

;;; NODE -------------------------------------------------------------------

(ert-deftest semantic-region-test-node-without-parser-is-unavailable ()
  (semantic-region-test--with-buffer "plain text"
    (should-not (semantic-region-parse-at 'node (point-min)))))

(ert-deftest semantic-region-test-node-mode-requires-tree-sitter-parser ()
  (semantic-region-test--with-buffer "plain text"
    (should-error (sr-set-node-mode) :type 'user-error)
    (should (eq sr-submode 'line))))

(ert-deftest semantic-region-test-node-mode-creates-configured-parser ()
  (semantic-region-test--with-buffer "[{\"x\": 1}]"
    (unless (and (treesit-available-p)
                 (treesit-language-available-p 'json))
      (ert-skip "JSON tree-sitter grammar unavailable"))
    (let ((sr-node-language-alist '((fundamental-mode . json))))
      (goto-char 2)
      (should-not (treesit-parser-list))
      (sr-set-node-mode)
      (should (eq sr-submode 'node))
      (should (equal
               (mapcar #'treesit-parser-language (treesit-parser-list))
               '(json)))
      (should (equal (semantic-region-string
                      (semantic-region-parse-at 'node (point)))
                     "{\"x\": 1}")))))


(ert-deftest semantic-region-test-node-navigation-matches-ki ()
  (semantic-region-test--with-json-buffer
      "[{\"x\": 123}, true, {\"y\": {}}]"
    (setq sr-submode 'node)
    (goto-char 2)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "{\"x\": 123}"))
    ;; Left/Right traverse named siblings.
    (sr-nav-right)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "true"))
    (sr-nav-left)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "{\"x\": 123}"))
    ;; Previous/Next include anonymous punctuation siblings.
    (sr-nav-next)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   ","))
    (sr-nav-next)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "true"))
    ;; First/Last use named siblings; Up/Down use parent/first named child.
    (sr-nav-last)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "{\"y\": {}}"))
    (sr-nav-first)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "{\"x\": 123}"))
    (sr-nav-up)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "[{\"x\": 123}, true, {\"y\": {}}]"))
    (sr-nav-down)
    (should (equal (semantic-region-string
                    (semantic-region-parse-at 'node (point)))
                   "{\"x\": 123}"))))

(ert-deftest semantic-region-test-parent-line-requires-tree-sitter ()
  (semantic-region-test--with-buffer "plain text"
    (let ((sr-node-language-alist nil))
      (let ((error-data
             (should-error (sr-nav-parent-line) :type 'user-error)))
        (should
         (string-match-p
          "\\`Parent Line requires"
          (error-message-string error-data)))))))

(ert-deftest semantic-region-test-parent-line-matches-ki-hierarchy ()
  (semantic-region-test--with-buffer
      "fn outer() {\n  fn inner() {\n    same-column\n    call();\n  }\n}\n"
    (let* ((outer (point-min))
           (inner
            (save-excursion
              (forward-line 1)
              (back-to-indentation)
              (point)))
           (same-column
            (save-excursion
              (forward-line 2)
              (back-to-indentation)
              (point)))
           (call
            (save-excursion
              (forward-line 3)
              (back-to-indentation)
              (point)))
           (nodes
            `((call-leaf ,call ,(1+ call) call-wrapper)
              (call-wrapper ,call ,(1+ call) same-column-node)
              (same-column-node ,same-column ,call inner-node)
              (inner-leaf ,inner ,(1+ inner) inner-wrapper)
              (inner-wrapper ,inner ,(1+ inner) inner-node)
              (inner-node ,inner ,same-column outer-node)
              (outer-leaf ,outer ,(1+ outer) outer-wrapper)
              (outer-wrapper ,outer ,(1+ outer) outer-node)
              (outer-node ,outer ,(1- (point-max)) root)
              (root ,outer ,(point-max) nil))))
      (cl-letf
          (((symbol-function 'sr--require-node-parser)
            (lambda (&optional _feature) 'fake))
           ((symbol-function 'sr--ensure-node-parser)
            (lambda (_position) 'fake))
           ((symbol-function 'treesit-node-at)
            (lambda (position &optional _parser-or-language _named)
              (cond
               ((= position call) 'call-leaf)
               ((= position inner) 'inner-leaf)
               (t 'outer-leaf))))
           ((symbol-function 'treesit-node-parser)
            (lambda (_node) 'fake-parser))
           ((symbol-function 'treesit-parser-root-node)
            (lambda (_parser) 'root))
           ((symbol-function 'treesit-node-descendant-for-range)
            (lambda (_root beginning _end &optional _named)
              (cond
               ((= beginning call) 'call-leaf)
               ((= beginning inner) 'inner-leaf)
               (t 'outer-leaf))))
           ((symbol-function 'treesit-node-start)
            (lambda (node) (nth 1 (assq node nodes))))
           ((symbol-function 'treesit-node-end)
            (lambda (node) (nth 2 (assq node nodes))))
           ((symbol-function 'treesit-node-parent)
            (lambda (node) (nth 3 (assq node nodes)))))
        (setq sr-submode 'line)
        (goto-char call)
        (sr-nav-parent-line)
        (should (= (point) inner))
        (should
         (equal
          (semantic-region-string
           (semantic-region-parse-at 'line (point)))
          "fn inner() {"))
        (sr-nav-parent-line)
        (should (= (point) outer))
        (should
         (equal
          (semantic-region-string
           (semantic-region-parse-at 'line (point)))
          "fn outer() {"))
        (sr-nav-parent-line)
        (should (= (point) outer))))))


(ert-deftest semantic-region-test-node-api-traverses-named-siblings ()
  (semantic-region-test--with-json-buffer
      "[{\"x\": 123}, true]"
    (let* ((object (semantic-region-parse-at 'node 2))
           (boolean (semantic-region-next object)))
      (should (eq (semantic-region-unit object) 'node))
      (should (equal (semantic-region-string boolean) "true"))
      (should (equal (semantic-region-string
                      (semantic-region-prev boolean))
                     "{\"x\": 123}"))
      (should (equal (semantic-region-string
                      (semantic-region-extend-next object))
                     "{\"x\": 123}, true")))))

;;; Bounds compatibility regression tests ----------------------------------

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

(ert-deftest sr-test-empty-buffer-has-no-paragraph ()
  (with-temp-buffer
    (should-not (sr--unit-bounds-at (point-min) 'paragraph))))

(ert-deftest semantic-region-test-highlight-provider-splits-multiline-range ()
  (semantic-region-test--with-buffer "foo\nbar\n"
    (let ((sr-highlight-bounds-function (lambda () (cons 1 8))))
      (sr--update-highlight)
      (dolist (pos '(1 2 3 5 6 7))
        (should (semantic-region-test--highlighted-p pos)))
      (dolist (pos '(4 8))
        (should-not (semantic-region-test--highlighted-p pos))))))

(ert-deftest semantic-region-test-single-newline-unit-remains-visible ()
  (semantic-region-test--with-buffer "\n"
    (let ((sr-highlight-bounds-function (lambda () (cons 1 2))))
      (sr--update-highlight)
      (should (semantic-region-test--highlighted-p 1)))))

(provide 'semantic-regions-test)
;;; semantic-regions-test.el ends here
