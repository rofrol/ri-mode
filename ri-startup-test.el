;;; ri-startup-test.el --- Ri startup regression tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri)

(ert-deftest ri-startup-test-fresh-load-keeps-lsp-lazy ()
  (let ((output (generate-new-buffer " *ri-startup-test-child*")))
    (unwind-protect
        (let ((emacs (expand-file-name invocation-name invocation-directory))
              (kkp-dir (file-name-directory
                        (or (locate-library "kkp")
                            (ert-fail "Cannot locate kkp.el"))))
              (root (file-name-directory
                     (or (locate-library "ri")
                         (ert-fail "Cannot locate ri.el")))))
          (should
           (equal
            (call-process
             emacs nil output nil
             "-Q" "--batch" "-L" kkp-dir "-L" root
             "--eval"
             "(progn (require 'ri) (princ (list (featurep 'ri-lsp) (featurep 'eglot))))")
            0))
          (with-current-buffer output
            (should (equal (buffer-string) "(nil nil)"))))
      (kill-buffer output))))

(ert-deftest ri-startup-test-first-lsp-command-loads-before-dispatch ()
  (let (events)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push (list 'require feature) events)
                 t))
              ((symbol-function 'ri--close-menu)
               (lambda () (push '(close-menu) events)))
              ((symbol-function 'ri--call-preserving-user-error)
               (lambda (function) (push (list 'dispatch function) events))))
      (ri-find-definition))
    (should
     (equal (nreverse events)
            '((require ri-lsp)
              (close-menu)
              (dispatch ri-lsp--find-definition))))))


(ert-deftest ri-startup-test-first-lsp-picker-loads-before-opening ()
  (let (events)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push (list 'require feature) events)
                 t))
              ((symbol-function 'ri--open-picker)
               (lambda (function) (push (list 'open function) events))))
      (ri-pick-document-symbol)
      (ri-pick-workspace-symbol))
    (should
     (equal (nreverse events)
            '((require ri-lsp)
              (open ri-lsp-pick-document-symbols)
              (require ri-lsp)
              (open ri-lsp-pick-workspace-symbols))))))

(provide 'ri-startup-test)
;;; ri-startup-test.el ends here
