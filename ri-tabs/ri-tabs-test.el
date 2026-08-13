;;; ri-tabs-test.el --- Tests for ri-tabs.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri-tabs)
(require 'tab-bar)
(require 'tab-line)

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

(defun ri-tabs-test--track-root-buffers (root)
  "Register every live file buffer below ROOT for test cleanup."
  (dolist (buffer (buffer-list))
    (let ((file (buffer-file-name buffer)))
      (when (and file
                 (condition-case nil
                     (file-in-directory-p file root)
                   (error nil)))
        (cl-pushnew buffer ri-tabs-test--buffers)))))

(defun ri-tabs-test--file-id (file)
  "Return the canonical persistent identity for FILE."
  (setq file (expand-file-name file))
  (if (file-exists-p file)
      (file-truename file)
    (expand-file-name
     (file-name-nondirectory file)
     (file-truename (file-name-directory file)))))

(defun ri-tabs-test--store-files (&rest files)
  "Persist canonical identities for FILES."
  (ri-tabs--write-state
   (ri-tabs--make-state
    (mapcar #'ri-tabs-test--file-id files))))

(defun ri-tabs-test--buffers-for-id (file-id)
  "Return all live visible file buffers representing FILE-ID."
  (seq-filter
   (lambda (buffer)
     (equal (ri-tabs--buffer-file-id buffer) file-id))
   (ri-tabs-file-buffer-list)))

(ert-deftest ri-tabs-test-public-file-buffer-list-filters-and-sorts ()
  (let ((later (generate-new-buffer "ri-tabs-public-later"))
        (earlier (generate-new-buffer "ri-tabs-public-earlier"))
        (non-file (generate-new-buffer "ri-tabs-public-non-file")))
    (unwind-protect
        (progn
          (with-current-buffer later
            (setq buffer-file-name "/tmp/z.el"))
          (with-current-buffer earlier
            (setq buffer-file-name "/tmp/a.el"))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list later non-file earlier))))
            (should (equal (ri-tabs-file-buffer-list)
                           (list earlier later)))))
      (mapc #'kill-buffer (list later earlier non-file)))))

(defun ri-tabs-test--capture-frame-state (frame)
  "Capture Tab Bar parameters of FRAME for fixture cleanup."
  (list frame
        (frame-parameter frame 'tab-bar-lines)
        (frame-parameter frame 'tab-bar-lines-keep-state)))

(defun ri-tabs-test--restore-frame-state (state)
  "Restore one frame from captured fixture STATE."
  (when (frame-live-p (car state))
    (set-frame-parameter (car state) 'tab-bar-lines (nth 1 state))
    (set-frame-parameter
     (car state) 'tab-bar-lines-keep-state (nth 2 state))))

(defun ri-tabs-test--tab-line-state (buffer)
  "Return every Tab Line-local setting in BUFFER."
  (with-current-buffer buffer
    (sort
     (seq-filter
      (lambda (entry)
        (string-prefix-p
         "tab-line-" (symbol-name (car entry))))
      (copy-tree (buffer-local-variables)))
     (lambda (left right)
       (string-lessp
        (symbol-name (car left))
        (symbol-name (car right)))))))

(defmacro ri-tabs-test-with-tab-bar-state (&rest body)
  "Run BODY while restoring native Tab Bar and Ri surface state afterward."
  (declare (indent 0) (debug t))
  `(let ((ri-tabs-test--saved-tab-bar-mode (and tab-bar-mode t))
         (ri-tabs-test--saved-tab-bar-format
          (copy-tree (default-value 'tab-bar-format)))
         (ri-tabs-test--saved-tab-bar-show
          (default-value 'tab-bar-show))
         (ri-tabs-test--saved-tab-bar-auto-width
          (default-value 'tab-bar-auto-width))
         (ri-tabs-test--saved-auto-resize-tab-bars auto-resize-tab-bars)
         (ri-tabs-test--saved-tab-bar-map (copy-keymap tab-bar-map))
         (ri-tabs-test--saved-tab-bar-mode-map (copy-keymap tab-bar-mode-map))
         (ri-tabs-test--saved-default-frame-alist (copy-tree default-frame-alist))
         (ri-tabs-test--saved-frame-states
          (mapcar #'ri-tabs-test--capture-frame-state (frame-list))))
     (unwind-protect
         (progn ,@body)
       (condition-case nil
           (when ri-tabs-mode
             (ri-tabs-mode -1))
         (error nil))
       (setq ri-tabs-mode nil
             ri-tabs--activation-complete-p nil
             ri-tabs--refresh-pending-p nil)
       (ri-tabs--cancel-pending-activation)
       (ri-tabs--remove-infrastructure)
       (ri-tabs--remove-all-surfaces)
       (dolist (buffer (buffer-list))
         (ri-tabs--clear-buffer-cache buffer))
       (setq-default
        tab-bar-format (copy-tree ri-tabs-test--saved-tab-bar-format)
        tab-bar-show ri-tabs-test--saved-tab-bar-show
        tab-bar-auto-width ri-tabs-test--saved-tab-bar-auto-width
        auto-resize-tab-bars ri-tabs-test--saved-auto-resize-tab-bars)
       (condition-case nil
           (tab-bar-mode (if ri-tabs-test--saved-tab-bar-mode 1 -1))
         (error (setq tab-bar-mode ri-tabs-test--saved-tab-bar-mode)))
       (setcdr tab-bar-map (cdr (copy-keymap ri-tabs-test--saved-tab-bar-map)))
       (setcdr tab-bar-mode-map
               (cdr (copy-keymap ri-tabs-test--saved-tab-bar-mode-map)))
       (setq default-frame-alist
             (copy-tree ri-tabs-test--saved-default-frame-alist))
       (mapc #'ri-tabs-test--restore-frame-state
             ri-tabs-test--saved-frame-states))))

(defun ri-tabs-test--ordinary-windows (&optional frame)
  "Return non-minibuffer, non-Ri-surface windows of FRAME."
  (seq-filter
   (lambda (window)
     (and (not (window-minibuffer-p window))
          (not (ri-tabs--surface-window-p window))))
   (window-list frame 'nomini)))

(defun ri-tabs-test--surface-text (&optional frame)
  "Return FRAME's Ri surface text without properties, or nil."
  (let* ((frame (or frame (selected-frame)))
         (window (gethash frame ri-tabs--surface-windows)))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (buffer-substring-no-properties (point-min) (point-max))))))

(defmacro ri-tabs-test-with-persistence (&rest body)
  "Run BODY with isolated persistence and Tab Bar state."
  (declare (indent 0) (debug t))
  `(ri-tabs-test-with-tab-bar-state
     (let* ((ri-tabs-test-root
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
         (ri-tabs-test--track-root-buffers ri-tabs-test-root)
         (mapc #'ri-tabs-test--kill-buffer ri-tabs-test--buffers)
         (when (file-directory-p ri-tabs-test-root)
           (delete-directory ri-tabs-test-root t))))))

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
            (should
             (equal (ri-tabs--buffer-list current)
                    (list alpha zeta current)))
            (should
             (equal (ri-tabs--buffer-list unmarked)
                    (list alpha zeta unmarked)))
            (should
             (equal (ri-tabs--buffer-list special)
                    (list alpha zeta)))
            (should
             (equal (ri-tabs--buffer-list hidden)
                    (list alpha zeta)))))
      (mapc #'kill-buffer
            (list alpha zeta current unmarked special hidden)))))

(ert-deftest ri-tabs-test-owner-local-duplicate-keeps-basename ()
  (let ((owner (generate-new-buffer "ri-tabs-owner-main"))
        (foreign (generate-new-buffer "ri-tabs-foreign-main"))
        (owner-root "/tmp/repo-a/"))
    (unwind-protect
        (progn
          (with-current-buffer owner
            (setq buffer-file-name "/tmp/repo-a/src/main.el"))
          (with-current-buffer foreign
            (setq buffer-file-name "/tmp/repo-b/src/main.el"))
          (cl-letf (((symbol-function 'ri-tabs--buffer-owner-context)
                     (lambda (buffer)
                       (if (eq buffer owner)
                           owner-root
                         "/tmp/repo-b/"))))
            (let ((buffers (list owner foreign)))
              (should (equal (ri-tabs--tab-name owner buffers owner-root)
                             "main.el"))
              (should (equal (ri-tabs--tab-name foreign buffers owner-root)
                             "repo-b/src/main.el")))))
      (mapc #'kill-buffer (list owner foreign)))))

(ert-deftest ri-tabs-test-duplicate-naming-is-selection-independent ()
  (let ((owner (generate-new-buffer "ri-tabs-owner-main"))
        (foreign (generate-new-buffer "ri-tabs-foreign-main"))
        (owner-root "/tmp/repo-a/"))
    (unwind-protect
        (progn
          (with-current-buffer owner
            (setq buffer-file-name "/tmp/repo-a/src/main.el"))
          (with-current-buffer foreign
            (setq buffer-file-name "/tmp/repo-b/src/main.el"))
          (cl-letf (((symbol-function 'ri-tabs--buffer-owner-context)
                     (lambda (buffer)
                       (if (eq buffer owner)
                           owner-root
                         "/tmp/repo-b/"))))
            (let* ((buffers (list owner foreign))
                   (owner-labels
                    (mapcar (lambda (buffer)
                              (ri-tabs--tab-name buffer buffers owner-root))
                            buffers))
                   (foreign-labels
                    (mapcar (lambda (buffer)
                              (ri-tabs--tab-name buffer buffers owner-root))
                            buffers)))
              (should (equal owner-labels foreign-labels)))))
      (mapc #'kill-buffer (list owner foreign)))))

(ert-deftest ri-tabs-test-two-foreign-duplicates-grow-until-distinct ()
  (let ((owner (generate-new-buffer "ri-tabs-owner-main"))
        (foreign-a (generate-new-buffer "ri-tabs-foreign-a-main"))
        (foreign-b (generate-new-buffer "ri-tabs-foreign-b-main"))
        (owner-root "/tmp/repo-a/"))
    (unwind-protect
        (progn
          (with-current-buffer owner
            (setq buffer-file-name "/tmp/repo-a/src/main.el"))
          (with-current-buffer foreign-a
            (setq buffer-file-name "/tmp/repo-b/src/main.el"))
          (with-current-buffer foreign-b
            (setq buffer-file-name "/tmp/repo-c/src/main.el"))
          (cl-letf (((symbol-function 'ri-tabs--buffer-owner-context)
                     (lambda (buffer)
                       (if (eq buffer owner)
                           owner-root
                         (file-name-directory
                          (directory-file-name
                           (file-name-directory
                            (buffer-file-name buffer))))))))
            (let ((buffers (list owner foreign-a foreign-b)))
              (should (equal (ri-tabs--tab-name owner buffers owner-root)
                             "main.el"))
              (should (equal (ri-tabs--tab-name foreign-a buffers owner-root)
                             "repo-b/src/main.el"))
              (should (equal (ri-tabs--tab-name foreign-b buffers owner-root)
                             "repo-c/src/main.el")))))
      (mapc #'kill-buffer (list owner foreign-a foreign-b)))))

(ert-deftest ri-tabs-test-owner-repository-duplicates-are-distinguished ()
  (let ((foo (generate-new-buffer "ri-tabs-foo-main"))
        (bar (generate-new-buffer "ri-tabs-bar-main"))
        (owner-root "/tmp/project-a/"))
    (unwind-protect
        (progn
          (with-current-buffer foo
            (setq buffer-file-name "/tmp/project-a/foo/main.el"))
          (with-current-buffer bar
            (setq buffer-file-name "/tmp/project-a/bar/main.el"))
          (cl-letf (((symbol-function 'ri-tabs--buffer-owner-context)
                     (lambda (_buffer) owner-root)))
            (let ((buffers (list foo bar)))
              (should (equal (ri-tabs--tab-name foo buffers owner-root)
                             "foo/main.el"))
              (should (equal (ri-tabs--tab-name bar buffers owner-root)
                             "bar/main.el")))))
      (mapc #'kill-buffer (list foo bar)))))

(ert-deftest ri-tabs-test-outside-git-owner-keeps-short-name ()
  (let ((owner (generate-new-buffer "ri-tabs-dir-owner-main"))
        (foreign (generate-new-buffer "ri-tabs-dir-foreign-main"))
        (owner-root "/tmp/project-a/"))
    (unwind-protect
        (progn
          (with-current-buffer owner
            (setq buffer-file-name "/tmp/project-a/main.el"
                  default-directory owner-root))
          (with-current-buffer foreign
            (setq buffer-file-name "/tmp/project-b/main.el"
                  default-directory "/tmp/project-b/"))
          (cl-letf (((symbol-function 'ri-tabs--git-work-tree-root)
                     (lambda (_directory) nil)))
            (let ((buffers (list owner foreign)))
              (should (equal (ri-tabs--tab-name owner buffers owner-root)
                             "main.el"))
              (should (equal (ri-tabs--tab-name foreign buffers owner-root)
                             "project-b/main.el")))))
      (mapc #'kill-buffer (list owner foreign)))))

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
            (should (equal (ri-tabs--tab-name first buffers "/tmp/")
                           (buffer-name first)))
            (should (equal (ri-tabs--tab-name second buffers "/tmp/")
                           (buffer-name second)))))
      (mapc #'kill-buffer (list first second)))))

(ert-deftest ri-tabs-test-tab-label-width-follows-content ()
  (let ((short (generate-new-buffer "ri-tabs-short"))
        (long (generate-new-buffer "ri-tabs-long")))
    (unwind-protect
        (progn
          (with-current-buffer short
            (setq buffer-file-name "/tmp/a.el"))
          (with-current-buffer long
            (setq buffer-file-name "/tmp/a-very-long-file-name.el"))
          (let* ((buffers (list short long))
                 (short-label (ri-tabs--tab-label
                               short (ri-tabs--tab-name short buffers nil)
                               'active))
                 (long-label (ri-tabs--tab-label
                              long (ri-tabs--tab-name long buffers nil)
                              'inactive)))
            (should (< (string-width short-label)
                       (string-width long-label)))
            (should (equal (substring-no-properties short-label)
                           " [ ] a.el "))
            (should (equal (substring-no-properties long-label)
                           " [ ] a-very-long-file-name.el "))))
      (mapc #'kill-buffer (list short long)))))

(ert-deftest ri-tabs-test-tab-face-follows-semantic-state ()
  (should (eq (ri-tabs--tab-face 'active) 'ri-tabs-current-tab))
  (should (eq (ri-tabs--tab-face 'visible) 'ri-tabs-visible-tab))
  (should (eq (ri-tabs--tab-face 'inactive) 'ri-tabs-tab)))

(ert-deftest ri-tabs-test-color-hierarchy-has-explicit-backgrounds ()
  (should (equal (face-background 'ri-tabs-current-tab nil t) "#ffffff"))
  (should (equal (face-background 'ri-tabs-bar nil t) "#f4f4f4"))
  (should (equal (face-background 'ri-tabs-visible-tab nil t) "#8faec7"))
  (should (equal (face-background 'ri-tabs-tab nil t) "#989898")))

(ert-deftest ri-tabs-test-surface-buffer-uses-bar-background-face ()
  (let ((ri-tabs--surface-buffers (make-hash-table :test #'eq))
        (buffer nil))
    (unwind-protect
        (progn
          (setq buffer (ri-tabs--surface-buffer (selected-frame)))
          (with-current-buffer buffer
            (should buffer-face-mode)
            (should (eq buffer-face-mode-face 'ri-tabs-bar))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ri-tabs-test-buffer-state-prefers-active-over-visible ()
  (let ((active (generate-new-buffer "ri-tabs-state-active"))
        (visible (generate-new-buffer "ri-tabs-state-visible"))
        (inactive (generate-new-buffer "ri-tabs-state-inactive")))
    (unwind-protect
        (let ((visible-buffers (list active visible)))
          (should (eq (ri-tabs--buffer-state active active visible-buffers)
                      'active))
          (should (eq (ri-tabs--buffer-state visible active visible-buffers)
                      'visible))
          (should (eq (ri-tabs--buffer-state inactive active visible-buffers)
                      'inactive)))
      (mapc #'kill-buffer (list active visible inactive)))))

(ert-deftest ri-tabs-test-current-tab-face-is-black-on-white ()
  (should (equal (face-foreground 'ri-tabs-current-tab nil t) "black"))
  (should (equal (face-background 'ri-tabs-current-tab nil t) "#ffffff"))
  (should (eq (face-attribute 'ri-tabs-current-tab :weight nil t) 'bold))
  (should-not (face-attribute 'ri-tabs-current-tab :box nil t)))

(ert-deftest ri-tabs-test-current-tab-tty-background-is-pure-white ()
  (skip-unless
   (and (not noninteractive)
        (not (display-graphic-p))
        (terminal-live-p (frame-terminal))
        (= (display-color-cells) 16777216)))
  (let* ((background (face-background 'ri-tabs-current-tab nil t))
         (description (tty-color-desc background)))
    (should (equal background "#ffffff"))
    (should (equal (nthcdr 2 description) '(65535 65535 65535)))))

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

(ert-deftest ri-tabs-test-restores-two-marks-without-explicit-visits ()
  (ri-tabs-test-with-persistence
    (let* ((first
            (ri-tabs-test--make-file ri-tabs-test-root "restore-a.el"))
           (second
            (ri-tabs-test--make-file ri-tabs-test-root "restore-b.el"))
           (first-id (ri-tabs-test--file-id first))
           (second-id (ri-tabs-test--file-id second))
           (ids (sort (list first-id second-id) #'string-lessp)))
      (ri-tabs-test--store-files first second)
      (should-not (ri-tabs-test--buffers-for-id first-id))
      (should-not (ri-tabs-test--buffers-for-id second-id))
      (ri-tabs-mode 1)
      (dolist (file-id ids)
        (let ((buffers (ri-tabs-test--buffers-for-id file-id)))
          (should (= (length buffers) 1))
          (should (ri-tabs-buffer-marked-p (car buffers)))))
      (should
       (equal
        (mapcar #'ri-tabs--buffer-file-id
                (ri-tabs--marked-buffer-list))
        ids)))))

(ert-deftest ri-tabs-test-fresh-store-restores-all-marks-from-disk ()
  (ri-tabs-test-with-persistence
    (let* ((first-file
            (ri-tabs-test--make-file ri-tabs-test-root "disk-a.el"))
           (second-file
            (ri-tabs-test--make-file ri-tabs-test-root "disk-b.el"))
           (first-id (ri-tabs-test--file-id first-file))
           (second-id (ri-tabs-test--file-id second-file)))
      (ri-tabs-test--store-files)
      (ri-tabs-mode 1)
      (let ((first (ri-tabs-test--visit-file first-file))
            (second (ri-tabs-test--visit-file second-file)))
        (ri-tabs-mark-buffer first)
        (ri-tabs-mark-buffer second)
        (ri-tabs-mode -1)
        (setq ri-tabs--marks-store (ri-tabs-test--make-store))
        (ri-tabs-test--kill-buffer first)
        (ri-tabs-test--kill-buffer second))
      (ri-tabs-mode 1)
      (dolist (file-id (list first-id second-id))
        (let ((buffers (ri-tabs-test--buffers-for-id file-id)))
          (should (= (length buffers) 1))
          (should (ri-tabs-buffer-marked-p (car buffers))))))))

(ert-deftest ri-tabs-test-startup-defers-and-restores-each-file-once ()
  (ri-tabs-test-with-persistence
    (let* ((first
            (ri-tabs-test--make-file ri-tabs-test-root "deferred-a.el"))
           (second
            (ri-tabs-test--make-file ri-tabs-test-root "deferred-b.el"))
           (first-id (ri-tabs-test--file-id first))
           (second-id (ri-tabs-test--file-id second))
           (find-file-noselect-function
            (symbol-function 'find-file-noselect))
           opens)
      (ri-tabs-test--store-files first second)
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (&rest args)
                   (push (car args) opens)
                   (apply find-file-noselect-function args))))
        (let ((after-init-time nil))
          (ri-tabs-mode 1)
          (ri-tabs-mode 1))
        (should-not (ri-tabs-test--buffers-for-id first-id))
        (should-not (ri-tabs-test--buffers-for-id second-id))
        (ri-tabs--startup-activate)
        (ri-tabs--startup-activate))
      (should (= (cl-count first-id opens :test #'equal) 1))
      (should (= (cl-count second-id opens :test #'equal) 1))
      (should (= (length (ri-tabs-test--buffers-for-id first-id)) 1))
      (should (= (length (ri-tabs-test--buffers-for-id second-id)) 1)))))

(ert-deftest ri-tabs-test-post-startup-restore-is-immediate ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file ri-tabs-test-root "immediate.el"))
           (file-id (ri-tabs-test--file-id file)))
      (ri-tabs-test--store-files file)
      (let ((after-init-time '(1)))
        (ri-tabs-mode 1)
        (let ((buffers (ri-tabs-test--buffers-for-id file-id)))
          (should (= (length buffers) 1))
          (should (ri-tabs-buffer-marked-p (car buffers))))))))

(ert-deftest ri-tabs-test-restore-reuses-already-live-buffer ()
  (ri-tabs-test-with-persistence
    (let* ((live-file
            (ri-tabs-test--make-file ri-tabs-test-root "already-live.el"))
           (missing-file
            (ri-tabs-test--make-file ri-tabs-test-root "missing-live.el"))
           (live-id (ri-tabs-test--file-id live-file))
           (missing-id (ri-tabs-test--file-id missing-file))
           (live-buffer (ri-tabs-test--visit-file live-file)))
      (ri-tabs-test--store-files live-file missing-file)
      (ri-tabs-mode 1)
      (let ((live-buffers (ri-tabs-test--buffers-for-id live-id))
            (restored-buffers (ri-tabs-test--buffers-for-id missing-id)))
        (should (equal live-buffers (list live-buffer)))
        (should (= (length restored-buffers) 1))
        (should (ri-tabs-buffer-marked-p live-buffer))
        (should (ri-tabs-buffer-marked-p (car restored-buffers)))))))

(ert-deftest ri-tabs-test-activation-is-idempotent ()
  (ri-tabs-test-with-persistence
    (let* ((first
            (ri-tabs-test--make-file ri-tabs-test-root "idempotent-a.el"))
           (second
            (ri-tabs-test--make-file ri-tabs-test-root "idempotent-b.el"))
           (first-id (ri-tabs-test--file-id first))
           (second-id (ri-tabs-test--file-id second))
           (find-file-noselect-function
            (symbol-function 'find-file-noselect))
           (calls 0))
      (ri-tabs-test--store-files first second)
      (ri-tabs-mode 1)
      (let ((first-buffer
             (car (ri-tabs-test--buffers-for-id first-id)))
            (second-buffer
             (car (ri-tabs-test--buffers-for-id second-id))))
        (cl-letf (((symbol-function 'find-file-noselect)
                   (lambda (&rest args)
                     (cl-incf calls)
                     (apply find-file-noselect-function args))))
          (ri-tabs--activate))
        (should (zerop calls))
        (should
         (equal (ri-tabs-test--buffers-for-id first-id)
                (list first-buffer)))
        (should
         (equal (ri-tabs-test--buffers-for-id second-id)
                (list second-buffer)))))))

(ert-deftest ri-tabs-test-restore-preserves-selection-and-windows ()
  (ri-tabs-test-with-persistence
    (let ((first
           (ri-tabs-test--make-file ri-tabs-test-root "windows-a.el"))
          (second
           (ri-tabs-test--make-file ri-tabs-test-root "windows-b.el"))
          (selected-buffer (generate-new-buffer "ri-tabs-selected"))
          (other-buffer (generate-new-buffer "ri-tabs-other")))
      (push selected-buffer ri-tabs-test--buffers)
      (push other-buffer ri-tabs-test--buffers)
      (ri-tabs-test--store-files first second)
      (with-current-buffer selected-buffer
        (dotimes (line 100)
          (insert (format "line %d\n" line))))
      (save-window-excursion
        (delete-other-windows)
        (switch-to-buffer selected-buffer)
        (goto-char 200)
        (let* ((selected-window (selected-window))
               (other-window (split-window-below)))
          (set-window-buffer other-window other-buffer)
          (set-window-start selected-window 80)
          (let ((window-count
                 (length (ri-tabs-test--ordinary-windows)))
                (other-displayed-buffer
                 (window-buffer other-window))
                (selected-point (point))
                (selected-start (window-start selected-window))
                (displayed-buffer (window-buffer selected-window)))
            (ri-tabs-mode 1)
            (should (eq (current-buffer) selected-buffer))
            (should (eq (selected-window) selected-window))
            (should (eq (window-buffer selected-window)
                        displayed-buffer))
            (should (= (point) selected-point))
            (should (= (window-start selected-window)
                       selected-start))
            (should
             (= (length (ri-tabs-test--ordinary-windows))
                window-count))
            (should
             (eq (window-buffer other-window)
                 other-displayed-buffer))))))))

(ert-deftest ri-tabs-test-dead-tab-actions-are-harmless ()
  (ri-tabs-test-with-tab-bar-state
    (let ((dead (generate-new-buffer "ri-tabs-dead"))
          (survivor (generate-new-buffer "ri-tabs-survivor"))
          (refreshes 0))
      (with-current-buffer dead
        (setq buffer-file-name "/tmp/ri-tabs-dead.el"))
      (set-window-buffer (selected-window) survivor)
      (kill-buffer dead)
      (cl-letf (((symbol-function 'ri-tabs--refresh)
                 (lambda (&rest _)
                   (cl-incf refreshes))))
        (ri-tabs--select-buffer (selected-frame) dead)
        (ri-tabs--close-buffer dead)
        (should (= refreshes 2))
        (should (eq (window-buffer (selected-window)) survivor)))
      (kill-buffer survivor))))

(ert-deftest ri-tabs-test-frame-selected-window-routes-minibuffer-origin ()
  (let ((frame (selected-frame))
        (origin (selected-window))
        (minibuffer (minibuffer-window)))
    (cl-letf (((symbol-function 'active-minibuffer-window)
               (lambda () minibuffer))
              ((symbol-function 'minibuffer-selected-window)
               (lambda () origin)))
      (should (eq (ri-tabs--frame-selected-window frame) origin)))))

(ert-deftest ri-tabs-test-close-action-preserves-persistent-mark ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file
             ri-tabs-test-root "rendered-close.el"))
           (file-id (ri-tabs-test--file-id file))
           buffer)
      (ri-tabs-test--store-files file)
      (ri-tabs-mode 1)
      (setq buffer (car (ri-tabs-test--buffers-for-id file-id)))
      (ri-tabs--close-buffer buffer)
      (should-not (buffer-live-p buffer))
      (should
       (member file-id
               (plist-get (ri-tabs--read-state) :files))))))
(ert-deftest ri-tabs-test-context-menu-targets-file-buffer ()
  (ri-tabs-test-with-persistence
    (let ((buffer
           (ri-tabs-test--visit-file
            (ri-tabs-test--make-file
             ri-tabs-test-root "context-menu.el"))))
      (ri-tabs-test--store-files)
      (ri-tabs-mode 1)
      (let* ((menu
              (ri-tabs--context-menu (selected-frame) buffer))
             (select (assq 'select (cdr menu)))
             (toggle (assq 'toggle-mark (cdr menu)))
             (close (assq 'close (cdr menu))))
        (should (equal (nth 1 (cdr select)) "Select"))
        (should (equal (nth 1 (cdr toggle)) "Mark"))
        (funcall (nth 2 (cdr toggle)))
        (should (ri-tabs-buffer-marked-p buffer))
        (setq menu
              (ri-tabs--context-menu (selected-frame) buffer)
              toggle (assq 'toggle-mark (cdr menu)))
        (should (equal (nth 1 (cdr toggle)) "Unmark"))
        (funcall (nth 2 (cdr close)))
        (should-not (buffer-live-p buffer))))))



(ert-deftest ri-tabs-test-close-does-not-immediately-reopen-mark ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file ri-tabs-test-root "close.el"))
           (file-id (ri-tabs-test--file-id file)))
      (ri-tabs-test--store-files file)
      (ri-tabs-mode 1)
      (ri-tabs-test--kill-buffer
       (car (ri-tabs-test--buffers-for-id file-id)))
      (should ri-tabs-mode)
      (should-not (ri-tabs-test--buffers-for-id file-id))
      (should
       (member file-id (plist-get (ri-tabs--read-state) :files))))))

(ert-deftest ri-tabs-test-reenable-restores-closed-mark ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file ri-tabs-test-root "reenable-close.el"))
           (file-id (ri-tabs-test--file-id file)))
      (ri-tabs-test--store-files file)
      (ri-tabs-mode 1)
      (ri-tabs-test--kill-buffer
       (car (ri-tabs-test--buffers-for-id file-id)))
      (should-not (ri-tabs-test--buffers-for-id file-id))
      (ri-tabs-mode -1)
      (ri-tabs-mode 1)
      (let ((buffers (ri-tabs-test--buffers-for-id file-id)))
        (should (= (length buffers) 1))
        (should (ri-tabs-buffer-marked-p (car buffers)))))))

(ert-deftest ri-tabs-test-explicit-unmark-prevents-restoration ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file ri-tabs-test-root "unmark-restore.el"))
           (file-id (ri-tabs-test--file-id file)))
      (ri-tabs-test--store-files file)
      (ri-tabs-mode 1)
      (let ((buffer (car (ri-tabs-test--buffers-for-id file-id))))
        (ri-tabs-unmark-buffer buffer)
        (ri-tabs-test--kill-buffer buffer))
      (ri-tabs-mode -1)
      (ri-tabs-mode 1)
      (should-not (ri-tabs-test--buffers-for-id file-id))
      (should-not
       (member file-id (plist-get (ri-tabs--read-state) :files))))))

(ert-deftest ri-tabs-test-empty-initialized-state-opens-nothing ()
  (ri-tabs-test-with-persistence
    (let* ((live-file
            (ri-tabs-test--make-file ri-tabs-test-root "empty-live.el"))
           (closed-file
            (ri-tabs-test--make-file ri-tabs-test-root "empty-closed.el"))
           (closed-id (ri-tabs-test--file-id closed-file))
           (live-buffer (ri-tabs-test--visit-file live-file)))
      (ri-tabs-test--store-files)
      (ri-tabs-mode 1)
      (should-not (ri-tabs-buffer-marked-p live-buffer))
      (should-not (ri-tabs-test--buffers-for-id closed-id))
      (should (equal (ri-tabs--read-state)
                     '(:version 1 :files nil))))))

(ert-deftest ri-tabs-test-deferred-first-enable-initializes-once ()
  (ri-tabs-test-with-persistence
    (let* ((first-file
            (ri-tabs-test--make-file ri-tabs-test-root "boundary-a.el"))
           (second-file
            (ri-tabs-test--make-file ri-tabs-test-root "boundary-b.el"))
           (first (ri-tabs-test--visit-file first-file))
           (second nil)
           (write-state-function
            (symbol-function 'ri-tabs--write-state))
           (writes 0))
      (cl-letf (((symbol-function 'ri-tabs--write-state)
                 (lambda (state)
                   (cl-incf writes)
                   (funcall write-state-function state))))
        (let ((after-init-time nil))
          (ri-tabs-mode 1)
          (setq second (ri-tabs-test--visit-file second-file)))
        (should (null (ri-tabs--read-state)))
        (ri-tabs--startup-activate))
      (should (= writes 1))
      (should (ri-tabs-buffer-marked-p first))
      (should (ri-tabs-buffer-marked-p second))
      (should
       (equal
        (plist-get (ri-tabs--read-state) :files)
        (sort (list (ri-tabs--buffer-file-id first)
                    (ri-tabs--buffer-file-id second))
              #'string-lessp))))))

(ert-deftest ri-tabs-test-missing-file-remains-marked-without-buffer ()
  (ri-tabs-test-with-persistence
    (let* ((existing
            (ri-tabs-test--make-file ri-tabs-test-root "available.el"))
           (missing
            (expand-file-name "missing.el" ri-tabs-test-root))
           (existing-id (ri-tabs-test--file-id existing))
           (missing-id (ri-tabs-test--file-id missing))
           warnings)
      (ri-tabs-test--store-files existing missing)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest warning)
                   (push warning warnings))))
        (ri-tabs-mode 1))
      (should
       (ri-tabs-buffer-marked-p
        (car (ri-tabs-test--buffers-for-id existing-id))))
      (should-not (ri-tabs-test--buffers-for-id missing-id))
      (should
       (= (cl-count 'ri-tabs warnings :key #'car :test #'eq) 1))
      (should
       (equal
        (plist-get (ri-tabs--read-state) :files)
        (sort (list existing-id missing-id) #'string-lessp))))))

(ert-deftest ri-tabs-test-one-restore-failure-does-not-block-later-files ()
  (ri-tabs-test-with-persistence
    (let* ((first
            (ri-tabs-test--make-file ri-tabs-test-root "failure-a.el"))
           (failing
            (ri-tabs-test--make-file ri-tabs-test-root "failure-b.el"))
           (last
            (ri-tabs-test--make-file ri-tabs-test-root "failure-c.el"))
           (first-id (ri-tabs-test--file-id first))
           (failing-id (ri-tabs-test--file-id failing))
           (last-id (ri-tabs-test--file-id last))
           (find-file-noselect-function
            (symbol-function 'find-file-noselect))
           warnings)
      (ri-tabs-test--store-files first failing last)
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (&rest args)
                   (if (equal (car args) failing-id)
                       (signal 'file-error
                               (list "Synthetic restore failure"
                                     failing-id))
                     (apply find-file-noselect-function args))))
                ((symbol-function 'display-warning)
                 (lambda (&rest warning)
                   (push warning warnings))))
        (ri-tabs-mode 1))
      (should (= (length (ri-tabs-test--buffers-for-id first-id)) 1))
      (should-not (ri-tabs-test--buffers-for-id failing-id))
      (should (= (length (ri-tabs-test--buffers-for-id last-id)) 1))
      (should
       (= (cl-count 'ri-tabs warnings :key #'car :test #'eq) 1))
      (should
       (equal
        (plist-get (ri-tabs--read-state) :files)
        (sort (list first-id failing-id last-id) #'string-lessp))))))

(ert-deftest ri-tabs-test-malformed-state-restores-and-writes-nothing ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file ri-tabs-test-root "never-open.el"))
           (file-id (ri-tabs-test--file-id file))
           (invalid (list :version 99 :files (list file-id)))
           (find-file-calls 0)
           (write-calls 0)
           warnings)
      (setf (multisession-value ri-tabs--marks-store) invalid)
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (&rest _args)
                   (cl-incf find-file-calls)))
                ((symbol-function 'ri-tabs--write-state)
                 (lambda (_state)
                   (cl-incf write-calls)))
                ((symbol-function 'display-warning)
                 (lambda (&rest warning)
                   (push warning warnings))))
        (ri-tabs-mode 1))
      (should (zerop find-file-calls))
      (should (zerop write-calls))
      (should-not (ri-tabs-test--buffers-for-id file-id))
      (should
       (= (cl-count 'ri-tabs warnings :key #'car :test #'eq) 1))
      (should
       (equal (multisession-value ri-tabs--marks-store)
              invalid)))))

(ert-deftest ri-tabs-test-canonical-live-duplicates-are-not-reopened ()
  (ri-tabs-test-with-persistence
    (let* ((real-file
            (ri-tabs-test--make-file ri-tabs-test-root "canonical.el"))
           (link-file
            (expand-file-name "canonical-link.el" ri-tabs-test-root))
           (file-id (ri-tabs-test--file-id real-file))
           (first nil)
           (second (generate-new-buffer "ri-tabs-canonical-duplicate"))
           (find-file-calls 0))
      (make-symbolic-link real-file link-file)
      (ri-tabs-test--store-files real-file)
      (setq first (ri-tabs-test--visit-file link-file))
      (push second ri-tabs-test--buffers)
      (with-current-buffer second
        (set-visited-file-name real-file t))
      (should (= (length (ri-tabs-test--buffers-for-id file-id)) 2))
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (&rest _args)
                   (cl-incf find-file-calls))))
        (ri-tabs-mode 1))
      (should (zerop find-file-calls))
      (should (= (length (ri-tabs-test--buffers-for-id file-id)) 2))
      (should (ri-tabs-buffer-marked-p first))
      (should (ri-tabs-buffer-marked-p second)))))

(ert-deftest ri-tabs-test-disable-cancels-deferred-restoration ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--make-file ri-tabs-test-root "cancel.el"))
           (file-id (ri-tabs-test--file-id file)))
      (ri-tabs-test--store-files file)
      (let ((after-init-time nil))
        (ri-tabs-mode 1)
        (should-not (ri-tabs-test--buffers-for-id file-id))
        (ri-tabs-mode -1))
      (ri-tabs--startup-activate)
      (should-not ri-tabs-mode)
      (should-not (ri-tabs-test--buffers-for-id file-id)))))

(ert-deftest ri-tabs-test-restoration-batches-global-refresh ()
  (ri-tabs-test-with-persistence
    (let ((first
           (ri-tabs-test--make-file ri-tabs-test-root "refresh-a.el"))
          (second
           (ri-tabs-test--make-file ri-tabs-test-root "refresh-b.el"))
          (global-refreshes 0))
      (ri-tabs-test--store-files first second)
      (cl-letf (((symbol-function 'force-mode-line-update)
                 (lambda (&optional all)
                   (when all
                     (cl-incf global-refreshes)))))
        (ri-tabs-mode 1))
      (should (= global-refreshes 1)))))



(ert-deftest ri-tabs-test-git-environment-owner-uses-external-git-dir ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((work-tree (expand-file-name "dotfiles-home" ri-tabs-test-root))
             (git-dir (expand-file-name "dotfiles.git" ri-tabs-test-root))
             (file (ri-tabs-test--make-file work-tree "config/test.el"))
             (buffer (ri-tabs-test--visit-file file))
             (process-environment (copy-sequence process-environment)))
        (make-directory git-dir t)
        (let ((default-directory (file-name-as-directory work-tree)))
          (unless (eq 0 (process-file "git" nil nil nil
                                      "--git-dir" git-dir
                                      "--work-tree" work-tree
                                      "init" "--quiet"))
            (error "Could not initialize external Git directory")))
        (setenv "GIT_DIR" git-dir)
        (setenv "GIT_WORK_TREE" work-tree)
        (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
        (with-current-buffer buffer
          (setq default-directory (file-name-as-directory work-tree)))
        (ri-tabs-mark-buffer buffer)
        (should (equal (ri-tabs--frame-owner)
                       (ri-tabs--canonical-directory work-tree)))))))

(ert-deftest ri-tabs-test-directory-owner-remains-first-owner-across-contexts ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((plain-root (expand-file-name "plain" ri-tabs-test-root))
             (repo (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-after-plain"))
             (plain-file (ri-tabs-test--make-file plain-root "a.txt"))
             (repo-file (ri-tabs-test--make-file repo "b.el"))
             (plain-buffer (ri-tabs-test--visit-file plain-file))
             (repo-buffer (ri-tabs-test--visit-file repo-file)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
        (with-current-buffer plain-buffer
          (setq default-directory (file-name-as-directory plain-root)))
        (ri-tabs-mark-buffer plain-buffer)
        (let ((owner (ri-tabs--frame-owner)))
          (ri-tabs-mark-buffer repo-buffer)
          (should (equal (ri-tabs--frame-owner) owner))
          (should (equal (ri-tabs--state-owner-files (ri-tabs--read-state) owner)
                         (sort (list (ri-tabs-test--file-id plain-file)
                                     (ri-tabs-test--file-id repo-file))
                               #'string-lessp))))))))

(ert-deftest ri-tabs-test-v2-state-migrates-to-v3-owners ()
  (ri-tabs-test-with-persistence
    (let* ((owner (ri-tabs--canonical-directory ri-tabs-test-root))
           (file (ri-tabs-test--make-file ri-tabs-test-root "v2.el"))
           (file-id (ri-tabs-test--file-id file))
           (state (ri-tabs--normalize-state
                   (list :version 2
                         :repos (list (cons owner (list file-id)))
                         :unresolved nil))))
      (should (eql (plist-get state :version) 3))
      (should (equal (plist-get state :owners)
                     (list (cons owner (list file-id))))))))

(provide 'ri-tabs-test)

;;; ri-tabs-test.el ends here

(defun ri-tabs-test--make-git-repo (root name)
  "Create a real Git repository directory NAME below ROOT."
  (let ((repo (expand-file-name name root)))
    (make-directory repo t)
    (let ((default-directory (file-name-as-directory repo)))
      (unless (eq 0 (process-file "git" nil nil nil "init" "--quiet"))
        (error "Could not initialize test Git repository: %s" repo)))
    repo))

(defmacro ri-tabs-test-with-owner-frame (&rest body)
  "Run BODY while restoring the selected frame's Ri owner parameter."
  (declare (indent 0) (debug t))
  `(let* ((frame (selected-frame))
          (saved-owner (frame-parameter frame 'ri-tabs-owner)))
     (unwind-protect
         (progn ,@body)
       (set-frame-parameter frame 'ri-tabs-owner saved-owner))))

(ert-deftest ri-tabs-test-first-mark-owns-cross-repository-set ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
             (repo-b (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-b"))
             (file-a (ri-tabs-test--make-file repo-a "a.el"))
             (file-b (ri-tabs-test--make-file repo-b "b.el"))
             (buffer-a (ri-tabs-test--visit-file file-a))
             (buffer-b (ri-tabs-test--visit-file file-b)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
        (ri-tabs-mark-buffer buffer-a)
        (let ((owner (ri-tabs--frame-owner)))
          (should (equal owner (ri-tabs--canonical-directory repo-a)))
          (ri-tabs-mark-buffer buffer-b)
          (let ((state (ri-tabs--read-state)))
            (should
             (equal (ri-tabs--state-owner-files state owner)
                    (sort (list (ri-tabs-test--file-id file-a)
                                (ri-tabs-test--file-id file-b))
                          #'string-lessp)))
            (should-not
             (ri-tabs--state-has-owner-p
              state (ri-tabs--canonical-directory repo-b)))))))))

(ert-deftest ri-tabs-test-opening-other-repo-does-not-change-owner ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
             (repo-b (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-b"))
             (file-a (ri-tabs-test--make-file repo-a "a.el"))
             (file-b (ri-tabs-test--make-file repo-b "b.el"))
             (buffer-a (ri-tabs-test--visit-file file-a))
             (buffer-b (ri-tabs-test--visit-file file-b)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
        (ri-tabs-mark-buffer buffer-a)
        (let ((owner (ri-tabs--frame-owner)))
          (set-window-buffer (selected-window) buffer-b)
          (ri-tabs--sync-visited-buffer)
          (should (equal (ri-tabs--frame-owner) owner)))))))

(ert-deftest ri-tabs-test-explicit-owner-context-switch-selects-independent-set ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
             (repo-b (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-b"))
             (file-a (ri-tabs-test--make-file repo-a "a.el"))
             (file-b (ri-tabs-test--make-file repo-b "b.el"))
             (buffer-a (ri-tabs-test--visit-file file-a))
             (buffer-b (ri-tabs-test--visit-file file-b)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
        (ri-tabs-mark-buffer buffer-a)
        (ri-tabs-switch-owner-context buffer-b)
        (ri-tabs-mark-buffer buffer-b)
        (let* ((state (ri-tabs--read-state))
               (owner-a (ri-tabs--canonical-directory repo-a))
               (owner-b (ri-tabs--canonical-directory repo-b)))
          (should (equal (ri-tabs--state-owner-files state owner-a)
                         (list (ri-tabs-test--file-id file-a))))
          (should (equal (ri-tabs--state-owner-files state owner-b)
                         (list (ri-tabs-test--file-id file-b))))
          (should (equal (ri-tabs--frame-owner) owner-b)))))))

(ert-deftest ri-tabs-test-existing-owner-allows-mark-outside-git ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
             (outside-root (expand-file-name "outside" ri-tabs-test-root))
             (file-a (ri-tabs-test--make-file repo-a "a.el"))
             (outside (ri-tabs-test--make-file outside-root "notes.txt"))
             (buffer-a (ri-tabs-test--visit-file file-a))
             (outside-buffer (ri-tabs-test--visit-file outside)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
        (ri-tabs-mark-buffer buffer-a)
        (let ((owner (ri-tabs--frame-owner)))
          (ri-tabs-mark-buffer outside-buffer)
          (should
           (member (ri-tabs-test--file-id outside)
                   (ri-tabs--state-owner-files (ri-tabs--read-state) owner))))))))

(ert-deftest ri-tabs-test-first-mark-outside-git-uses-current-directory-owner ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((outside-root (expand-file-name "outside" ri-tabs-test-root))
             (outside (ri-tabs-test--make-file outside-root "notes.txt"))
             (buffer (ri-tabs-test--visit-file outside)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
        (with-current-buffer buffer
          (setq default-directory (file-name-as-directory outside-root)))
        (ri-tabs-mark-buffer buffer)
        (let ((owner (ri-tabs--canonical-directory outside-root)))
          (should (equal (ri-tabs--frame-owner) owner))
          (should (equal (ri-tabs--state-owner-files (ri-tabs--read-state) owner)
                         (list (ri-tabs-test--file-id outside)))))))))

(ert-deftest ri-tabs-test-rename-migrates-file-through-all-owner-sets ()
  (ri-tabs-test-with-persistence
    (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
           (repo-b (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-b"))
           (old (ri-tabs-test--make-file repo-a "shared.el"))
           (new (expand-file-name "renamed.el" repo-b))
           (old-id (ri-tabs-test--file-id old))
           (new-id (expand-file-name new))
           (owner-a (ri-tabs--canonical-directory repo-a))
           (owner-b (ri-tabs--canonical-directory repo-b))
           (state (ri-tabs--make-state
                   (list (cons owner-a (list old-id))
                         (cons owner-b (list old-id))))))
      (setq state (ri-tabs--replace-file-id state old-id new-id))
      (should (equal (ri-tabs--state-owner-files state owner-a)
                     (list new-id)))
      (should (equal (ri-tabs--state-owner-files state owner-b)
                     (list new-id))))))

(ert-deftest ri-tabs-test-v1-migration-keeps-one-owner-for-whole-list ()
  (ri-tabs-test-with-persistence
    (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
           (repo-b (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-b"))
           (file-a (ri-tabs-test--make-file repo-a "a.el"))
           (file-b (ri-tabs-test--make-file repo-b "b.el"))
           (id-a (ri-tabs-test--file-id file-a))
           (id-b (ri-tabs-test--file-id file-b))
           (state (ri-tabs--normalize-state
                   (list :version 1 :files (list id-a id-b))))
           (owner-a (ri-tabs--canonical-directory repo-a)))
      (should (equal (ri-tabs--state-owner-files state owner-a)
                     (sort (list id-a id-b) #'string-lessp)))
      (should (= (length (plist-get state :owners)) 1)))))


(ert-deftest ri-tabs-test-faces-are-independent-of-native-tab-bar-faces ()
  (should (eq (face-attribute 'ri-tabs-tab :inherit nil t)
              'mode-line-inactive))
  (should (eq (face-attribute 'ri-tabs-visible-tab :inherit nil t)
              'mode-line-inactive))
  (should (eq (face-attribute 'ri-tabs-current-tab :inherit nil t)
              'mode-line-active)))

(ert-deftest ri-tabs-test-tab-label-has-no-visual-mouse-face ()
  (let ((buffer (generate-new-buffer "ri-tabs-label-hover")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq buffer-file-name "/tmp/hover.el"))
          (dolist (tab-state '(active visible inactive))
            (let ((label (ri-tabs--tab-label buffer "hover.el" tab-state)))
              (should (eq (get-text-property 0 'face label)
                          (ri-tabs--tab-face tab-state)))
              (should (stringp (get-text-property 0 'help-echo label)))
              (should-not (text-property-not-all
                           0 (length label) 'mouse-face nil label)))))
      (kill-buffer buffer))))

(ert-deftest ri-tabs-test-prepare-item-display-keeps-hit-testing-without-hover ()
  (let* ((frame (selected-frame))
         (buffer (generate-new-buffer "ri-tabs-hit-test"))
         (item (ri-tabs--make-item :buffer buffer :display " Tab "))
         (text (ri-tabs--prepare-item-display frame item)))
    (unwind-protect
        (progn
          (should (eq (get-text-property 1 'ri-tabs-frame text) frame))
          (should (eq (get-text-property 1 'ri-tabs-buffer text) buffer))
          (should (eq (get-text-property 1 'pointer text) 'hand))
          (should-not (text-property-not-all
                       0 (length text) 'mouse-face nil text)))
      (kill-buffer buffer))))

(ert-deftest ri-tabs-test-visible-item-model-carries-final-state ()
  (let ((current (generate-new-buffer "ri-tabs-model-current"))
        (marked-modified (generate-new-buffer "ri-tabs-model-marked")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer current
            (setq buffer-file-name "/tmp/current.el"))
          (with-current-buffer marked-modified
            (setq buffer-file-name "/tmp/marked.el"
                  ri-tabs--marked-p t)
            (set-buffer-modified-p t))
          (set-window-buffer (selected-window) current)
          (set-frame-parameter (selected-frame) 'ri-tabs-owner nil)
          (cl-letf (((symbol-function 'ri-tabs--read-state-safely)
                     (lambda () (ri-tabs--make-state)))
                    ((symbol-function 'ri-tabs-file-buffer-list)
                     (lambda () (list marked-modified current))))
            (let ((items (ri-tabs--visible-items (selected-frame))))
              (should (= (length items) 2))
              (should (eq (ri-tabs--item-buffer (nth 0 items))
                          marked-modified))
              (should (ri-tabs--item-marked (nth 0 items)))
              (should (ri-tabs--item-modified (nth 0 items)))
              (should (eq (ri-tabs--item-state (nth 0 items)) 'inactive))
              (should (eq (ri-tabs--item-state (nth 1 items)) 'active))
              (should (equal (substring-no-properties
                              (ri-tabs--item-display (nth 0 items)))
                             " [÷] marked.el "))
              (should (equal (substring-no-properties
                              (ri-tabs--item-display (nth 1 items)))
                             " [ ] current.el ")))))
      (when (buffer-live-p marked-modified)
        (with-current-buffer marked-modified (set-buffer-modified-p nil)))
      (mapc #'kill-buffer (list current marked-modified)))))

(ert-deftest ri-tabs-test-pack-items-exact-boundary-stays-on-one-row ()
  (let ((items '(a b c)))
    (should (equal (ri-tabs--pack-items-into-rows
                    (cl-mapcar #'cons items '(20 30 50)) 100)
                   '((a b c))))))

(ert-deftest ri-tabs-test-pack-items-wraps-without-splitting ()
  (should (equal (ri-tabs--pack-items-into-rows
                  '((a . 60) (b . 50) (c . 40) (d . 70)) 100)
                 '((a) (b c) (d)))))

(ert-deftest ri-tabs-test-pack-items-oversized-item-gets-own-row ()
  (should (equal (ri-tabs--pack-items-into-rows
                  '((wide . 140) (small . 20)) 100)
                 '((wide) (small)))))

(ert-deftest ri-tabs-test-pack-items-empty-input-is-empty ()
  (should-not (ri-tabs--pack-items-into-rows nil 100)))

(ert-deftest ri-tabs-test-render-rows-inserts-explicit-newlines-and-properties ()
  (let* ((frame (selected-frame))
         (first-buffer (generate-new-buffer "ri-tabs-render-first"))
         (second-buffer (generate-new-buffer "ri-tabs-render-second"))
         (first (ri-tabs--make-item :buffer first-buffer :display " A "))
         (second (ri-tabs--make-item :buffer second-buffer :display " B "))
         (text (ri-tabs--render-rows frame `((,first) (,second)))))
    (unwind-protect
        (progn
          (should (equal (substring-no-properties text) " A \n B "))
          (should (eq (get-text-property 1 'ri-tabs-buffer text)
                      first-buffer))
          (should (eq (get-text-property 1 'ri-tabs-frame text) frame))
          (should (eq (get-text-property 1 'pointer text) 'hand))
          (let ((second-pos (1+ (string-search "B" text))))
            (should (eq (get-text-property second-pos 'ri-tabs-buffer text)
                        second-buffer))
            (should (eq (get-text-property second-pos 'ri-tabs-frame text)
                        frame))
            (should (eq (get-text-property second-pos 'pointer text) 'hand)))
          (should-not (text-property-not-all
                       0 (length text) 'mouse-face nil text)))
      (mapc #'kill-buffer (list first-buffer second-buffer)))))

(ert-deftest ri-tabs-test-surface-map-routes-only-ri-input ()
  (should (eq (lookup-key ri-tabs--surface-mode-map [down-mouse-1])
              #'ri-tabs--mouse-select))
  (should (eq (lookup-key ri-tabs--surface-mode-map [mouse-2])
              #'ri-tabs--mouse-close))
  (should (eq (lookup-key ri-tabs--surface-mode-map [down-mouse-3])
              #'ri-tabs--mouse-context-menu))
  (should (eq (lookup-key ri-tabs--surface-mode-map [touchscreen-begin])
              #'ri-tabs--touchscreen-begin))
  (dolist (key '([mouse-4] [wheel-up] [wheel-left]))
    (should (eq (lookup-key ri-tabs--surface-mode-map key)
                #'ri-tabs--mouse-previous)))
  (dolist (key '([mouse-5] [wheel-down] [wheel-right]))
    (should (eq (lookup-key ri-tabs--surface-mode-map key)
                #'ri-tabs--mouse-next))))

(ert-deftest ri-tabs-test-mode-leaves-native-tab-bar-state-untouched ()
  (ri-tabs-test-with-persistence
    (let ((before-mode (and tab-bar-mode t))
          (before-format (copy-tree (default-value 'tab-bar-format)))
          (before-show (default-value 'tab-bar-show))
          (before-auto-width (default-value 'tab-bar-auto-width))
          (before-auto-resize auto-resize-tab-bars)
          (before-lines (frame-parameter nil 'tab-bar-lines))
          (before-keep (frame-parameter nil 'tab-bar-lines-keep-state)))
      (ri-tabs-test--store-files)
      (ri-tabs-mode 1)
      (should (eq (and tab-bar-mode t) before-mode))
      (should (equal (default-value 'tab-bar-format) before-format))
      (should (eql (default-value 'tab-bar-show) before-show))
      (should (eql (default-value 'tab-bar-auto-width) before-auto-width))
      (should (eql auto-resize-tab-bars before-auto-resize))
      (should (eql (frame-parameter nil 'tab-bar-lines) before-lines))
      (should (eql (frame-parameter nil 'tab-bar-lines-keep-state)
                   before-keep)))))

(ert-deftest ri-tabs-test-mode-creates-one-dedicated-frame-wide-surface ()
  (ri-tabs-test-with-persistence
    (let ((file (ri-tabs-test--make-file ri-tabs-test-root "surface.el")))
      (ri-tabs-test--store-files file)
      (ri-tabs-mode 1)
      (let ((window (gethash (selected-frame) ri-tabs--surface-windows)))
        (should (window-live-p window))
        (should (window-parameter window 'ri-tabs-surface))
        (should (window-dedicated-p window))
        (should (window-at-side-p window 'top))
        (should-not (window-minibuffer-p window))
        (with-current-buffer (window-buffer window)
          (should buffer-read-only)
          (should-not cursor-type)
          (should-not mode-line-format))))))

(ert-deftest ri-tabs-test-surface-height-follows-packed-row-count ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test--store-files)
    (ri-tabs-mode 1)
    (let ((window (gethash (selected-frame) ri-tabs--surface-windows)))
      (cl-letf (((symbol-function 'ri-tabs--visible-items)
                 (lambda (&optional _frame)
                   (list (ri-tabs--make-item :buffer (current-buffer)
                                             :display "AAAA")
                         (ri-tabs--make-item :buffer (current-buffer)
                                             :display "BBBB")
                         (ri-tabs--make-item :buffer (current-buffer)
                                             :display "CCCC"))))
                ((symbol-function 'ri-tabs--available-width)
                 (lambda (_window) 8))
                ((symbol-function 'ri-tabs--display-width)
                 (lambda (_window _string) 4)))
        (ri-tabs--surface-update (selected-frame))
        (should (= (length (window-parameter window 'ri-tabs-rows)) 2)))
      (cl-letf (((symbol-function 'ri-tabs--visible-items)
                 (lambda (&optional _frame)
                   (list (ri-tabs--make-item :buffer (current-buffer)
                                             :display "AAAA")
                         (ri-tabs--make-item :buffer (current-buffer)
                                             :display "BBBB")
                         (ri-tabs--make-item :buffer (current-buffer)
                                             :display "CCCC"))))
                ((symbol-function 'ri-tabs--available-width)
                 (lambda (_window) 20))
                ((symbol-function 'ri-tabs--display-width)
                 (lambda (_window _string) 4)))
        (ri-tabs--surface-update (selected-frame))
        (should (= (length (window-parameter window 'ri-tabs-rows)) 1))))))

(ert-deftest ri-tabs-test-renderer-follows-selected-editing-window-across-split ()
  (ri-tabs-test-with-tab-bar-state
    (let ((first (generate-new-buffer "ri-tabs-split-first"))
          (second (generate-new-buffer "ri-tabs-split-second")))
      (unwind-protect
          (save-window-excursion
            (with-current-buffer first
              (setq buffer-file-name "/tmp/ri-tabs-split-first.el"
                    ri-tabs--marked-p t))
            (with-current-buffer second
              (setq buffer-file-name "/tmp/ri-tabs-split-second.el"
                    ri-tabs--marked-p t))
            (delete-other-windows)
            (set-window-buffer (selected-window) first)
            (let ((other-window (split-window-below)))
              (set-window-buffer other-window second)
              (cl-letf (((symbol-function 'ri-tabs--read-state-safely)
                         (lambda () ri-tabs--read-error))
                        ((symbol-function 'ri-tabs-file-buffer-list)
                         (lambda () (list first second))))
                (let ((items (ri-tabs--visible-items (selected-frame))))
                  (should (eq (ri-tabs--item-state (nth 0 items)) 'active))
                  (should (eq (ri-tabs--item-state (nth 1 items)) 'visible)))
                (select-window other-window)
                (let ((items (ri-tabs--visible-items (selected-frame))))
                  (should (eq (ri-tabs--item-state (nth 0 items)) 'visible))
                  (should (eq (ri-tabs--item-state (nth 1 items)) 'active))))))
        (mapc #'kill-buffer (list first second))))))

(ert-deftest ri-tabs-test-tab-action-preserves-editing-split-and-native-workspaces ()
  (ri-tabs-test-with-tab-bar-state
    (let ((target (generate-new-buffer "ri-tabs-action-target"))
          (current (generate-new-buffer "ri-tabs-action-current"))
          (other (generate-new-buffer "ri-tabs-action-other")))
      (unwind-protect
          (save-window-excursion
            (with-current-buffer target
              (setq buffer-file-name "/tmp/ri-tabs-action-target.el"))
            (with-current-buffer current
              (setq buffer-file-name "/tmp/ri-tabs-action-current.el"))
            (delete-other-windows)
            (set-window-buffer (selected-window) current)
            (let* ((selected-window (selected-window))
                   (other-window (split-window-below))
                   (native-tabs (copy-tree (frame-parameter nil 'tabs))))
              (set-window-buffer other-window other)
              (ri-tabs--select-buffer (selected-frame) target)
              (should (eq (selected-window) selected-window))
              (should (eq (window-buffer selected-window) target))
              (should (eq (window-buffer other-window) other))
              (should (equal (frame-parameter nil 'tabs) native-tabs))))
        (mapc #'kill-buffer (list target current other))))))

(ert-deftest ri-tabs-test-structurally-ineligible-frame-does-not-get-surface ()
  (ri-tabs-test-with-tab-bar-state
    (let ((frame (selected-frame))
          (ri-tabs-mode t))
      (cl-letf (((symbol-function 'ri-tabs--structurally-ineligible-frame-p)
                 (lambda (candidate) (eq candidate frame))))
        (ri-tabs--surface-update frame)
        (should-not (gethash frame ri-tabs--surface-windows))))))

