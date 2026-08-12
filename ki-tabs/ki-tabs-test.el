;;; ki-tabs-test.el --- Tests for ki-tabs.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ki-tabs)

(ert-deftest ki-tabs-test-buffer-list-keeps-marked-files-plus-current ()
  (let ((alpha (generate-new-buffer "ki-tabs-alpha"))
        (zeta (generate-new-buffer "ki-tabs-zeta"))
        (current (generate-new-buffer "ki-tabs-current"))
        (unmarked (generate-new-buffer "ki-tabs-unmarked"))
        (special (generate-new-buffer "ki-tabs-special"))
        (hidden (generate-new-buffer " ki-tabs-hidden")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer alpha
            (setq buffer-file-name "/tmp/alpha.el"
                  ki-tabs--marked-p t))
          (with-current-buffer zeta
            (setq buffer-file-name "/tmp/zeta.el"
                  ki-tabs--marked-p t))
          (with-current-buffer current
            (setq buffer-file-name "/tmp/beta.el"))
          (with-current-buffer unmarked
            (setq buffer-file-name "/tmp/unmarked.el"))
          (with-current-buffer hidden
            (setq buffer-file-name "/tmp/hidden.el"
                  ki-tabs--marked-p t))
          (set-window-buffer (selected-window) current)
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list special zeta unmarked hidden current alpha))))
            (should (equal (ki-tabs--buffer-list)
                           (list alpha zeta current)))))
      (mapc #'kill-buffer
            (list alpha zeta current unmarked special hidden)))))

(ert-deftest ki-tabs-test-names-use-shortest-unique-path-suffix ()
  (let ((alpha (generate-new-buffer "ki-tabs-alpha-main"))
        (beta (generate-new-buffer "ki-tabs-beta-main"))
        (other (generate-new-buffer "ki-tabs-other")))
    (unwind-protect
        (progn
          (with-current-buffer alpha
            (setq buffer-file-name "/tmp/alpha/src/main.el"))
          (with-current-buffer beta
            (setq buffer-file-name "/tmp/beta/src/main.el"))
          (with-current-buffer other
            (setq buffer-file-name "/tmp/beta/src/other.el"))
          (let ((buffers (list alpha beta other)))
            (should (equal (ki-tabs--tab-name alpha buffers)
                           "alpha/src/main.el"))
            (should (equal (ki-tabs--tab-name beta buffers)
                           "beta/src/main.el"))
            (should (equal (ki-tabs--tab-name other buffers)
                           "other.el"))))
      (mapc #'kill-buffer (list alpha beta other)))))

(ert-deftest ki-tabs-test-identical-paths-fall-back-to-buffer-names ()
  (let ((first (generate-new-buffer "ki-tabs-main-a"))
        (second (generate-new-buffer "ki-tabs-main-b")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (setq buffer-file-name "/tmp/main.el"))
          (with-current-buffer second
            (setq buffer-file-name "/tmp/main.el"))
          (let ((buffers (list first second)))
            (should (equal (ki-tabs--tab-name first buffers)
                           (buffer-name first)))
            (should (equal (ki-tabs--tab-name second buffers)
                           (buffer-name second)))))
      (mapc #'kill-buffer (list first second)))))

(ert-deftest ki-tabs-test-format-shows-marked-and-modified-states ()
  (let ((current (generate-new-buffer "ki-tabs-current"))
        (unmarked (generate-new-buffer "ki-tabs-unmarked"))
        (unmarked-modified
         (generate-new-buffer "ki-tabs-unmarked-modified"))
        (marked-modified
         (generate-new-buffer "ki-tabs-marked-modified")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer current
            (setq buffer-file-name "/tmp/100%.el"
                  ki-tabs--marked-p t))
          (with-current-buffer unmarked
            (setq buffer-file-name "/tmp/unmarked.el"))
          (with-current-buffer unmarked-modified
            (setq buffer-file-name "/tmp/unmarked-modified.el")
            (set-buffer-modified-p t))
          (with-current-buffer marked-modified
            (setq buffer-file-name "/tmp/marked-modified.el"
                  ki-tabs--marked-p t)
            (set-buffer-modified-p t))
          (set-window-buffer (selected-window) current)
          (with-current-buffer current
            (setq-local tab-line-tab-name-function #'ki-tabs--tab-name)
            (let* ((buffers
                    (list current unmarked unmarked-modified marked-modified))
                   (current-tab (ki-tabs--format-tab current buffers))
                   (unmarked-tab (ki-tabs--format-tab unmarked buffers))
                   (unmarked-modified-tab
                    (ki-tabs--format-tab unmarked-modified buffers))
                   (marked-modified-tab
                    (ki-tabs--format-tab marked-modified buffers)))
              (should (equal (substring-no-properties current-tab)
                             " [-] 100%%.el "))
              (should (equal (substring-no-properties unmarked-tab)
                             " [ ] unmarked.el "))
              (should
               (equal (substring-no-properties unmarked-modified-tab)
                      " [:] unmarked-modified.el "))
              (should
               (equal (substring-no-properties marked-modified-tab)
                      " [÷] marked-modified.el "))
              (should (eq (get-text-property 0 'tab current-tab) current))
              (should (get-text-property 0 'selected current-tab))
              (should-not
               (get-text-property 0 'selected unmarked-modified-tab))
              (should (eq (get-text-property 0 'keymap current-tab)
                          tab-line-tab-map)))))
      (dolist (buffer (list unmarked-modified marked-modified))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))))
      (mapc #'kill-buffer
            (list current unmarked unmarked-modified marked-modified)))))

(ert-deftest ki-tabs-test-buffer-layer-navigation-matches-ki ()
  (let ((alpha (generate-new-buffer "ki-tabs-alpha"))
        (beta (generate-new-buffer "ki-tabs-beta"))
        (gamma (generate-new-buffer "ki-tabs-gamma"))
        (transient (generate-new-buffer "ki-tabs-transient")))
    (unwind-protect
        (save-window-excursion
          (dolist (entry `((,alpha . "/tmp/alpha.el")
                           (,beta . "/tmp/beta.el")
                           (,gamma . "/tmp/gamma.el")
                           (,transient . "/tmp/transient.el")))
            (with-current-buffer (car entry)
              (setq buffer-file-name (cdr entry))))
          (dolist (buffer (list alpha gamma))
            (with-current-buffer buffer
              (setq ki-tabs--marked-p t)))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list transient gamma beta alpha))))
            (switch-to-buffer transient)
            (ki-tabs-switch-to-right-marked-buffer)
            (should (eq (current-buffer) alpha))
            (ki-tabs-switch-to-left-marked-buffer)
            (should (eq (current-buffer) gamma))
            (ki-tabs-switch-to-first-marked-buffer)
            (should (eq (current-buffer) alpha))
            (ki-tabs-switch-to-last-marked-buffer)
            (should (eq (current-buffer) gamma))
            (ki-tabs-switch-to-next-buffer)
            (should (eq (current-buffer) beta))
            (ki-tabs-switch-to-next-buffer)
            (should (eq (current-buffer) transient))
            (ki-tabs-switch-to-previous-buffer)
            (should (eq (current-buffer) beta))
            (ki-tabs-switch-to-previous-buffer)
            (should (eq (current-buffer) gamma))
            (switch-to-buffer alpha)
            (ki-tabs-switch-to-previous-buffer)
            (should (eq (current-buffer) alpha))
            (switch-to-buffer transient)
            (ki-tabs-switch-to-next-buffer)
            (should (eq (current-buffer) transient))))
      (mapc #'kill-buffer (list alpha beta gamma transient)))))

(ert-deftest ki-tabs-test-buffer-layer-mark-and-alternate-operations ()
  (let ((current (generate-new-buffer "ki-tabs-current"))
        (alternate (generate-new-buffer "ki-tabs-alternate"))
        (other (generate-new-buffer "ki-tabs-other")))
    (unwind-protect
        (save-window-excursion
          (dolist (entry `((,current . "/tmp/current.el")
                           (,alternate . "/tmp/alternate.el")
                           (,other . "/tmp/other.el")))
            (with-current-buffer (car entry)
              (setq buffer-file-name (cdr entry)
                    ki-tabs--marked-p t)))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list current alternate other))))
            (switch-to-buffer current)
            (ki-tabs-unmark-other-buffers)
            (should (ki-tabs-buffer-marked-p current))
            (should-not (ki-tabs-buffer-marked-p alternate))
            (should-not (ki-tabs-buffer-marked-p other))
            (ki-tabs-toggle-buffer-mark)
            (should-not (ki-tabs-buffer-marked-p current))
            (ki-tabs-toggle-buffer-mark)
            (should (ki-tabs-buffer-marked-p current))
            (ki-tabs-switch-to-alternate-buffer)
            (should (eq (current-buffer) alternate))))
      (mapc #'kill-buffer (list current alternate other)))))

(ert-deftest ki-tabs-test-mode-installs-for-files-and-restores-state ()
  (let ((file (generate-new-buffer "ki-tabs-file"))
        (late-file (generate-new-buffer "ki-tabs-late-file"))
        (special (generate-new-buffer "ki-tabs-special")))
    (unwind-protect
        (progn
          (with-current-buffer file
            (setq buffer-file-name "/tmp/file.el")
            (setq-local tab-line-separator "before"))
          (ki-tabs-mode 1)
          (with-current-buffer file
            (should (ki-tabs-buffer-marked-p)))
          (with-current-buffer file
            (should tab-line-mode)
            (should (eq tab-line-tabs-function #'ki-tabs--buffer-list))
            (should (eq tab-line-tab-name-format-function
                        #'ki-tabs--format-tab))
            (should (eq tab-line-close-tab-function 'kill-buffer))
            (should (equal tab-line-separator "")))
          (with-current-buffer special
            (should-not tab-line-mode))
          (with-current-buffer late-file
            (setq buffer-file-name "/tmp/late.el")
            (run-hooks 'find-file-hook)
            (should-not (ki-tabs-buffer-marked-p))
            (should tab-line-mode)
            (should (eq tab-line-tabs-function #'ki-tabs--buffer-list)))
          (ki-tabs-mode -1)
          (with-current-buffer file
            (should-not tab-line-mode)
            (should (local-variable-p 'tab-line-separator))
            (should (equal tab-line-separator "before"))
            (should-not (local-variable-p 'tab-line-tabs-function))
            (should-not (local-variable-p 'ki-tabs--marked-p)))
          (with-current-buffer late-file
            (should-not tab-line-mode)
            (should-not (local-variable-p 'tab-line-format))
            (should-not (local-variable-p 'ki-tabs--marked-p))))
      (when ki-tabs-mode
        (ki-tabs-mode -1))
      (mapc #'kill-buffer (list file late-file special)))))

(provide 'ki-tabs-test)

;;; ki-tabs-test.el ends here
