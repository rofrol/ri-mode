;;; ri-chord-test.el --- Tests for RI KKP chord dispatch -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri)

(defmacro ri-chord-test--with-fresh-chords (&rest body)
  "Run BODY with isolated chord registrations and held state."
  (declare (indent 0) (debug t))
  `(let ((kkp-chord--held nil)
         (kkp-chord--mod-maps (make-hash-table :test 'eql))
         (kkp-chord--tap-actions (make-hash-table :test 'eql))
         (kkp-chord--predicates (make-hash-table :test 'eql))
         (kkp-chord--press-actions (make-hash-table :test 'eql))
         (kkp-chord--release-actions (make-hash-table :test 'eql)))
     ,@body))

(ert-deftest ri-chord-test-prefix-keys-do-not-shadow-emacs-keymaps ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (let ((mini-modal-mode t)
            (ri--menu-state nil))
        (ri-chord-setup)
        (dolist (prefix '(?\C-h ?\C-x ?\C-c))
          (let (translated)
            (cl-letf (((symbol-function 'this-command-keys-vector)
                       (lambda () (vector prefix))))
              (should-not (ri--chord-when-p))
              (setq translated
                    (kkp-chord--translate-advice
                     (lambda (_input) 'normal)
                     (string-to-list "118;:1u"))))
            (should (eq translated 'normal))
            (should-not kkp-chord--held)))))))

(ert-deftest ri-chord-test-standalone-v-remains-a-momentary-chord ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (let ((mini-modal-mode t)
            (ri--menu-state nil))
        (ri-chord-setup)
        (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () []))
                  ((symbol-function 'ri--hide-frame) #'ignore)
                  ((symbol-function 'keymap-legend-show) #'ignore)
                  ((symbol-function 'modal-cursor-refresh) #'ignore))
          (should (ri--chord-when-p))
          (should (equal
                   (kkp-chord--translate-advice
                    (lambda (_input) 'unexpected)
                    (string-to-list "118;:1u"))
                   [])))
        (should (equal kkp-chord--held '((118))))))))

(provide 'ri-chord-test)
;;; ri-chord-test.el ends here
