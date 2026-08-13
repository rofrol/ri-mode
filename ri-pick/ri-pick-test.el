;;; ri-pick-test.el --- Tests for ri-pick.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri-extend)
(require 'ri-pick)

(defun ri-pick-test--item (label target)
  "Return a picker item named LABEL with TARGET."
  (ri-pick-item-create :label label :search label :target target))

(defmacro ri-pick-test--without-real-ui (&rest body)
  "Run BODY with picker display primitives recorded but inert."
  (declare (indent 0) (debug t))
  `(let (display-action quit-arguments)
     (cl-letf (((symbol-function 'keymap-legend-show)
                (lambda (&rest _arguments)
                  (ert-fail "Picker unexpectedly showed a keymap legend")))
               ((symbol-function 'keymap-legend-hide)
                (lambda ()
                  (ert-fail "Picker unexpectedly hid a keymap legend")))
               ((symbol-function 'display-buffer)
                (lambda (_buffer action)
                  (setq display-action action)
                  (selected-window)))
               ((symbol-function 'set-window-dedicated-p) #'ignore)
               ((symbol-function 'set-window-parameter) #'ignore)
               ((symbol-function 'select-window)
                (lambda (window &rest _) window))
               ((symbol-function 'quit-window)
                (lambda (&rest arguments)
                  (setq quit-arguments arguments))))
       ,@body)))

(ert-deftest ri-pick-test-printable-keys-remain-query-input ()
  (with-temp-buffer
    (ri-pick-mode)
    (dolist (key '("q" "-" "5" "SPC" "s" "d" "f" "S"))
      (should (eq (key-binding (kbd key)) #'ri-pick-self-insert)))))

(ert-deftest ri-pick-test-navigation-and-editing-bindings-remain-active ()
  (dolist (binding
           '(("DEL" . ri-pick-delete-backward)
             ("<backspace>" . ri-pick-delete-backward)
             ("<delete>" . ri-pick-delete-forward)
             ("C-a" . ri-pick-query-beginning)
             ("C-e" . ri-pick-query-end)
             ("C-y" . ri-pick-yank)
             ("C-d" . ri-pick-page-down)
             ("C-u" . ri-pick-page-up)
             ("C-j" . ri-pick-next)
             ("C-k" . ri-pick-previous)
             ("<down>" . ri-pick-next)
             ("<up>" . ri-pick-previous)
             ("RET" . ri-pick-accept)
             ("<return>" . ri-pick-accept)
             ("C-g" . ri-pick-cancel)
             ("<escape>" . ri-pick-cancel)))
    (should (eq (lookup-key ri-pick-mode-map (kbd (car binding)))
                (cdr binding)))))

(ert-deftest ri-pick-test-render-keeps-results-out-of-query-line ()
  (with-temp-buffer
    (ri-pick-mode)
    (let* ((item (ri-pick-test--item "ri-pick/ri-pick.el" 'match))
           (session
            (ri-pick--session-create
             :buffer (current-buffer)
             :items (list item)
             :filtered (list item)
             :index 0
             :offset 0)))
      (let ((ri-pick--session session))
        (ri-pick--render session)
        (goto-char (point-min))
        (insert "ri-pick")
        (ri-pick--query-changed)
        (should (equal (ri-pick--query) "ri-pick"))
        (should (equal (mapcar #'ri-pick-item-target
                               (ri-pick--session-filtered session))
                       '(match)))))))

(ert-deftest ri-pick-test-fuzzy-filter-keeps-duplicate-identities-stable ()
  (let* ((first (ri-pick-test--item "src/main.rs" 'first))
         (second (ri-pick-test--item "tests/main.rs" 'second))
         (other (ri-pick-test--item "README.md" 'other))
         (results (ri-pick--filter-items "main" (list first second other))))
    (should (equal (mapcar #'ri-pick-item-target results)
                   '(first second)))
    (should (equal (mapcar #'ri-pick-item-label results)
                   '("src/main.rs" "tests/main.rs")))))

(ert-deftest ri-pick-test-subsequence-filter-matches-noncontiguous-query ()
  (let ((results
         (ri-pick--filter-items
          "rpl" (list (ri-pick-test--item "ri-pick.el" 'match)
                      (ri-pick-test--item "README" 'miss)))))
    (should (equal (mapcar #'ri-pick-item-target results) '(match)))))

(ert-deftest ri-pick-test-start-uses-display-buffer-child-frame-action ()
  (ri-pick-test--without-real-ui
    (let (closed)
      (unwind-protect
          (progn
            (ri-pick-start
             "Buffer" (list (ri-pick-test--item "one" 1)) #'ignore
             :on-close (lambda (accepted) (setq closed accepted)))
            (should (equal (car display-action)
                           '(display-buffer-in-child-frame)))
            (ri-pick-cancel)
            (should (equal quit-arguments
                           (list t (selected-window))))
            (should-not closed)
            (should-not (ri-pick--active-session)))
        (when (ri-pick--active-session) (ri-pick-cancel))))))

(ert-deftest ri-pick-test-cancel-preserves-extend-exactly ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 2)
    (sr-set-word-mode)
    (should (ri--enter-extend))
    (let ((bounds (ri--selection-bounds))
          (position (point))
          (edge (ri--selection-state-active-edge ri--selection))
          (submode sr-submode))
      (ri-pick-test--without-real-ui
        (unwind-protect
            (progn
              (ri-pick-start "File" nil #'ignore)
              (ri-pick-cancel))
          (when (ri-pick--active-session) (ri-pick-cancel))))
      (should (equal (ri--selection-bounds) bounds))
      (should (= (point) position))
      (should (eq (ri--selection-state-active-edge ri--selection) edge))
      (should (eq sr-submode submode)))))

(ert-deftest ri-pick-test-stale-provider-result-cannot-replace-current-items ()
  (let* ((old (ri-pick-test--item "old" 'old))
         (new (ri-pick-test--item "new" 'new))
         (session (ri-pick--session-create
                   :items (list new) :filtered (list new)
                   :index 0 :offset 0 :generation 2)))
    (let ((ri-pick--session session))
      (ri-pick--provider-success session 1 (list old))
      (should (equal (mapcar #'ri-pick-item-target
                             (ri-pick--session-items session))
                     '(new)))
      (ri-pick--provider-success session 2 (list old))
      (should (equal (mapcar #'ri-pick-item-target
                             (ri-pick--session-items session))
                     '(old))))))

(ert-deftest ri-pick-test-provider-refresh-cancels-previous-work ()
  (let* ((cancelled nil)
        (session (ri-pick--session-create
                  :items nil :filtered nil :index 0 :offset 0
                  :generation 0 :cancel-request
                  (lambda () (setq cancelled t))
                  :provider #'ignore)))
    (let ((ri-pick--session session)
          (ri-pick-query-delay 60))
      (cl-letf (((symbol-function 'ri-pick--query) (lambda () "next"))
                ((symbol-function 'ri-pick--render) #'ignore))
        (unwind-protect
            (progn
              (ri-pick--query-changed)
              (should cancelled)
              (should (= (ri-pick--session-generation session) 1))
              (should (timerp (ri-pick--session-timer session))))
          (ri-pick--cancel-pending session))))))

(ert-deftest ri-pick-test-bottom-edge-ignores-bottom-side-windows ()
  (save-window-excursion
    (let* ((side-buffer (get-buffer-create " *ri-pick-test-bottom*"))
           (side-window
            (display-buffer-in-side-window
             side-buffer '((side . bottom) (window-height . 4))))
           (frame (selected-frame))
           (minibuffer (minibuffer-window frame))
           (expected
            (- (frame-height frame)
               (if (window-live-p minibuffer)
                   (window-total-height minibuffer)
                 0))))
      (unwind-protect
          (progn
            (should (= (ri-pick--bottom-usable-edge frame) expected))
            (should (> expected (nth 1 (window-edges side-window)))))
        (when (buffer-live-p side-buffer)
          (kill-buffer side-buffer))))))

(ert-deftest ri-pick-test-buffer-items-retain-buffer-identity ()
  (let ((first (generate-new-buffer "ri-pick-first"))
        (second (generate-new-buffer "ri-pick-second")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (setq buffer-file-name "/tmp/project/src/main.el"))
          (with-current-buffer second
            (setq buffer-file-name "/tmp/project/tests/main.el"))
          (cl-letf (((symbol-function 'ri-tabs-file-buffer-list)
                     (lambda () (list first second))))
            (let ((items (ri-pick--buffer-items "/tmp/project/")))
              (should (equal (mapcar #'ri-pick-item-label items)
                             '("src/main.el" "tests/main.el")))
              (should (equal (mapcar #'ri-pick-item-target items)
                             (list first second))))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest ri-pick-test-project-file-label-and-target-have-distinct-roles ()
  (let* ((root (make-temp-file "ri-pick-project-" t))
         (file (expand-file-name "src/main.el" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (write-region "" nil file nil 'silent)
          (let ((items (ri-pick--file-items nil root nil)))
            (should (equal (mapcar #'ri-pick-item-label items)
                           '("src/main.el")))
            (should (equal (mapcar #'ri-pick-item-target items)
                           (list file)))))
      (delete-directory root t))))

(ert-deftest ri-pick-test-git-environment-files-cover-work-tree ()
  (skip-unless (executable-find "git"))
  (let* ((root (make-temp-file "ri-pick-git-environment-" t))
         (work-tree (expand-file-name "work-tree" root))
         (git-dir (expand-file-name "repository.git" root))
         (nested (expand-file-name "nested/current" work-tree))
         (global-config (expand-file-name "global.gitconfig" root))
         (root-file (expand-file-name "root file.el" work-tree))
         (nested-file (expand-file-name "nested/current/local.el" work-tree))
         (ignored-file (expand-file-name "ignored.el" work-tree))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (make-directory nested t)
          (make-directory git-dir t)
          (write-region "" nil global-config nil 'silent)
          (write-region "" nil root-file nil 'silent)
          (write-region "" nil nested-file nil 'silent)
          (write-region "" nil ignored-file nil 'silent)
          (write-region "ignored.el\n" nil
                        (expand-file-name ".gitignore" work-tree)
                        nil 'silent)
          (let ((default-directory (file-name-as-directory work-tree)))
            (unless
                (eq 0
                    (process-file
                     "git" nil nil nil
                     "--git-dir" git-dir
                     "--work-tree" work-tree
                     "init" "--quiet"))
              (ert-fail "Could not initialize external Git directory")))
          (setenv "GIT_DIR" git-dir)
          (setenv "GIT_WORK_TREE" work-tree)
          (setenv "GIT_CONFIG_GLOBAL" global-config)
          (setenv "GIT_CONFIG_NOSYSTEM" "1")
          (let ((default-directory (file-name-as-directory nested)))
            (should-not (file-exists-p (expand-file-name ".git" work-tree)))
            (pcase-let
                ((`(,project ,resolved-root ,git-directory)
                  (cl-letf (((symbol-function 'project-current)
                             (lambda (&rest _arguments)
                               (ert-fail
                                "Explicit Git context consulted project.el"))))
                    (ri-pick--project-context))))
              (should-not project)
              (should
               (equal resolved-root
                      (file-name-as-directory (file-truename work-tree))))
              (should (equal git-directory default-directory))
              (let* ((items
                      (ri-pick--file-items
                       project resolved-root git-directory))
                     (labels
                      (sort (mapcar #'ri-pick-item-label items)
                            #'string-lessp))
                     (targets (mapcar #'ri-pick-item-target items)))
                (should
                 (equal labels
                        '(".gitignore"
                          "nested/current/local.el"
                          "root file.el")))
                (should (member (file-truename root-file) targets))
                (should (member (file-truename nested-file) targets))
                (should-not (member (file-truename ignored-file) targets))
                (should (seq-every-p #'file-name-absolute-p targets))))))
      (delete-directory root t))))

(ert-deftest ri-pick-test-ordinary-project-remains-project-backed ()
  (let* ((root (make-temp-file "ri-pick-ordinary-project-" t))
         (project 'ordinary-project)
         (project-file (expand-file-name "src/main.el" root))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (setenv "GIT_DIR" nil)
          (setenv "GIT_WORK_TREE" nil)
          (let ((default-directory (file-name-as-directory root)))
            (cl-letf (((symbol-function 'project-current)
                       (lambda (&rest _arguments) project))
                      ((symbol-function 'project-root)
                       (lambda (value)
                         (should (eq value project))
                         root))
                      ((symbol-function 'ri-tabs-git-work-tree-root)
                       (lambda (_directory)
                         (ert-fail "Ordinary project consulted Git directly"))))
              (should
               (equal (ri-pick--project-context)
                      (list project default-directory nil))))
            (cl-letf (((symbol-function 'project-files)
                       (lambda (value)
                         (should (eq value project))
                         '("src/main.el")))
                      ((symbol-function 'ri-pick--git-files)
                       (lambda (_directory)
                         (ert-fail "Ordinary project used direct Git files")))
                      ((symbol-function 'ri-pick--fallback-files)
                       (lambda (_directory)
                         (ert-fail "Ordinary project used directory fallback"))))
              (let ((items (ri-pick--file-items project default-directory nil)))
                (should
                 (equal (mapcar #'ri-pick-item-label items)
                        '("src/main.el")))
                (should
                 (equal (mapcar #'ri-pick-item-target items)
                        (list project-file)))))))
      (delete-directory root t))))

(provide 'ri-pick-test)
;;; ri-pick-test.el ends here
