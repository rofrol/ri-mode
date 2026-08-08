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

(ert-deftest ri-extend-test-switches-from-char-to-word ()
  (ri-extend-test--with-buffer "foo bar baz"
    (dolist (case '((nil end 1 4 "foo")
                    (t start 1 2 "f")))
      (pcase-let ((`(,swap ,edge ,beg ,end ,text) case))
        (goto-char (point-min))
        (setq sr-submode 'char)
        (should (ri--enter-extend))
        (when swap
          (ri-swap-cursor))
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

(ert-deftest ri-extend-test-line-down-does-not-highlight-newline ()
  (ri-extend-test--with-buffer "foo\nbar\n"
    (setq sr-submode 'line)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (let ((bounds (ri--selection-bounds))
          (highlighted-p
           (lambda (pos)
             (cl-some
              (lambda (overlay)
                (eq (overlay-get overlay 'face) 'sr-highlight-face))
              (overlays-at pos)))))
      (should (equal bounds (cons 1 8)))
      (should (equal (buffer-substring-no-properties
                      (car bounds) (cdr bounds))
                     "foo\nbar"))
      (dolist (pos '(1 2 3 5 6 7))
        (should (funcall highlighted-p pos)))
      (dolist (pos '(4 8))
        (should-not (funcall highlighted-p pos))))
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
                  #'ri-swap-cursor)))))

(provide 'ri-extend-test)
;;; ri-extend-test.el ends here
