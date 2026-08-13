;;; ri-tabs-test.el --- Tests for ri-tabs.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri-tabs)
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
   (ri-tabs--file-buffer-list)))

(defun ri-tabs-test--capture-frame-state (frame)
  "Capture Tab Bar parameters of FRAME for fixture cleanup."
  (list frame
        (frame-parameter frame 'tab-bar-lines)
        (frame-parameter frame 'tab-bar-lines-keep-state)
        (frame-parameter frame 'ri-tabs--item-buffers)))

(defun ri-tabs-test--restore-frame-state (state)
  "Restore one frame from captured fixture STATE."
  (when (frame-live-p (car state))
    (set-frame-parameter (car state) 'tab-bar-lines (nth 1 state))
    (set-frame-parameter
     (car state) 'tab-bar-lines-keep-state (nth 2 state))
    (set-frame-parameter
     (car state) 'ri-tabs--item-buffers (nth 3 state))))

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
  "Run BODY while restoring all global Tab Bar state afterward."
  (declare (indent 0) (debug t))
  `(let ((ri-tabs-test--saved-tab-bar-mode (and tab-bar-mode t))
         (ri-tabs-test--saved-tab-bar-format
          (copy-tree (default-value 'tab-bar-format)))
         (ri-tabs-test--saved-tab-bar-show
          (default-value 'tab-bar-show))
         (ri-tabs-test--saved-tab-bar-map
          (copy-keymap tab-bar-map))
         (ri-tabs-test--saved-tab-bar-mode-map
          (copy-keymap tab-bar-mode-map))
         (ri-tabs-test--saved-default-frame-alist
          (copy-tree default-frame-alist))
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
       (dolist (buffer (buffer-list))
         (ri-tabs--clear-buffer-cache buffer))
       (setq-default
        tab-bar-format
        (copy-tree ri-tabs-test--saved-tab-bar-format)
        tab-bar-show ri-tabs-test--saved-tab-bar-show)
       (condition-case nil
           (tab-bar-mode
            (if ri-tabs-test--saved-tab-bar-mode 1 -1))
         (error
          (setq tab-bar-mode
                ri-tabs-test--saved-tab-bar-mode)))
       (setcdr tab-bar-map
               (cdr (copy-keymap
                     ri-tabs-test--saved-tab-bar-map)))
       (setcdr tab-bar-mode-map
               (cdr (copy-keymap
                     ri-tabs-test--saved-tab-bar-mode-map)))
       (setq default-frame-alist
             (copy-tree
              ri-tabs-test--saved-default-frame-alist))
       (mapc #'ri-tabs-test--restore-frame-state
             ri-tabs-test--saved-frame-states)
       (setq ri-tabs--tab-bar-state nil
             ri-tabs--temporary-frame-states nil)
       (force-mode-line-update t))))

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

(ert-deftest ri-tabs-test-tab-face-follows-tab-selection ()
  (should (eq (ri-tabs--tab-face t) 'ri-tabs-current-tab))
  (should (eq (ri-tabs--tab-face nil) 'ri-tabs-tab)))

(ert-deftest ri-tabs-test-faces-inherit-native-tab-bar-faces ()
  (should
   (eq (face-attribute 'ri-tabs-tab :inherit nil t)
       'tab-bar-tab-inactive))
  (should
   (eq (face-attribute 'ri-tabs-current-tab :inherit nil t)
       'tab-bar-tab))
  (should
   (eq (face-attribute 'ri-tabs-highlight :inherit nil t)
       'tab-bar-tab-highlight)))

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

(ert-deftest ri-tabs-test-native-format-shows-file-state-and-menu-items ()
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
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame)
                       (list unmarked-modified marked-modified
                             unmarked current))))
            (let* ((buffers
                    (list current unmarked unmarked-modified
                          marked-modified))
                   (current-label
                    (ri-tabs--tab-label current buffers current))
                   (unmarked-label
                    (ri-tabs--tab-label unmarked buffers current))
                   (unmarked-modified-label
                    (ri-tabs--tab-label
                     unmarked-modified buffers current))
                   (marked-modified-label
                    (ri-tabs--tab-label
                     marked-modified buffers current))
                   (items (ri-tabs--format-tabs (selected-frame)))
                   (current-item (assq 'current-tab items))
                   (inactive-item (assq 'tab-2 items)))
              (should
               (equal (substring-no-properties current-label)
                      " [-] 100%.el "))
              (should
               (equal (substring-no-properties unmarked-label)
                      " [ ] unmarked.el "))
              (should
               (equal
                (substring-no-properties unmarked-modified-label)
                " [:] unmarked-modified.el "))
              (should
               (equal
                (substring-no-properties marked-modified-label)
                " [÷] marked-modified.el "))
              (should (equal (mapcar #'car items)
                             '(current-tab tab-2)))
              (should (eq (nth 1 current-item) 'menu-item))
              (should (eq (nth 3 current-item) #'ignore))
              (should (functionp (nth 3 inactive-item)))
              (should
               (equal
                (plist-get (nthcdr 4 current-item) :help)
                "Current file: /tmp/100%.el"))
              (should
               (eq (get-text-property 0 'face (nth 2 current-item))
                   'ri-tabs-current-tab))
              (should
               (eq (get-text-property 0 'mouse-face
                                      (nth 2 inactive-item))
                   'ri-tabs-highlight))
              (dolist (property '(tab selected keymap))
                (should-not
                 (get-text-property
                  0 property (nth 2 current-item))))
              (should
               (equal
                (frame-parameter
                 nil 'ri-tabs--item-buffers)
                `((current-tab . ,current)
                  (tab-2 . ,marked-modified)))))))
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

(ert-deftest ri-tabs-test-mode-owns-and-restores-native-tab-bar ()
  (ri-tabs-test-with-persistence
    (let* ((file
            (ri-tabs-test--visit-file
             (ri-tabs-test--make-file ri-tabs-test-root "file.el")))
           (late-path
            (ri-tabs-test--make-file ri-tabs-test-root "late.el"))
           (late-file nil)
           (special (generate-new-buffer "ri-tabs-special"))
           (frame (selected-frame))
           (before-format '(tab-bar-format-history tab-bar-format-tabs))
           (before-show 2)
           (before-lines (frame-parameter frame 'tab-bar-lines))
           (before-keep
            (frame-parameter frame 'tab-bar-lines-keep-state))
           (before-default (copy-tree default-frame-alist))
           (before-mouse-2 (lookup-key tab-bar-map [mouse-2]))
           before-tab-line-state)
      (push special ri-tabs-test--buffers)
      (with-current-buffer file
        (tab-line-mode 1)
        (setq-local tab-line-separator "before"
                    tab-line-tabs-function #'buffer-list)
        (setq before-tab-line-state
              (ri-tabs-test--tab-line-state file)))
      (setq-default tab-bar-format before-format
                    tab-bar-show before-show)
      (ri-tabs-mode 1)
      (should tab-bar-mode)
      (should (equal (default-value 'tab-bar-format)
                     '(ri-tabs--format-tabs)))
      (should (eq (default-value 'tab-bar-show) t))
      (should (= (frame-parameter frame 'tab-bar-lines) 1))
      (should (frame-parameter frame 'tab-bar-lines-keep-state))
      (should
       (eq (lookup-key tab-bar-map [mouse-2])
           #'ri-tabs--mouse-close))
      (with-current-buffer file
        (should (ri-tabs-buffer-marked-p))
        (should tab-line-mode)
        (should (equal tab-line-separator "before"))
        (should (eq tab-line-tabs-function #'buffer-list)))
      (with-current-buffer special
        (should-not tab-line-mode))
      (setq late-file (ri-tabs-test--visit-file late-path))
      (with-current-buffer late-file
        (should-not (ri-tabs-buffer-marked-p))
        (should-not tab-line-mode))
      (ri-tabs-mode -1)
      (should (equal (default-value 'tab-bar-format) before-format))
      (should (eql (default-value 'tab-bar-show) before-show))
      (should (eql (frame-parameter frame 'tab-bar-lines)
                   before-lines))
      (should (eql
               (frame-parameter frame 'tab-bar-lines-keep-state)
               before-keep))
      (should (equal default-frame-alist before-default))
      (should (eq (lookup-key tab-bar-map [mouse-2])
                  before-mouse-2))
      (with-current-buffer file
        (should tab-line-mode)
        (should (equal tab-line-separator "before"))
        (should (eq tab-line-tabs-function #'buffer-list))
        (should
         (equal (ri-tabs-test--tab-line-state file)
                before-tab-line-state))
        (should-not (local-variable-p 'ri-tabs--marked-p))
        (should-not (local-variable-p 'ri-tabs--file-id)))
      (with-current-buffer late-file
        (should-not tab-line-mode)
        (should-not (local-variable-p 'ri-tabs--marked-p))
        (should-not (local-variable-p 'ri-tabs--file-id))))))


(ert-deftest ri-tabs-test-restores-normal-frame-hidden-by-keep-state ()
  (ri-tabs-test-with-persistence
    (let ((frame (selected-frame)))
      (tab-bar-mode -1)
      (set-frame-parameter frame 'tab-bar-lines 0)
      (set-frame-parameter frame 'tab-bar-lines-keep-state t)
      (let ((before (ri-tabs--capture-frame-state frame)))
        (ri-tabs-mode 1)
        (should tab-bar-mode)
        (should (= (frame-parameter frame 'tab-bar-lines) 1))
        (should (frame-parameter frame 'tab-bar-lines-keep-state))
        (ri-tabs-mode -1)
        (should (equal (ri-tabs--capture-frame-state frame) before))))))

(ert-deftest ri-tabs-test-refresh-reasserts-owned-tab-bar ()
  (ri-tabs-test-with-persistence
    (let ((frame (selected-frame)))
      (ri-tabs-mode 1)
      ;; Simulate configuration evaluated later in init.el.
      (tab-bar-mode -1)
      (setq-default tab-bar-format '(tab-bar-format-tabs)
                    tab-bar-show nil)
      (set-frame-parameter frame 'tab-bar-lines 0)
      (set-frame-parameter frame 'tab-bar-lines-keep-state nil)
      (ri-tabs--refresh)
      (should tab-bar-mode)
      (should (equal (default-value 'tab-bar-format)
                     '(ri-tabs--format-tabs)))
      (should (eq (default-value 'tab-bar-show) t))
      (should (= (frame-parameter frame 'tab-bar-lines) 1))
      (should (frame-parameter frame 'tab-bar-lines-keep-state)))))

(ert-deftest ri-tabs-test-restores-enabled-custom-tab-bar-exactly ()
  (ri-tabs-test-with-persistence
    (let ((frame (selected-frame))
          (custom-format
           '(tab-bar-format-menu-bar tab-bar-format-history))
          (custom-show 3))
      (tab-bar-mode 1)
      (setq-default tab-bar-format custom-format
                    tab-bar-show custom-show)
      (setq default-frame-alist
            '((width . 91)
              (tab-bar-lines . 0)
              (height . 37)))
      (set-frame-parameter frame 'tab-bar-lines 1)
      (set-frame-parameter
       frame 'tab-bar-lines-keep-state nil)
      (define-key tab-bar-map [mouse-2] #'forward-char)
      (define-key
       tab-bar-mode-map [(control tab)] #'backward-char)
      (let ((before (ri-tabs--capture-tab-bar-state))
            (before-default (copy-tree default-frame-alist)))
        (ri-tabs-mode 1)
        (should tab-bar-mode)
        (should
         (equal (default-value 'tab-bar-format)
                '(ri-tabs--format-tabs)))
        (ri-tabs-mode -1)
        (should tab-bar-mode)
        (should
         (equal (ri-tabs--capture-tab-bar-state) before))
        (should (equal default-frame-alist before-default))))))

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
                 (length (window-list nil 'nomini)))
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
             (= (length (window-list nil 'nomini))
                window-count))
            (should
             (eq (window-buffer other-window)
                 other-displayed-buffer))))))))

(ert-deftest ri-tabs-test-renderer-follows-selected-window-across-split ()
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
              (setq ri-tabs-mode t
                    ri-tabs--tab-bar-state
                    (list :frames
                          (list
                           (ri-tabs--capture-frame-state
                            (selected-frame)))))
              (set-frame-parameter nil 'tab-bar-lines 1)
              (should (= (length (window-list nil 'nomini)) 2))
              (should
               (equal
                (mapcar
                 (lambda (item)
                   (cons
                    (car item)
                    (substring-no-properties (nth 2 item))))
                 (ri-tabs--format-tabs (selected-frame)))
                '((current-tab . " [-] ri-tabs-split-first.el ")
                  (tab-2 . " [-] ri-tabs-split-second.el "))))
              (select-window other-window)
              (should
               (equal
                (mapcar
                 (lambda (item)
                   (cons
                    (car item)
                    (substring-no-properties (nth 2 item))))
                 (ri-tabs--format-tabs (selected-frame)))
                '((tab-1 . " [-] ri-tabs-split-first.el ")
                  (current-tab . " [-] ri-tabs-split-second.el "))))
              (dolist (buffer (list first second))
                (with-current-buffer buffer
                  (should-not tab-line-mode)))))
        (setq ri-tabs-mode nil
              ri-tabs--tab-bar-state nil)
        (mapc #'kill-buffer (list first second))))))

(ert-deftest ri-tabs-test-tab-action-preserves-split-and-workspace-state ()
  (ri-tabs-test-with-tab-bar-state
    (let ((marked (generate-new-buffer "ri-tabs-action-marked"))
          (current (generate-new-buffer "ri-tabs-action-current"))
          (other (generate-new-buffer "ri-tabs-action-other")))
      (unwind-protect
          (save-window-excursion
            (with-current-buffer marked
              (setq buffer-file-name "/tmp/ri-tabs-action-marked.el"
                    ri-tabs--marked-p t))
            (with-current-buffer current
              (setq buffer-file-name "/tmp/ri-tabs-action-current.el"))
            (delete-other-windows)
            (set-window-buffer (selected-window) current)
            (let* ((selected-window (selected-window))
                   (other-window (split-window-below)))
              (set-window-buffer other-window other)
              (setq ri-tabs--tab-bar-state
                    (list :frames
                          (list
                           (ri-tabs--capture-frame-state
                            (selected-frame)))))
              (let* ((window-count
                      (length (window-list nil 'nomini)))
                     (other-buffer (window-buffer other-window))
                     (native-tabs
                      (copy-tree (frame-parameter nil 'tabs)))
                     (window-tree (copy-tree (window-tree)))
                     (items (ri-tabs--format-tabs (selected-frame)))
                     (action (nth 3 (assq 'tab-1 items))))
                (funcall action)
                (should (eq (selected-window) selected-window))
                (should (eq (window-buffer selected-window) marked))
                (should (eq (window-buffer other-window) other-buffer))
                (should
                 (= (length (window-list nil 'nomini))
                    window-count))
                (should (equal (window-tree) window-tree))
                (should
                 (equal (frame-parameter nil 'tabs)
                        native-tabs)))))
        (setq ri-tabs--tab-bar-state nil)
        (mapc #'kill-buffer (list marked current other))))))

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

(ert-deftest ri-tabs-test-event-decoder-supports-gui-and-tty-positions ()
  (ri-tabs-test-with-tab-bar-state
    (let ((buffer (generate-new-buffer "ri-tabs-event"))
          (frame (selected-frame)))
      (unwind-protect
          (progn
            (set-frame-parameter
             frame 'ri-tabs--item-buffers
             `((tab-1 . ,buffer)))
            (cl-letf (((symbol-function 'tab-bar--event-to-item)
                       (lambda (_position)
                         '(tab-1 ignore nil))))
              (should
               (equal
                (ri-tabs--event-target
                 '(mouse-1 (nil tab-bar (3 . 0) 0)))
                (list frame 'tab-1 buffer nil)))
              (should
               (equal
                (ri-tabs--event-target
                 `(mouse-1 (,frame tab-bar (3 . 0) 0)))
                (list frame 'tab-1 buffer nil)))))
        (kill-buffer buffer)))))

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
(ert-deftest ri-tabs-test-input-bindings-route-only-to-ri-commands ()
  (ri-tabs-test-with-tab-bar-state
    (let ((before
           (ri-tabs--capture-bindings
            tab-bar-map
            (mapcar #'car ri-tabs--tab-bar-event-bindings))))
      (ri-tabs--install-event-bindings)
      (should
       (eq (lookup-key tab-bar-map [down-mouse-1])
           #'ri-tabs--mouse-select))
      (should
       (eq (lookup-key tab-bar-map [mouse-2])
           #'ri-tabs--mouse-close))
      (should
       (eq (lookup-key tab-bar-map [down-mouse-3])
           #'ri-tabs--mouse-context-menu))
      (should
       (eq (lookup-key tab-bar-map [touchscreen-begin])
           #'ri-tabs--touchscreen-begin))
      (dolist (key '([mouse-4] [wheel-up] [wheel-left]))
        (should
         (eq (lookup-key tab-bar-map key)
             #'ri-tabs-switch-to-previous-buffer)))
      (dolist (key '([mouse-5] [wheel-down] [wheel-right]))
        (should
         (eq (lookup-key tab-bar-map key)
             #'ri-tabs-switch-to-next-buffer)))
      (dolist (key '([drag-mouse-1]
                     [S-mouse-4] [S-mouse-5]
                     [S-wheel-up] [S-wheel-down]
                     [S-wheel-left] [S-wheel-right]))
        (should (eq (lookup-key tab-bar-map key) #'ignore)))
      (ri-tabs--restore-bindings tab-bar-map before)
      (should
       (equal
        (ri-tabs--capture-bindings
         tab-bar-map
         (mapcar #'car ri-tabs--tab-bar-event-bindings))
        before)))))

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



(ert-deftest ri-tabs-test-normal-frame-overrides-preexisting-keep-state ()
  (let ((ri-tabs--tab-bar-state nil)
        (ri-tabs--temporary-frame-states nil)
        (frame (selected-frame))
        (original-lines (frame-parameter nil 'tab-bar-lines))
        (original-keep
         (frame-parameter nil 'tab-bar-lines-keep-state)))
    (unwind-protect
        (progn
          (set-frame-parameter
           frame 'tab-bar-lines-keep-state t)
          (set-frame-parameter frame 'tab-bar-lines 0)
          (should (ri-tabs--frame-eligible-p frame))
          (ri-tabs--configure-frame frame)
          (should (= (frame-parameter frame 'tab-bar-lines) 1))
          ;; Ri must not destroy the user's keep-state preference; the
          ;; lifecycle snapshot restores the original line count later.
          (should
           (frame-parameter frame 'tab-bar-lines-keep-state)))
      (set-frame-parameter frame 'tab-bar-lines original-lines)
      (set-frame-parameter
       frame 'tab-bar-lines-keep-state original-keep))))

(ert-deftest ri-tabs-test-structurally-ineligible-frames-stay-line-free ()
  (let ((ri-tabs--tab-bar-state nil)
        (ri-tabs--temporary-frame-states nil)
        (frame (selected-frame))
        (original-lines (frame-parameter nil 'tab-bar-lines))
        (original-keep
         (frame-parameter nil 'tab-bar-lines-keep-state)))
    (unwind-protect
        (progn
          (set-frame-parameter
           frame 'tab-bar-lines-keep-state nil)
          (set-frame-parameter frame 'tab-bar-lines 1)
          (cl-letf (((symbol-function
                      'ri-tabs--structurally-ineligible-frame-p)
                     (lambda (candidate)
                       (eq candidate frame))))
            (should-not (ri-tabs--frame-eligible-p frame))
            (ri-tabs--configure-frame frame t))
          (should (= (frame-parameter frame 'tab-bar-lines) 0))
          (should
           (frame-parameter
            frame 'tab-bar-lines-keep-state))
          (should (assq frame ri-tabs--temporary-frame-states)))
      (set-frame-parameter frame 'tab-bar-lines original-lines)
      (set-frame-parameter
       frame 'tab-bar-lines-keep-state original-keep))))


(ert-deftest ri-tabs-test-multiple-frames-render-independent-active-files ()
  (skip-unless
   (and (display-graphic-p) (display-multi-frame-p)))
  (ri-tabs-test-with-persistence
    (let* ((first-file
            (ri-tabs-test--make-file
             ri-tabs-test-root "frame-a.el"))
           (second-file
            (ri-tabs-test--make-file
             ri-tabs-test-root "frame-b.el"))
           (first (ri-tabs-test--visit-file first-file))
           (second (ri-tabs-test--visit-file second-file))
           (first-frame (selected-frame))
           second-frame)
      (unwind-protect
          (progn
            (ri-tabs-test--store-files first-file second-file)
            (set-window-buffer
             (frame-selected-window first-frame) first)
            (ri-tabs-mode 1)
            (setq second-frame
                  (make-frame
                   '((name . "ri-tabs-multiple-frame-test")
                     (visibility . nil))))
            (set-window-buffer
             (frame-selected-window second-frame) second)
            (let ((first-items
                   (ri-tabs--format-tabs first-frame))
                  (second-items
                   (ri-tabs--format-tabs second-frame)))
              (should
               (equal
                (mapcar
                 (lambda (item)
                   (cons
                    (car item)
                    (substring-no-properties (nth 2 item))))
                 first-items)
                '((current-tab . " [-] frame-a.el ")
                  (tab-2 . " [-] frame-b.el "))))
              (should
               (equal
                (mapcar
                 (lambda (item)
                   (cons
                    (car item)
                    (substring-no-properties (nth 2 item))))
                 second-items)
                '((tab-1 . " [-] frame-a.el ")
                  (current-tab . " [-] frame-b.el "))))
              (should
               (eq
                (cdr
                 (assq
                  'current-tab
                  (frame-parameter
                   first-frame 'ri-tabs--item-buffers)))
                first))
              (should
               (eq
                (cdr
                 (assq
                  'current-tab
                  (frame-parameter
                   second-frame 'ri-tabs--item-buffers)))
                second)))
            (should (= (frame-parameter first-frame 'tab-bar-lines) 1))
            (should (= (frame-parameter second-frame 'tab-bar-lines) 1))
            (dolist (buffer (list first second))
              (with-current-buffer buffer
                (should-not tab-line-mode))))
        (when (frame-live-p second-frame)
          (delete-frame second-frame t))))))

(ert-deftest ri-tabs-test-new-normal-and-child-frame-policy ()
  (skip-unless
   (and (display-graphic-p) (display-multi-frame-p)))
  (ri-tabs-test-with-persistence
    (let ((parent (selected-frame))
          normal
          child)
      (unwind-protect
          (progn
            (tab-bar-mode -1)
            (setq default-frame-alist
                  (assq-delete-all
                   'tab-bar-lines default-frame-alist))
            (ri-tabs-test--store-files)
            (ri-tabs-mode 1)
            (setq normal
                  (make-frame
                   '((name . "ri-tabs-new-normal-test")
                     (visibility . nil))))
            (should (= (frame-parameter normal 'tab-bar-lines) 1))
            (setq child
                  (make-frame
                   `((name . "ri-tabs-new-child-test")
                     (parent-frame . ,parent)
                     (minibuffer . ,(minibuffer-window parent))
                     (visibility . nil)
                     (no-accept-focus . t)
                     (width . 20)
                     (height . 2)
                     (tab-bar-lines . 0))))
            (should (= (frame-parameter child 'tab-bar-lines) 0))
            (should
             (frame-parameter child 'tab-bar-lines-keep-state))
            (should-not (ri-tabs--format-tabs child))
            (ri-tabs-mode -1)
            (should-not tab-bar-mode)
            (should (= (frame-parameter normal 'tab-bar-lines) 0))
            (should (= (frame-parameter child 'tab-bar-lines) 0))
            (should-not
             (frame-parameter child 'tab-bar-lines-keep-state)))
        (when (frame-live-p child)
          (delete-frame child t))
        (when (frame-live-p normal)
          (delete-frame normal t))))))

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

(provide 'ri-tabs-test)

;;; ri-tabs-test.el ends here

(defun ri-tabs-test--make-git-repo (root name)
  "Create a minimal Git repository directory NAME below ROOT."
  (let ((repo (expand-file-name name root)))
    (make-directory (expand-file-name ".git" repo) t)
    repo))

(defmacro ri-tabs-test-with-owner-frame (&rest body)
  "Run BODY while restoring the selected frame's Ri owner parameter."
  (declare (indent 0) (debug t))
  `(let* ((frame (selected-frame))
          (saved-owner (frame-parameter frame 'ri-tabs-owner-repo)))
     (unwind-protect
         (progn ,@body)
       (set-frame-parameter frame 'ri-tabs-owner-repo saved-owner))))

(ert-deftest ri-tabs-test-first-mark-owns-cross-repository-set ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
             (repo-b (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-b"))
             (file-a (ri-tabs-test--make-file repo-a "a.el"))
             (file-b (ri-tabs-test--make-file repo-b "b.el"))
             (buffer-a (ri-tabs-test--visit-file file-a))
             (buffer-b (ri-tabs-test--visit-file file-b)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner-repo nil)
        (ri-tabs-mark-buffer buffer-a)
        (let ((owner (ri-tabs--frame-owner-repo)))
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
        (set-frame-parameter (selected-frame) 'ri-tabs-owner-repo nil)
        (ri-tabs-mark-buffer buffer-a)
        (let ((owner (ri-tabs--frame-owner-repo)))
          (set-window-buffer (selected-window) buffer-b)
          (ri-tabs--sync-visited-buffer)
          (should (equal (ri-tabs--frame-owner-repo) owner)))))))

(ert-deftest ri-tabs-test-explicit-repository-switch-selects-independent-set ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
             (repo-b (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-b"))
             (file-a (ri-tabs-test--make-file repo-a "a.el"))
             (file-b (ri-tabs-test--make-file repo-b "b.el"))
             (buffer-a (ri-tabs-test--visit-file file-a))
             (buffer-b (ri-tabs-test--visit-file file-b)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner-repo nil)
        (ri-tabs-mark-buffer buffer-a)
        (ri-tabs-switch-repository buffer-b)
        (ri-tabs-mark-buffer buffer-b)
        (let* ((state (ri-tabs--read-state))
               (owner-a (ri-tabs--canonical-directory repo-a))
               (owner-b (ri-tabs--canonical-directory repo-b)))
          (should (equal (ri-tabs--state-owner-files state owner-a)
                         (list (ri-tabs-test--file-id file-a))))
          (should (equal (ri-tabs--state-owner-files state owner-b)
                         (list (ri-tabs-test--file-id file-b))))
          (should (equal (ri-tabs--frame-owner-repo) owner-b)))))))

(ert-deftest ri-tabs-test-existing-owner-allows-mark-outside-git ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((repo-a (ri-tabs-test--make-git-repo ri-tabs-test-root "repo-a"))
             (outside-root (expand-file-name "outside" ri-tabs-test-root))
             (file-a (ri-tabs-test--make-file repo-a "a.el"))
             (outside (ri-tabs-test--make-file outside-root "notes.txt"))
             (buffer-a (ri-tabs-test--visit-file file-a))
             (outside-buffer (ri-tabs-test--visit-file outside)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner-repo nil)
        (ri-tabs-mark-buffer buffer-a)
        (let ((owner (ri-tabs--frame-owner-repo)))
          (ri-tabs-mark-buffer outside-buffer)
          (should
           (member (ri-tabs-test--file-id outside)
                   (ri-tabs--state-owner-files (ri-tabs--read-state) owner))))))))

(ert-deftest ri-tabs-test-cannot-start-marked-set-outside-git ()
  (ri-tabs-test-with-persistence
    (ri-tabs-test-with-owner-frame
      (let* ((outside-root (expand-file-name "outside" ri-tabs-test-root))
             (outside (ri-tabs-test--make-file outside-root "notes.txt"))
             (buffer (ri-tabs-test--visit-file outside)))
        (set-frame-parameter (selected-frame) 'ri-tabs-owner-repo nil)
        (should-error (ri-tabs-mark-buffer buffer) :type 'user-error)))))

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
      (should (= (length (plist-get state :repos)) 1)))))
