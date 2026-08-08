;;; ri-extend-test.el --- Tests for ri-extend.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri)

(defmacro ri-extend-test--with-buffer (text &rest body)
  "Run BODY in a temporary buffer containing TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defmacro ri-extend-test--with-json-buffer (text &rest body)
  "Run BODY in a temporary JSON buffer backed by tree-sitter."
  (declare (indent 1))
  `(ri-extend-test--with-buffer ,text
     (unless (and (treesit-available-p)
                  (treesit-language-available-p 'json))
       (ert-skip "JSON tree-sitter grammar unavailable"))
     (treesit-parser-create 'json)
     ,@body))

(defun ri-extend-test--highlighted-p (pos)
  "Return non-nil when POS has the semantic highlight face."
  (cl-some
   (lambda (overlay)
     (eq (overlay-get overlay 'face) 'sr-highlight-face))
   (overlays-at pos)))

(ert-deftest ri-extend-test-submode-switch-preserves-selection ()
  (ri-extend-test--with-buffer "foo bar baz\n"
    (dolist
        (case
         '((ri-extend-set-line-star-mode line-star)
           (ri-extend-set-line-mode line)
           (ri-extend-set-character-mode char)
           (ri-extend-set-word-mode word)
           (ri-extend-set-word-star-mode word-star)
           (ri-extend-set-word-plus-mode word-plus)
           (ri-extend-set-subword-mode subword)))
      (pcase-let ((`(,setter ,submode) case))
        (dolist (swap '(nil t))
          (goto-char 2)
          (setq sr-submode 'char)
          (should (ri--enter-extend))
          (let ((before (ri--selection-bounds)))
            (should (equal before (cons 2 3)))
            (when swap
              (ri-swap-cursor)
              (should (equal (ri--selection-bounds) before)))
            (funcall setter)
            (should (eq sr-submode submode))
            (should (ri--selection-active-p))
            (should (eq (ri--selection-state-active-edge ri--selection)
                        (if swap 'start 'end)))
            (should (equal (ri--selection-bounds) before)))
          (ri--exit-extend))))))

(ert-deftest ri-extend-test-line-to-word-after-swap-preserves-extend ()
  (ri-extend-test--with-buffer
      "zero alpha\nbeta gamma\ndelta epsilon\n"
    (goto-char 8)
    (setq sr-submode 'char)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (ri-extend-nav-down)
    (let ((extended-bounds (ri--selection-bounds)))
      (should (equal extended-bounds (cons 8 24)))
      (should
       (equal (buffer-substring-no-properties
               (car extended-bounds) (cdr extended-bounds))
              "pha\nbeta gamma\nd"))
      (ri-extend-set-line-mode)
      (should (equal (ri--selection-bounds) extended-bounds))
      (ri-swap-cursor)
      (should (equal (ri--selection-bounds) extended-bounds))
      (ri-extend-set-word-mode)
      (should (eq sr-submode 'word))
      (should (equal (ri--selection-bounds) extended-bounds))
      (ri-extend-nav-right)
      (should (equal (ri--selection-bounds) (cons 12 24)))
      (ri-smart-undo)
      (should (equal (ri--selection-bounds) extended-bounds)))
    (ri--exit-extend)))


(ert-deftest ri-extend-test-node-extends-across-named-siblings ()
  (ri-extend-test--with-json-buffer
      "[{\"x\": 123}, true, {\"y\": {}}]"
    (setq sr-submode 'char)
    (goto-char 2)
    (ri-extend-set-node-mode)
    (should (eq sr-submode 'node))
    (should (equal (sr--get-current-unit-bounds) (cons 2 12)))
    (should (ri--enter-extend))
    ;; Ki recipe: NODE, Extend, Right, Right, Left.
    (ri-extend-nav-right)
    (ri-extend-nav-right)
    (ri-extend-nav-left)
    (let ((bounds (ri--selection-bounds)))
      (should (equal (buffer-substring-no-properties
                      (car bounds) (cdr bounds))
                     "{\"x\": 123}, true"))
      (should (= (point) (1- (cdr bounds)))))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-normal-submode-switch-snaps-to-unit-start ()
  (ri-extend-test--with-buffer "  alpha beta\n"
    (dolist
        (case
         '((ri-extend-set-line-star-mode line-star 1 (1 . 13))
           (ri-extend-set-line-mode line 3 (3 . 13))
           (ri-extend-set-character-mode char 1 (1 . 2))
           (ri-extend-set-word-mode word 3 (3 . 8))
           (ri-extend-set-word-star-mode word-star 3 (3 . 8))
           (ri-extend-set-word-plus-mode word-plus 3 (3 . 8))
           (ri-extend-set-subword-mode subword 3 (3 . 8))))
      (pcase-let
          ((`(,setter ,submode ,expected-point ,expected-bounds) case))
        (goto-char (point-min))
        (setq sr-submode 'char)
        (funcall setter)
        (should (eq sr-submode submode))
        (should (= (point) expected-point))
        (should (equal (sr--get-current-unit-bounds)
                       expected-bounds))))))

(ert-deftest ri-extend-test-line-down-does-not-highlight-newline ()
  (ri-extend-test--with-buffer "foo\nbar\n"
    (setq sr-submode 'line)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (should (= (point) 7))
    (let ((bounds (ri--selection-bounds)))
      (should (equal bounds (cons 1 8)))
      (should (equal (buffer-substring-no-properties
                      (car bounds) (cdr bounds))
                     "foo\nbar"))
      (dolist (pos '(1 2 3 5 6 7))
        (should (ri-extend-test--highlighted-p pos)))
      (dolist (pos '(4 8))
        (should-not (ri-extend-test--highlighted-p pos))))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-line-to-word-keeps-newlines-unpainted ()
  (ri-extend-test--with-buffer "foo\nbar\nbaz\n"
    (setq sr-submode 'line)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (ri-extend-nav-down)
    (let ((line-bounds (ri--selection-bounds)))
      (should (equal line-bounds (cons 1 12)))
      (ri-extend-set-word-mode)
      (should (eq sr-submode 'word))
      (should (equal (ri--selection-bounds) line-bounds))
      (dolist (pos '(1 2 3 5 6 7 9 10 11))
        (should (ri-extend-test--highlighted-p pos)))
      (dolist (pos '(4 8 12))
        (should-not (ri-extend-test--highlighted-p pos))))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-swaps-normal-unit-cursor ()
  (ri-extend-test--with-buffer "foo bar"
    (setq sr-submode 'word)
    (ri-swap-cursor)
    (should (= (point) 3))
    (ri-swap-cursor)
    (should (= (point) 1))))

(ert-deftest ri-extend-test-registers-swap-cursor-binding ()
  (let ((mini-modal-map (make-sparse-keymap))
        (minor-mode-alist nil)
        (find-file-hook nil)
        (kkp-chord-after-release-hook nil)
        (sr-highlight-predicate nil)
        (status-frame-height 0))
    (cl-letf (((symbol-function 'modal-cursor-mode) #'ignore)
              ((symbol-function 'mini-modal-setup) #'ignore)
              ((symbol-function 'kkp-chord-mode) #'ignore)
              ((symbol-function 'global-kkp-mode) #'ignore)
              ((symbol-function 'ri-chord-setup) #'ignore)
              ((symbol-function 'buffer-list) (lambda () nil)))
      (ri-enable)
      (should (eq (lookup-key mini-modal-map "/")
                  #'ri-swap-cursor))
      (should (eq (lookup-key ri--normal-help-map "/")
                  #'ri-swap-cursor))
      (should (eq (lookup-key mini-modal-map "d")
                  #'ri-extend-set-node-mode))
      (should (eq (lookup-key ri--normal-help-map "d")
                  #'ri-extend-set-node-mode))
      (let ((sr-submode 'node))
        (should (equal (ri--submode-name) "NODE"))))))

(provide 'ri-extend-test)
;;; ri-extend-test.el ends here
