;;; ki-tabs-test.el --- Tests for ki-tabs.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ki-tabs)

(ert-deftest ki-tabs-test-buffer-list-keeps-only-files-in-path-order ()
  (let ((alpha (generate-new-buffer "ki-tabs-alpha"))
        (zeta (generate-new-buffer "ki-tabs-zeta"))
        (special (generate-new-buffer "ki-tabs-special"))
        (hidden (generate-new-buffer " ki-tabs-hidden")))
    (unwind-protect
        (progn
          (with-current-buffer alpha
            (setq buffer-file-name "/tmp/alpha.el"))
          (with-current-buffer zeta
            (setq buffer-file-name "/tmp/zeta.el"))
          (with-current-buffer hidden
            (setq buffer-file-name "/tmp/hidden.el"))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list special zeta hidden alpha))))
            (should (equal (ki-tabs--buffer-list)
                           (list alpha zeta)))))
      (mapc #'kill-buffer (list alpha zeta special hidden)))))

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

(ert-deftest ki-tabs-test-format-marks-current-and-modified-tabs ()
  (let ((current (generate-new-buffer "ki-tabs-current"))
        (modified (generate-new-buffer "ki-tabs-modified")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer current
            (setq buffer-file-name "/tmp/100%.el"))
          (with-current-buffer modified
            (setq buffer-file-name "/tmp/modified.el")
            (set-buffer-modified-p t))
          (set-window-buffer (selected-window) current)
          (with-current-buffer current
            (setq-local tab-line-tab-name-function #'ki-tabs--tab-name)
            (let* ((buffers (list current modified))
                   (current-tab (ki-tabs--format-tab current buffers))
                   (modified-tab (ki-tabs--format-tab modified buffers)))
              (should (equal (substring-no-properties current-tab)
                             " [-] 100%%.el "))
              (should (equal (substring-no-properties modified-tab)
                             " [÷] modified.el "))
              (should (eq (get-text-property 0 'tab current-tab) current))
              (should (get-text-property 0 'selected current-tab))
              (should-not (get-text-property 0 'selected modified-tab))
              (should (eq (get-text-property 0 'keymap current-tab)
                          tab-line-tab-map)))))
      (when (buffer-live-p modified)
        (with-current-buffer modified
          (set-buffer-modified-p nil)))
      (mapc #'kill-buffer (list current modified)))))

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
            (should tab-line-mode)
            (should (eq tab-line-tabs-function #'ki-tabs--buffer-list)))
          (ki-tabs-mode -1)
          (with-current-buffer file
            (should-not tab-line-mode)
            (should (local-variable-p 'tab-line-separator))
            (should (equal tab-line-separator "before"))
            (should-not (local-variable-p 'tab-line-tabs-function)))
          (with-current-buffer late-file
            (should-not tab-line-mode)
            (should-not (local-variable-p 'tab-line-format))))
      (when ki-tabs-mode
        (ki-tabs-mode -1))
      (mapc #'kill-buffer (list file late-file special)))))

(provide 'ki-tabs-test)

;;; ki-tabs-test.el ends here
