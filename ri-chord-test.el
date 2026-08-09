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

(ert-deftest ri-chord-test-help-prefix-shows-default-legend ()
  (with-temp-buffer
    (let (shown hidden)
      (cl-letf (((symbol-function 'keymap-legend-show)
                 (lambda (title keymap legend-spec)
                   (setq shown (list title keymap legend-spec))))
                ((symbol-function 'keymap-legend-hide)
                 (lambda () (setq hidden t)))
                ((symbol-function 'this-command-keys-vector)
                 (lambda () [])))
        (let ((ri--help-prefix-active nil))
          (should (eq (ri--help-prefix-filter 'help-command)
                      'help-command))
          (should-not shown)
          (cl-letf (((symbol-function 'this-command-keys-vector)
                     (lambda () (vector ?\C-h))))
            (should (eq (ri--help-prefix-filter 'help-command)
                        'help-command)))
          (should (equal shown
                         '("C-h Help" help-command (:title "C-h Help"))))
          (should ri--help-prefix-active)
          (should (memq #'ri--exit-help-prefix post-command-hook))
          (ri--exit-help-prefix)
          (should hidden)
          (should-not ri--help-prefix-active)
          (should-not (memq #'ri--exit-help-prefix post-command-hook)))))))

(ert-deftest ri-chord-test-help-prefix-disables-v-chord ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (let ((mini-modal-mode t)
            (ri--menu-state nil)
            (ri--help-prefix-active t))
        (ri-chord-setup)
        (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () [])))
          (should-not (ri--chord-when-p))
          (should (eq
                   (kkp-chord--translate-advice
                    (lambda (_input) 'normal)
                    (string-to-list "118;:1u"))
                   'normal)))
        (should-not kkp-chord--held)))))

(ert-deftest ri-chord-test-help-prefix-dispatches-next-key ()
  (let* ((help-map (copy-keymap (symbol-function 'help-command)))
         (mini-modal-map (copy-keymap mini-modal-map))
         (called nil)
         (shown nil)
         (hidden nil))
    (define-key mini-modal-map
                (kbd "C-h")
                '(menu-item "Help" help-command :filter ri--help-prefix-filter))
    (define-key help-map
                "v"
                (lambda () (interactive) (setq called t)))
    (with-temp-buffer
      (let ((ri--help-prefix-active nil)
            (overriding-terminal-local-map mini-modal-map))
        (cl-letf (((symbol-function 'help-command) help-map)
                  ((symbol-function 'keymap-legend-show)
                   (lambda (&rest _) (setq shown t)))
                  ((symbol-function 'keymap-legend-hide)
                   (lambda () (setq hidden t))))
          (execute-kbd-macro (kbd "C-h v")))
        (should called)
        (should shown)
        (should hidden)
        (should-not ri--help-prefix-active)))))

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
