;;; ri-pairs-test.el --- Tests for RI smart pairs -*- lexical-binding: t; -*-

(require 'ert)
(require 'ri-pairs)

(defun ri-pairs-test--type (char)
  "Insert CHAR as if it were typed interactively."
  (let ((last-command-event char))
    (self-insert-command 1)))

(defmacro ri-pairs-test--with-buffer (&rest body)
  `(with-temp-buffer
     (emacs-lisp-mode)
     ;; Make braces a syntactic pair too, so the electric-pair tests do not
     ;; depend on the brace policy of the test major mode.
     (modify-syntax-entry ?\{ "(}" (syntax-table))
     (modify-syntax-entry ?\} "){" (syntax-table))
     (ri-pairs-insert-mode 1)
     (electric-pair-local-mode 1)
     ,@body))

(ert-deftest ri-pairs-inserts-parentheses ()
  (ri-pairs-test--with-buffer
   (ri-pairs-test--type ?\()
   (should (equal (buffer-string) "()"))
   (should (= (point) 2))))

(ert-deftest ri-pairs-inserts-braces ()
  (ri-pairs-test--with-buffer
   (ri-pairs-test--type ?\{)
   (should (equal (buffer-string) "{}"))
   (should (= (point) 2))))

(ert-deftest ri-pairs-overtypes-parenthesis ()
  (ri-pairs-test--with-buffer
   (ri-pairs-test--type ?\()
   (ri-pairs-test--type ?\))
   (should (equal (buffer-string) "()"))
   (should (= (point) 3))))

(ert-deftest ri-pairs-overtypes-brace ()
  (ri-pairs-test--with-buffer
   (ri-pairs-test--type ?\{)
   (ri-pairs-test--type ?\})
   (should (equal (buffer-string) "{}"))
   (should (= (point) 3))))

(ert-deftest ri-pairs-return-expands-braces ()
  (ri-pairs-test--with-buffer
   (insert "{}")
   (goto-char 2)
   (ri-pairs-return)
   (should (= (line-number-at-pos) 2))
   (should (= (char-after (save-excursion (forward-line 1) (point))) ?\}))
   (should (= (count-lines (point-min) (point-max)) 3))))

(ert-deftest ri-pairs-return-expands-parentheses ()
  (ri-pairs-test--with-buffer
   (insert "()")
   (goto-char 2)
   (ri-pairs-return)
   (should (= (line-number-at-pos) 2))
   (should (= (count-lines (point-min) (point-max)) 3))))

(ert-deftest ri-pairs-return-is-ordinary-outside-pair ()
  (ri-pairs-test--with-buffer
   (insert "foo")
   (ri-pairs-return)
   (should (equal (buffer-string) "foo\n"))))

(ert-deftest ri-pairs-return-does-not-expand-string-braces ()
  (ri-pairs-test--with-buffer
   (insert "\"{}\"")
   (goto-char 3)
   (should (eq (ri-pairs-context-at-point) 'string))
   (ri-pairs-return)
   (should (= (count-lines (point-min) (point-max)) 2))))

(ert-deftest ri-pairs-return-does-not-expand-comment-braces ()
  (ri-pairs-test--with-buffer
   (insert "; {}")
   (goto-char 4)
   (should (eq (ri-pairs-context-at-point) 'comment))
   (ri-pairs-return)
   (should (= (count-lines (point-min) (point-max)) 2))))

(ert-deftest ri-pairs-type-context-is-conservative ()
  (should-not (ri-pairs--smart-newline-allowed-p '(?\( . ?\)) 'type-context)))

(ert-deftest ri-pairs-argument-list-allows-parentheses-only ()
  (should (ri-pairs--smart-newline-allowed-p '(?\( . ?\)) 'argument-list))
  (should-not (ri-pairs--smart-newline-allowed-p '(?\{ . ?\}) 'argument-list)))

(ert-deftest ri-pairs-ambiguous-context-is-conservative ()
  (should-not (ri-pairs--smart-newline-allowed-p '(?\{ . ?\}) 'ambiguous)))

(ert-deftest ri-pairs-syncs-with-mini-modal-state ()
  (let ((mini-modal-mode t))
    (with-temp-buffer
      (emacs-lisp-mode)
      (setq-local mini-modal-mode t)
      (ri-pairs-enable-buffer)
      (should-not ri-pairs-insert-mode)
      (setq mini-modal-mode nil)
      (run-hooks 'mini-modal-mode-hook)
      (should ri-pairs-insert-mode)
      (setq mini-modal-mode t)
      (run-hooks 'mini-modal-mode-hook)
      (should-not ri-pairs-insert-mode))))

(ert-deftest ri-pairs-tree-sitter-classification-hook-is-extensible ()
  (when (and (featurep 'treesit) (treesit-available-p))
    ;; The adapter contract itself is tested without requiring a grammar.
    (let ((ri-pairs-tree-sitter-context-functions
           (list (lambda (_node) 'type-context))))
      (cl-letf (((symbol-function 'treesit-node-type) (lambda (_node) "x"))
                ((symbol-function 'treesit-node-parent) (lambda (_node) nil)))
        (should (eq (ri-pairs--classify-node 'fake-node) 'type-context))))))

(ert-deftest ri-pairs-odin-indentation-integration ()
  (unless (fboundp 'odin-mode)
    (ert-skip "odin-mode is not available"))
  (with-temp-buffer
    (odin-mode)
    (insert "main :: proc () {}")
    (goto-char (1- (point-max)))
    (ri-pairs-return)
    (should (= (count-lines (point-min) (point-max)) 3))
    (should (= (line-number-at-pos) 2))
    (should (> (current-indentation) 0))
    (save-excursion
      (forward-line 1)
      (back-to-indentation)
      (should (eq (char-after) ?\})))))

(provide 'ri-pairs-test)
;;; ri-pairs-test.el ends here
