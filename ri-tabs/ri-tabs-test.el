;;; ri-tabs-test.el --- Tests for ri-tabs.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri-tabs)

(defvar ri-tabs-test--buffers nil)

(defun ri-tabs-test--make-store ()
  "Return a fresh synchronized file-backed multisession object."
  (make-multisession
   :key "marks-store"
   :initial-value nil
   :package "ri-tabs-test"
   :synchronized t
   :storage 'files))

(defun ri-tabs-test--make-file (root name)
  "Create NAME below ROOT and return its absolute filename."
  (let ((file (expand-file-name name root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert name "\n"))
    file))

(defun ri-tabs-test--visit-file (file)
  "Visit FILE and register its buffer for test cleanup."
  (let ((buffer (find-file-noselect file)))
    (cl-pushnew buffer ri-tabs-test--buffers)
    buffer))

(defun ri-tabs-test--kill-buffer (buffer)
  "Kill BUFFER without prompting when it is live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (set-buffer-modified-p nil))
    (kill-buffer buffer)))

(defmacro ri-tabs-test-with-persistence (&rest body)
  "Run BODY with isolated file-backed persistent mark storage."
  (declare (indent 0) (debug t))
  `(let* ((ri-tabs-test-root
           (make-temp-file "ri-tabs-persistence-" t))
          (multisession-directory
           (expand-file-name "multisession/" ri-tabs-test-root))
          (user-init-file
           (expand-file-name "synthetic-init.el" ri-tabs-test-root))
          (ri-tabs--marks-store (ri-tabs-test--make-store))
          (ri-tabs-test--buffers nil))
     (unwind-protect
         (progn
           (when ri-tabs-mode
             (ri-tabs-mode -1))
           ,@body)
       (when ri-tabs-mode
         (ri-tabs-mode -1))
       (mapc #'ri-tabs-test--kill-buffer ri-tabs-test--buffers)
       (when (file-directory-p ri-tabs-test-root)
         (delete-directory ri-tabs-test-root t)))))

(ert-deftest ri-tabs-test-buffer-list-keeps-marked-files-plus-current ()
  (let ((alpha (generate-new-buffer "ri-tabs-alpha"))
        (zeta (generate-new-buffer "ri-tabs-zeta"))
        (current (generate-new-buffer "ri-tabs-current"))
        (unmarked (generate-new-buffer "ri-tabs-unmarked"))
        (special (generate-new-buffer "ri-tabs-special"))
        (hidden (generate-new-buffer " ri-tabs-hidden")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer alpha
            (setq buffer-file-name "/tmp/alpha.el"
                  ri-tabs--marked-p t))
          (with-current-buffer zeta
            (setq buffer-file-name "/tmp/zeta.el"
                  ri-tabs--marked-p t))
          (with-current-buffer current
            (setq buffer-file-name "/tmp/beta.el"))
          (with-current-buffer unmarked
            (setq buffer-file-name "/tmp/unmarked.el"))
          (with-current-buffer hidden
            (setq buffer-file-name "/tmp/hidden.el"
                  ri-tabs--marked-p t))
          (set-window-buffer (selected-window) current)
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list special zeta unmarked hidden current alpha))))
            (should (equal (ri-tabs--buffer-list)
                           (list alpha zeta current)))))
      (mapc #'kill-buffer
            (list alpha zeta current unmarked special hidden)))))

(ert-deftest ri-tabs-test-names-use-shortest-unique-path-suffix ()
  (let ((alpha (generate-new-buffer "ri-tabs-alpha-main"))
        (beta (generate-new-buffer "ri-tabs-beta-main"))
        (other (generate-new-buffer "ri-tabs-other")))
    (unwind-protect
        (progn
          (with-current-buffer alpha
            (setq buffer-file-name "/tmp/alpha/src/main.el"))
          (with-current-buffer beta
            (setq buffer-file-name "/tmp/beta/src/main.el"))
          (with-current-buffer other
            (setq buffer-file-name "/tmp/beta/src/other.el"))
          (let ((buffers (list alpha beta other)))
            (should (equal (ri-tabs--tab-name alpha buffers)
                           "alpha/src/main.el"))
            (should (equal (ri-tabs--tab-name beta buffers)
                           "beta/src/main.el"))
            (should (equal (ri-tabs--tab-name other buffers)
                           "other.el"))))
      (mapc #'kill-buffer (list alpha beta other)))))

(ert-deftest ri-tabs-test-identical-paths-fall-back-to-buffer-names ()
  (let ((first (generate-new-buffer "ri-tabs-main-a"))
        (second (generate-new-buffer "ri-tabs-main-b")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (setq buffer-file-name "/tmp/main.el"))
          (with-current-buffer second
            (setq buffer-file-name "/tmp/main.el"))
          (let ((buffers (list first second)))
            (should (equal (ri-tabs--tab-name first buffers)
                           (buffer-name first)))
            (should (equal (ri-tabs--tab-name second buffers)
                           (buffer-name second)))))
      (mapc #'kill-buffer (list first second)))))

(ert-deftest ri-tabs-test-format-shows-marked-and-modified-states ()
  (let ((current (generate-new-buffer "ri-tabs-current"))
        (unmarked (generate-new-buffer "ri-tabs-unmarked"))
        (unmarked-modified
         (generate-new-buffer "ri-tabs-unmarked-modified"))
        (marked-modified
         (generate-new-buffer "ri-tabs-marked-modified")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer current
            (setq buffer-file-name "/tmp/100%.el"
                  ri-tabs--marked-p t))
          (with-current-buffer unmarked
            (setq buffer-file-name "/tmp/unmarked.el"))
          (with-current-buffer unmarked-modified
            (setq buffer-file-name "/tmp/unmarked-modified.el")
            (set-buffer-modified-p t))
          (with-current-buffer marked-modified
            (setq buffer-file-name "/tmp/marked-modified.el"
                  ri-tabs--marked-p t)
            (set-buffer-modified-p t))
          (set-window-buffer (selected-window) current)
          (with-current-buffer current
            (setq-local tab-line-tab-name-function #'ri-tabs--tab-name)
            (let* ((buffers
                    (list current unmarked unmarked-modified marked-modified))
                   (current-tab (ri-tabs--format-tab current buffers))
                   (unmarked-tab (ri-tabs--format-tab unmarked buffers))
                   (unmarked-modified-tab
                    (ri-tabs--format-tab unmarked-modified buffers))
                   (marked-modified-tab
                    (ri-tabs--format-tab marked-modified buffers)))
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

(ert-deftest ri-tabs-test-buffer-layer-navigation-matches-ki ()
  (let ((alpha (generate-new-buffer "ri-tabs-alpha"))
        (beta (generate-new-buffer "ri-tabs-beta"))
        (gamma (generate-new-buffer "ri-tabs-gamma"))
        (transient (generate-new-buffer "ri-tabs-transient")))
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
              (setq ri-tabs--marked-p t)))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list transient gamma beta alpha))))
            (switch-to-buffer transient)
            (ri-tabs-switch-to-right-marked-buffer)
            (should (eq (current-buffer) alpha))
            (ri-tabs-switch-to-left-marked-buffer)
            (should (eq (current-buffer) gamma))
            (ri-tabs-switch-to-first-marked-buffer)
            (should (eq (current-buffer) alpha))
            (ri-tabs-switch-to-last-marked-buffer)
            (should (eq (current-buffer) gamma))
            (ri-tabs-switch-to-next-buffer)
            (should (eq (current-buffer) beta))
            (ri-tabs-switch-to-next-buffer)
            (should (eq (current-buffer) transient))
            (ri-tabs-switch-to-previous-buffer)
            (should (eq (current-buffer) beta))
            (ri-tabs-switch-to-previous-buffer)
            (should (eq (current-buffer) gamma))
            (switch-to-buffer alpha)
            (ri-tabs-switch-to-previous-buffer)
            (should (eq (current-buffer) alpha))
            (switch-to-buffer transient)
            (ri-tabs-switch-to-next-buffer)
            (should (eq (current-buffer) transient))))
      (mapc #'kill-buffer (list alpha beta gamma transient)))))

(ert-deftest ri-tabs-test-buffer-layer-mark-and-alternate-operations ()
  (ri-tabs-test-with-persistence
    (save-window-excursion
      (let ((current
             (ri-tabs-test--visit-file
              (ri-tabs-test--make-file
               ri-tabs-test-root "current.el")))
            (alternate
             (ri-tabs-test--visit-file
              (ri-tabs-test--make-file
               ri-tabs-test-root "alternate.el")))
            (other
             (ri-tabs-test--visit-file
              (ri-tabs-test--make-file
               ri-tabs-test-root "other.el"))))
        (ri-tabs-mode 1)
        (cl-letf (((symbol-function 'buffer-list)
                   (lambda (&optional _frame)
                     (list current alternate other))))
          (switch-to-buffer current)
          (ri-tabs-unmark-other-buffers)
          (should (ri-tabs-buffer-marked-p current))
          (should-not (ri-tabs-buffer-marked-p alternate))
          (should-not (ri-tabs-buffer-marked-p other))
          (ri-tabs-toggle-buffer-mark)
          (should-not (ri-tabs-buffer-marked-p current))
          (ri-tabs-toggle-buffer-mark)
          (should (ri-tabs-buffer-marked-p current))
          (ri-tabs-switch-to-alternate-buffer)
          (should (eq (current-buffer) alternate)))))))

(ert-deftest ri-tabs-test-mode-installs-for-files-and-restores-state ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--visit-file
             (ri-tabs-test--make-file ri-tabs-test-root "file.el")))
           (late-path
            (ri-tabs-test--make-file ri-tabs-test-root "late.el"))
           (late-file nil)
           (special (generate-new-buffer "ri-tabs-special")))
      (push special ri-tabs-test--buffers)
      (with-current-buffer file
        (setq-local tab-line-separator "before"))
      (ri-tabs-mode 1)
      (with-current-buffer file
        (should (ri-tabs-buffer-marked-p))
        (should tab-line-mode)
        (should (eq tab-line-tabs-function #'ri-tabs--buffer-list))
        (should (eq tab-line-tab-name-format-function
                    #'ri-tabs--format-tab))
        (should (eq tab-line-close-tab-function 'kill-buffer))
        (should (equal tab-line-separator "")))
      (with-current-buffer special
        (should-not tab-line-mode))
      (setq late-file (ri-tabs-test--visit-file late-path))
      (with-current-buffer late-file
        (should-not (ri-tabs-buffer-marked-p))
        (should tab-line-mode)
        (should (eq tab-line-tabs-function #'ri-tabs--buffer-list)))
      (ri-tabs-mode -1)
      (with-current-buffer file
        (should-not tab-line-mode)
        (should (local-variable-p 'tab-line-separator))
        (should (equal tab-line-separator "before"))
        (should-not (local-variable-p 'tab-line-tabs-function))
        (should-not (local-variable-p 'ri-tabs--marked-p))
        (should-not (local-variable-p 'ri-tabs--file-id)))
      (with-current-buffer late-file
        (should-not tab-line-mode)
        (should-not (local-variable-p 'tab-line-format))
        (should-not (local-variable-p 'ri-tabs--marked-p))
        (should-not (local-variable-p 'ri-tabs--file-id))))))

(ert-deftest ri-tabs-test-mark-survives-kill-and-reopen ()
  (ri-tabs-test-with-persistence
    (let ((file (ri-tabs-test--make-file
                 ri-tabs-test-root "kill-and-reopen.el")))
      (ri-tabs-mode 1)
      (let ((buffer (ri-tabs-test--visit-file file)))
        (with-current-buffer buffer
          (should-not (ri-tabs-buffer-marked-p))
          (ri-tabs-mark-buffer)
          (should (ri-tabs-buffer-marked-p))
          (should
           (member (ri-tabs--buffer-file-id buffer)
                   (plist-get (ri-tabs--read-state) :files))))
        (ri-tabs-test--kill-buffer buffer))
      (let ((reopened (ri-tabs-test--visit-file file)))
        (with-current-buffer reopened
          (should (ri-tabs-buffer-marked-p)))))))

(ert-deftest ri-tabs-test-mark-reloads-from-disk ()
  (ri-tabs-test-with-persistence
    (let ((file (ri-tabs-test--make-file
                 ri-tabs-test-root "reload.el")))
      (ri-tabs-mode 1)
      (let ((buffer (ri-tabs-test--visit-file file)))
        (with-current-buffer buffer
          (ri-tabs-mark-buffer))
        (ri-tabs-test--kill-buffer buffer))
      (setq ri-tabs--marks-store (ri-tabs-test--make-store))
      (let ((reopened (ri-tabs-test--visit-file file)))
        (with-current-buffer reopened
          (should (ri-tabs-buffer-marked-p)))))))

(ert-deftest ri-tabs-test-unmark-survives-kill-and-reopen ()
  (ri-tabs-test-with-persistence
    (let ((file (ri-tabs-test--make-file
                 ri-tabs-test-root "unmark.el")))
      (ri-tabs-mode 1)
      (let ((buffer (ri-tabs-test--visit-file file)))
        (with-current-buffer buffer
          (ri-tabs-mark-buffer)
          (ri-tabs-unmark-buffer)
          (should-not (ri-tabs-buffer-marked-p)))
        (ri-tabs-test--kill-buffer buffer))
      (let ((reopened (ri-tabs-test--visit-file file)))
        (with-current-buffer reopened
          (should-not (ri-tabs-buffer-marked-p)))))))

(ert-deftest ri-tabs-test-unmark-others-includes-closed-files ()
  (ri-tabs-test-with-persistence
    (let* ((first-file
            (ri-tabs-test--make-file ri-tabs-test-root "first.el"))
           (second-file
            (ri-tabs-test--make-file ri-tabs-test-root "second.el")))
      (ri-tabs-mode 1)
      (let ((first (ri-tabs-test--visit-file first-file))
            (second (ri-tabs-test--visit-file second-file)))
        (with-current-buffer first
          (ri-tabs-mark-buffer))
        (with-current-buffer second
          (ri-tabs-mark-buffer))
        (ri-tabs-test--kill-buffer second)
        (with-current-buffer first
          (ri-tabs-unmark-other-buffers)
          (should (ri-tabs-buffer-marked-p)))
        (let ((reopened (ri-tabs-test--visit-file second-file)))
          (with-current-buffer reopened
            (should-not (ri-tabs-buffer-marked-p))))))))

(ert-deftest ri-tabs-test-rename-and-save-as-migrate-marks ()
  (ri-tabs-test-with-persistence
    (let* ((old-file
            (ri-tabs-test--make-file ri-tabs-test-root "old.el"))
           (renamed-file
            (expand-file-name "renamed.el" ri-tabs-test-root))
           (save-source
            (ri-tabs-test--make-file ri-tabs-test-root "source.el"))
           (saved-file
            (expand-file-name "saved.el" ri-tabs-test-root)))
      (ri-tabs-mode 1)
      (let* ((renamed-buffer (ri-tabs-test--visit-file old-file))
             (old-id (ri-tabs--buffer-file-id renamed-buffer)))
        (with-current-buffer renamed-buffer
          (ri-tabs-mark-buffer)
          (rename-visited-file renamed-file))
        (let ((renamed-id (ri-tabs--buffer-file-id renamed-buffer))
              (files (plist-get (ri-tabs--read-state) :files)))
          (should (member renamed-id files))
          (should-not (member old-id files)))
        (ri-tabs-test--kill-buffer renamed-buffer)
        (with-current-buffer
            (ri-tabs-test--visit-file renamed-file)
          (should (ri-tabs-buffer-marked-p))))
      (let* ((saved-buffer (ri-tabs-test--visit-file save-source))
             (source-id (ri-tabs--buffer-file-id saved-buffer)))
        (with-current-buffer saved-buffer
          (ri-tabs-mark-buffer)
          (write-file saved-file))
        (let ((saved-id (ri-tabs--buffer-file-id saved-buffer))
              (files (plist-get (ri-tabs--read-state) :files)))
          (should (member saved-id files))
          (should-not (member source-id files)))
        (ri-tabs-test--kill-buffer saved-buffer)
        (with-current-buffer
            (ri-tabs-test--visit-file saved-file)
          (should (ri-tabs-buffer-marked-p)))))))

(ert-deftest ri-tabs-test-mode-reenable-does-not-reseed-empty-state ()
  (ri-tabs-test-with-persistence
    (let* ((file (ri-tabs-test--make-file
                  ri-tabs-test-root "reenable.el"))
           (buffer (ri-tabs-test--visit-file file)))
      (ri-tabs-mode 1)
      (with-current-buffer buffer
        (should (ri-tabs-buffer-marked-p))
        (ri-tabs-unmark-buffer)
        (should-not (ri-tabs-buffer-marked-p)))
      (should (equal (ri-tabs--read-state)
                     '(:version 1 :files nil)))
      (ri-tabs-mode -1)
      (ri-tabs-mode 1)
      (with-current-buffer buffer
        (should-not (ri-tabs-buffer-marked-p))))))

(ert-deftest ri-tabs-test-first-enable-seeds-and-persists-open-files ()
  (ri-tabs-test-with-persistence
    (let* ((first
            (ri-tabs-test--visit-file
             (ri-tabs-test--make-file ri-tabs-test-root "seed-a.el")))
           (second
            (ri-tabs-test--visit-file
             (ri-tabs-test--make-file ri-tabs-test-root "seed-b.el")))
           (writes 0)
           (write-state (symbol-function 'ri-tabs--write-state)))
      (cl-letf (((symbol-function 'ri-tabs--write-state)
                 (lambda (state)
                   (cl-incf writes)
                   (funcall write-state state))))
        (ri-tabs-mode 1))
      (should (= writes 1))
      (should (ri-tabs-buffer-marked-p first))
      (should (ri-tabs-buffer-marked-p second))
      (should
       (equal
        (plist-get (ri-tabs--read-state) :files)
        (sort (list (ri-tabs--buffer-file-id first)
                    (ri-tabs--buffer-file-id second))
              #'string-lessp))))))

(ert-deftest ri-tabs-test-symlink-and-real-path-share-mark ()
  (ri-tabs-test-with-persistence
    (let* ((real-file
            (ri-tabs-test--make-file ri-tabs-test-root "real.el"))
           (link-file
            (expand-file-name "link.el" ri-tabs-test-root)))
      (make-symbolic-link real-file link-file)
      (ri-tabs-mode 1)
      (let ((linked-buffer (ri-tabs-test--visit-file link-file)))
        (with-current-buffer linked-buffer
          (ri-tabs-mark-buffer))
        (ri-tabs-test--kill-buffer linked-buffer))
      (let ((real-buffer (ri-tabs-test--visit-file real-file)))
        (with-current-buffer real-buffer
          (should (ri-tabs-buffer-marked-p)))))))

(ert-deftest ri-tabs-test-duplicate-file-buffers-share-mark-cache ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file ri-tabs-test-root "duplicate.el"))
           (first nil)
           (second nil))
      (ri-tabs-mode 1)
      (setq first (ri-tabs-test--visit-file file)
            second (generate-new-buffer "ri-tabs-duplicate"))
      (push second ri-tabs-test--buffers)
      (with-current-buffer second
        (set-visited-file-name file t))
      (with-current-buffer first
        (ri-tabs-toggle-buffer-mark))
      (should (ri-tabs-buffer-marked-p first))
      (should (ri-tabs-buffer-marked-p second))
      (with-current-buffer second
        (ri-tabs-toggle-buffer-mark))
      (should-not (ri-tabs-buffer-marked-p first))
      (should-not (ri-tabs-buffer-marked-p second)))))

(ert-deftest ri-tabs-test-mark-commands-reject-non-file-buffer ()
  (ri-tabs-test-with-persistence
    (let ((buffer (generate-new-buffer "ri-tabs-non-file")))
      (push buffer ri-tabs-test--buffers)
      (dolist (command '(ri-tabs-mark-buffer
                         ri-tabs-unmark-buffer
                         ri-tabs-toggle-buffer-mark
                         ri-tabs-unmark-other-buffers))
        (with-current-buffer buffer
          (should-error (funcall command) :type 'user-error))))))

(ert-deftest ri-tabs-test-malformed-schema-is-not-overwritten-by-hooks ()
  (ri-tabs-test-with-persistence
    (let ((file
           (ri-tabs-test--make-file ri-tabs-test-root "malformed.el"))
          (invalid '(:version 99 :files ("/unsupported")))
          warnings
          buffer)
      (ri-tabs-mode 1)
      (setf (multisession-value ri-tabs--marks-store) invalid)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type message &optional level buffer-name)
                   (push (list type message level buffer-name)
                         warnings))))
        (setq buffer (ri-tabs-test--visit-file file)))
      (should (buffer-live-p buffer))
      (should-not (ri-tabs-buffer-marked-p buffer))
      (should (seq-some (lambda (warning)
                          (eq (car warning) 'ri-tabs))
                        warnings))
      (should (equal (multisession-value ri-tabs--marks-store)
                     invalid)))))

(provide 'ri-tabs-test)

;;; ri-tabs-test.el ends here
