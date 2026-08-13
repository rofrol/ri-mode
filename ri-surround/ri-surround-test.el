;;; ri-surround-test.el --- Tests for ri-surround -*- lexical-binding: t; -*-
(require 'ert)
(require 'ri)

(defmacro ri-surround-test--buffer (text &rest body)
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     (setq-local sr-submode 'char)
     ,@body))

(ert-deftest ri-surround-add-parens ()
  (ri-surround-test--buffer "foo"
    (goto-char 2)
    (ri-surround-add 'paren)
    (should (equal (buffer-string) "f(o)o"))))

(ert-deftest ri-surround-find-nested-pair ()
  (ri-surround-test--buffer "(a (b) c)"
    (search-forward "b")
    (should (equal (ri-surround--find-pair 'paren (cons (1- (point)) (point)))
                   '(4 . 6)))))

(ert-deftest ri-surround-delete-parens ()
  (ri-surround-test--buffer "(foo)"
    (search-forward "o")
    (ri-surround-delete 'paren)
    (should (equal (buffer-string) "foo"))))

(ert-deftest ri-surround-change-parens-to-braces ()
  (ri-surround-test--buffer "(foo)"
    (search-forward "o")
    (ri-surround-change 'paren 'brace)
    (should (equal (buffer-string) "{foo}"))))

(ert-deftest ri-surround-select-inside-exact ()
  (ri-surround-test--buffer "xx(foo)yy"
    (search-forward "foo")
    (ri-surround-select-inside 'paren)
    (should (ri--selection-active-p))
    (should (equal (ri--selection-bounds) '(4 . 7)))))

(ert-deftest ri-surround-select-around-exact ()
  (ri-surround-test--buffer "xx(foo)yy"
    (search-forward "foo")
    (ri-surround-select-around 'paren)
    (should (ri--selection-active-p))
    (should (equal (ri--selection-bounds) '(3 . 8)))))

(ert-deftest ri-surround-square-key-is-comma ()
  (should (eq (lookup-key ri--surround-add-map ",")
              'ri--surround-add-bracket)))


(ert-deftest ri-surround-find-escaped-double-quote ()
  (ri-surround-test--buffer "\"foo \\\"bar\\\" baz\""
    (search-forward "bar")
    (should (equal (ri-surround--find-pair 'double
                                           (cons (- (point) 3) (point)))
                   '(1 . 17)))))

(ert-deftest ri-surround-add-map-has-xml-tag-command ()
  (should (eq (lookup-key ri--surround-add-map ";")
              'ri-surround-add-tag-menu-command)))

(provide 'ri-surround-test)
;;; ri-surround-test.el ends here
