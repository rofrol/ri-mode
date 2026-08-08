;;; ri-extend-test.el --- Tests for ri-extend.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'ri-extend)

(defmacro ri-extend-test--with-buffer (text &rest body)
  "Run BODY in a temporary buffer containing TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(ert-deftest ri-extend-test-switches-from-char-to-word ()
  (ri-extend-test--with-buffer "foo bar baz"
    (dolist (case '((nil end 1 4 "foo")
                    (t start 1 2 "f")))
      (pcase-let ((`(,flip ,edge ,beg ,end ,text) case))
        (goto-char (point-min))
        (setq sr-submode 'char)
        (should (ri--enter-extend))
        (when flip
          (ri-flip-selection))
        (ri-extend-set-word-mode)
        (should (eq sr-submode 'word))
        (should (ri--selection-active-p))
        (should (eq (ri--selection-state-active-edge ri--selection) edge))
        (let ((bounds (ri--selection-bounds)))
          (should (equal bounds (cons beg end)))
          (should (equal (buffer-substring-no-properties
                          (car bounds) (cdr bounds))
                         text)))
        (ri--exit-extend)))))

(provide 'ri-extend-test)
;;; ri-extend-test.el ends here
