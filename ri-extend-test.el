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

(defmacro ri-extend-test--with-json-buffer (text &rest body)
  "Run BODY in a temporary JSON buffer backed by tree-sitter."
  (declare (indent 1))
  `(ri-extend-test--with-buffer ,text
     (unless (and (treesit-available-p)
                  (treesit-language-available-p 'json))
       (ert-skip "JSON tree-sitter grammar unavailable"))
     (treesit-parser-create 'json)
     ,@body))

(defun ri-extend-test--highlighted-p (pos)
  "Return non-nil when POS has the semantic highlight face."
  (cl-some
   (lambda (overlay)
     (eq (overlay-get overlay 'face) 'sr-highlight-face))
   (overlays-at pos)))

(ert-deftest ri-extend-test-submode-switch-preserves-selection ()
  (ri-extend-test--with-buffer "foo bar baz\n"
    (dolist
        (case
         '((ri-extend-set-line-star-mode line-star)
           (ri-extend-set-line-mode line)
           (ri-extend-set-paragraph-mode paragraph)
           (ri-extend-set-character-mode char)
           (ri-extend-set-word-mode word)
           (ri-extend-set-word-star-mode word-star)
           (ri-extend-set-word-plus-mode word-plus)
           (ri-extend-set-subword-mode subword)))
      (pcase-let ((`(,setter ,submode) case))
        (dolist (swap '(nil t))
          (goto-char 2)
          (setq sr-submode 'char)
          (should (ri--enter-extend))
          (let ((before (ri--selection-bounds)))
            (should (equal before (cons 2 3)))
            (when swap
              (ri-swap-cursor)
              (should (equal (ri--selection-bounds) before)))
            (funcall setter)
            (should (eq sr-submode submode))
            (should (ri--selection-active-p))
            (should (eq (ri--selection-state-active-edge ri--selection)
                        (if swap 'start 'end)))
            (should (equal (ri--selection-bounds) before)))
          (ri--exit-extend))))))

(ert-deftest ri-extend-test-line-to-word-after-swap-preserves-extend ()
  (ri-extend-test--with-buffer
      "zero alpha\nbeta gamma\ndelta epsilon\n"
    (goto-char 8)
    (setq sr-submode 'char)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (ri-extend-nav-down)
    (let ((extended-bounds (ri--selection-bounds)))
      (should (equal extended-bounds (cons 8 24)))
      (should
       (equal (buffer-substring-no-properties
               (car extended-bounds) (cdr extended-bounds))
              "pha\nbeta gamma\nd"))
      (ri-extend-set-line-mode)
      (should (equal (ri--selection-bounds) extended-bounds))
      (ri-swap-cursor)
      (should (equal (ri--selection-bounds) extended-bounds))
      (ri-extend-set-word-mode)
      (should (eq sr-submode 'word))
      (should (equal (ri--selection-bounds) extended-bounds))
      (ri-extend-nav-right)
      (should (equal (ri--selection-bounds) (cons 12 24)))
      (ri-smart-undo)
      (should (equal (ri--selection-bounds) extended-bounds)))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-fine-undo-redo-splits-grouped-insertion ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abc")
    (undo-boundary)
    (let ((last-command nil))
      (cl-labels
          ((dispatch (command)
             (let ((this-command command))
               (call-interactively command)
               (setq last-command this-command))))
        (dolist (expected '("ab" "a" ""))
          (dispatch #'ri-fine-undo)
          (should (equal (buffer-string) expected)))
        (dolist (expected '("a" "ab" "abc"))
          (dispatch #'ri-fine-redo)
          (should (equal (buffer-string) expected)))))))


(ert-deftest ri-extend-test-node-extends-across-named-siblings ()
  (ri-extend-test--with-json-buffer
      "[{\"x\": 123}, true, {\"y\": {}}]"
    (setq sr-submode 'char)
    (goto-char 2)
    (ri-extend-set-node-mode)
    (should (eq sr-submode 'node))
    (should (equal (sr--get-current-unit-bounds) (cons 2 12)))
    (should (ri--enter-extend))
    ;; Ki recipe: NODE, Extend, Right, Right, Left.
    (ri-extend-nav-right)
    (ri-extend-nav-right)
    (ri-extend-nav-left)
    (let ((bounds (ri--selection-bounds)))
      (should (equal (buffer-substring-no-properties
                      (car bounds) (cdr bounds))
                     "{\"x\": 123}, true"))
      (should (= (point) (1- (cdr bounds)))))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-normal-submode-switch-snaps-to-unit-start ()
  (ri-extend-test--with-buffer "  alpha beta\n"
    (dolist
        (case
         '((ri-extend-set-line-star-mode line-star 1 (1 . 13))
           (ri-extend-set-line-mode line 3 (3 . 13))
           (ri-extend-set-paragraph-mode paragraph 1 (1 . 14))
           (ri-extend-set-character-mode char 1 (1 . 2))
           (ri-extend-set-word-mode word 3 (3 . 8))
           (ri-extend-set-word-star-mode word-star 3 (3 . 8))
           (ri-extend-set-word-plus-mode word-plus 3 (3 . 8))
           (ri-extend-set-subword-mode subword 3 (3 . 8))))
      (pcase-let
          ((`(,setter ,submode ,expected-point ,expected-bounds) case))
        (goto-char (point-min))
        (setq sr-submode 'char)
        (funcall setter)
        (should (eq sr-submode submode))
        (should (= (point) expected-point))
        (should (equal (sr--get-current-unit-bounds)
                       expected-bounds))))))

(ert-deftest ri-extend-test-paragraph-switch-keeps-empty-line-current ()
  (ri-extend-test--with-buffer "\nfoo\n"
    (setq sr-submode 'char)
    (ri-extend-set-paragraph-mode)
    (should (eq sr-submode 'paragraph))
    (should (= (point) (point-min)))
    (should (equal (sr--get-current-unit-bounds)
                   (cons (point-min) (point-min))))))

(ert-deftest ri-extend-test-paragraph-navigation-keeps-active-edge ()
  (ri-extend-test--with-buffer "foo\nbar\n\nspam\nbaz\n\nlol"
    (setq sr-submode 'paragraph)
    (should (ri--enter-extend))
    (ri-extend-nav-next)
    (let ((bounds (ri--selection-bounds)))
      (should (equal
               (buffer-substring-no-properties
                (car bounds) (cdr bounds))
               "foo\nbar\n\nspam\nbaz\n"))
      (should (eq (ri--selection-state-active-edge ri--selection)
                  'end))
      (should (= (point) (1- (cdr bounds)))))
    (ri-extend-nav-prev)
    (let ((bounds (ri--selection-bounds)))
      (should (equal
               (buffer-substring-no-properties
                (car bounds) (cdr bounds))
               "foo\nbar\n"))
      (should (= (point) (1- (cdr bounds)))))
    (ri--exit-extend)

    (search-forward "spam")
    (goto-char (match-beginning 0))
    (should (ri--enter-extend))
    (ri-swap-cursor)
    (ri-extend-nav-prev)
    (let ((bounds (ri--selection-bounds)))
      (should (equal
               (buffer-substring-no-properties
                (car bounds) (cdr bounds))
               "foo\nbar\n\nspam\nbaz\n"))
      (should (eq (ri--selection-state-active-edge ri--selection)
                  'start))
      (should (= (point) (car bounds))))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-line-down-does-not-highlight-newline ()
  (ri-extend-test--with-buffer "foo\nbar\n"
    (setq sr-submode 'line)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (should (= (point) 7))
    (let ((bounds (ri--selection-bounds)))
      (should (equal bounds (cons 1 8)))
      (should (equal (buffer-substring-no-properties
                      (car bounds) (cdr bounds))
                     "foo\nbar"))
      (dolist (pos '(1 2 3 5 6 7))
        (should (ri-extend-test--highlighted-p pos)))
      (dolist (pos '(4 8))
        (should-not (ri-extend-test--highlighted-p pos))))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-parent-line-matches-ki-and-extend-edges ()
  (ri-extend-test--with-buffer "outer\n  inner\n    leaf\n"
    (let* ((outer (point-min))
           (outer-line (line-beginning-position))
           (inner
            (save-excursion
              (forward-line 1)
              (back-to-indentation)
              (point)))
           (inner-line
            (save-excursion
              (forward-line 1)
              (line-beginning-position)))
           (leaf
            (save-excursion
              (forward-line 2)
              (back-to-indentation)
              (point)))
           (leaf-line
            (save-excursion
              (forward-line 2)
              (line-beginning-position)))
           (leaf-end
            (save-excursion
              (forward-line 2)
              (line-end-position))))
      (cl-letf
          (((symbol-function 'sr--require-node-parser)
            (lambda (&optional _feature) 'fake))
           ((symbol-function 'sr--parent-line-position)
            (lambda ()
              (cond
               ((= (line-beginning-position) leaf-line) inner)
               ((= (line-beginning-position) inner-line) outer)
               ((= (line-beginning-position) outer-line) nil)))))
        (setq sr-submode 'line)
        (goto-char leaf)
        (ri-parent-line)
        (should (= (point) inner))
        (ri-parent-line)
        (should (= (point) outer))

        (goto-char leaf)
        (should (ri--enter-extend))
        (let ((before (ri--selection-bounds)))
          ;; Parent Line cannot move an end edge backward without putting
          ;; point inside the selection; an explicit cursor swap is required.
          (ri-parent-line)
          (should (equal (ri--selection-bounds) before))
          (should (= (point) (1- (cdr before)))))

        (ri-swap-cursor)
        (should
         (eq (ri--selection-state-active-edge ri--selection) 'start))
        (ri-parent-line)
        (should (equal (ri--selection-bounds) (cons inner leaf-end)))
        (should (= (point) inner))
        (ri-parent-line)
        (should (equal (ri--selection-bounds) (cons outer leaf-end)))
        (should (= (point) outer))
        (should
         (eq (ri--selection-state-active-edge ri--selection) 'start))
        (ri--exit-extend)))))


(ert-deftest ri-extend-test-line-to-word-keeps-newlines-unpainted ()
  (ri-extend-test--with-buffer "foo\nbar\nbaz\n"
    (setq sr-submode 'line)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (ri-extend-nav-down)
    (let ((line-bounds (ri--selection-bounds)))
      (should (equal line-bounds (cons 1 12)))
      (ri-extend-set-word-mode)
      (should (eq sr-submode 'word))
      (should (equal (ri--selection-bounds) line-bounds))
      (dolist (pos '(1 2 3 5 6 7 9 10 11))
        (should (ri-extend-test--highlighted-p pos)))
      (dolist (pos '(4 8 12))
        (should-not (ri-extend-test--highlighted-p pos))))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-swaps-normal-unit-cursor ()
  (ri-extend-test--with-buffer "foo bar"
    (setq sr-submode 'word)
    (ri-swap-cursor)
    (should (= (point) 3))
    (ri-swap-cursor)
    (should (= (point) 1))))

(ert-deftest ri-extend-test-node-error-survives-key-release ()
  (ri-extend-test--with-buffer "plain text"
    (let ((sr-node-language-alist
           '((fundamental-mode . deliberately-missing)))
          (kkp-chord-after-release-hook
           '(ri--restore-message-after-release))
          (ri--restore-message-after-release nil)
          restored)
      (should-error (ri-set-node-mode) :type 'user-error)
      (let ((expected ri--restore-message-after-release))
        (should (string-match-p
                 "NODE requires.*deliberately-missing"
                 expected))
        (cl-letf (((symbol-function 'kkp-chord--parse)
                   (lambda (_input)
                     (list :keycode ?d
                           :event-type kkp-chord--event-release
                           :modifier-num 0)))
                  ((symbol-function 'kkp-chord--on-release) #'ignore)
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (setq restored (apply #'format format-string args)))))
          (should (equal
                   (kkp-chord--translate-advice #'ignore "release")
                   [])))
        (should (equal restored expected))
        (should-not ri--restore-message-after-release)))))

(ert-deftest ri-extend-test-registers-normal-navigation-bindings ()
  (let ((mini-modal-map (make-sparse-keymap))
        (minor-mode-alist nil)
        (find-file-hook nil)
        (kkp-chord-after-release-hook nil)
        (sr-highlight-predicate nil)
        (status-frame-height 0)
        ki-tabs-enabled)
    (cl-letf (((symbol-function 'modal-cursor-mode) #'ignore)
              ((symbol-function 'ki-tabs-mode)
               (lambda (&optional arg)
                 (setq ki-tabs-enabled arg)))
              ((symbol-function 'mini-modal-setup) #'ignore)
              ((symbol-function 'kkp-chord-mode) #'ignore)
              ((symbol-function 'global-kkp-mode) #'ignore)
              ((symbol-function 'buffer-list)
               (lambda (&optional _frame) nil)))
      (ri-enable)
      (should (equal ki-tabs-enabled 1))
      (should (eq (lookup-key mini-modal-map "/")
                  #'ri-swap-cursor))
      (should (keymapp (lookup-key mini-modal-map (kbd "C-h"))))
      (should (eq (lookup-key mini-modal-map (kbd "C-h v"))
                  #'describe-variable))
      (should (eq (lookup-key ri--normal-help-map (kbd "C-h"))
                  'help-command))
      (should (eq (lookup-key ri--normal-help-map "/")
                  #'ri-swap-cursor))
      (should (eq (lookup-key mini-modal-map "d")
                  #'ri-set-node-mode))
      (should (eq (lookup-key ri--normal-help-map "d")
                  #'ri-set-node-mode))
      (should (eq (lookup-key mini-modal-map "E")
                  #'ri-extend-set-paragraph-mode))
      (should (eq (lookup-key ri--normal-help-map "E")
                  #'ri-extend-set-paragraph-mode))
      (should (eq (lookup-key mini-modal-map "I")
                  #'ri-join-lines))
      (should (eq (lookup-key ri--normal-help-map "I")
                  #'ri-join-lines))
      (should (eq (lookup-key mini-modal-map "J")
                  #'ri-dedent))
      (should (eq (lookup-key ri--normal-help-map "J")
                  #'ri-dedent))
      (should (eq (lookup-key mini-modal-map "L")
                  #'ri-indent))
      (should (eq (lookup-key ri--normal-help-map "L")
                  #'ri-indent))
      (should (eq (lookup-key mini-modal-map "x")
                  #'ri--press-layer))
      (should (eq (lookup-key ri--normal-help-map "x")
                  #'ri-cut-selection))
      (should (eq (lookup-key mini-modal-map ".")
                  #'ri-parent-line))
      (should (eq (lookup-key ri--normal-help-map ".")
                  #'ri-parent-line))
      (dolist (case '((paragraph "PARAGRAPH")
                      (node "NODE")))
        (let ((sr-submode (car case)))
          (should (equal (ri--submode-name) (cadr case))))))))

(ert-deftest ri-extend-test-ri-enable-shows-tabs-for-new-file ()
  (let ((buffer (generate-new-buffer "ri-tabs-after-enable"))
        (mini-modal-map (make-sparse-keymap))
        (minor-mode-alist nil)
        (find-file-hook nil)
        (after-set-visited-file-name-hook nil)
        (after-change-major-mode-hook nil)
        (kill-buffer-hook nil)
        (first-change-hook nil)
        (after-save-hook nil)
        (after-revert-hook nil)
        (kkp-chord-after-release-hook nil)
        (sr-highlight-predicate nil)
        (status-frame-height 0)
        (ki-tabs-mode nil))
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'modal-cursor-mode) #'ignore)
                    ((symbol-function 'mini-modal-setup) #'ignore)
                    ((symbol-function 'kkp-chord-mode) #'ignore)
                    ((symbol-function 'ri-chord-setup) #'ignore)
                    ((symbol-function 'global-kkp-mode) #'ignore)
                    ((symbol-function 'ri--maybe-enable-semantic-regions)
                     #'ignore)
                    ((symbol-function 'buffer-list)
                     (lambda (&optional _frame) (list buffer))))
            (set-window-buffer (selected-window) buffer)
            (ri-enable)
            (with-current-buffer buffer
              (setq buffer-file-name "/tmp/ri-tabs-after-enable.el")
              (run-hooks 'find-file-hook)
              (should ki-tabs-mode)
              (should tab-line-mode)
              (should (eq tab-line-tabs-function
                          #'ki-tabs--buffer-list))
              (should
               (equal
                (mapconcat
                 (lambda (part)
                   (if (stringp part)
                       (substring-no-properties part)
                     ""))
                 (tab-line-format)
                 "")
                " [-] ri-tabs-after-enable.el ")))))
      (when ki-tabs-mode
        (ki-tabs-mode -1))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ri-extend-test-registers-cut-chord ()
  (let ((kkp-chord--mod-maps (make-hash-table :test 'eql))
        (kkp-chord--tap-actions (make-hash-table :test 'eql))
        (kkp-chord--predicates (make-hash-table :test 'eql))
        (kkp-chord--press-actions (make-hash-table :test 'eql))
        (kkp-chord--release-actions (make-hash-table :test 'eql)))
    (ri-chord-setup)
    (should (eq (gethash ?x kkp-chord--mod-maps)
                ri--cut-layer-map))
    (should (eq (gethash ?x kkp-chord--tap-actions)
                #'ri-cut-selection))
    (dolist (binding '(("j" . ri-cut-left)
                       ("l" . ri-cut-right)
                       ("u" . ri-cut-prev)
                       ("o" . ri-cut-next)
                       ("y" . ri-cut-first)
                       ("p" . ri-cut-last)))
      (should (eq (lookup-key ri--cut-layer-map (car binding))
                  (cdr binding))))))

(ert-deftest ri-extend-test-cut-selection ()
  (ri-extend-test--with-buffer "foo bar"
    (let ((kill-ring nil))
      (setq sr-submode 'word)
      (should (ri--enter-extend))
      (ri-extend-nav-right)
      (should (equal (ri--selection-bounds) (cons 1 8)))
      (ri-cut-selection)
      (should (equal (buffer-string) ""))
      (should (equal kill-ring '("foo bar")))
      (should-not (ri--selection-active-p)))))

(ert-deftest ri-extend-test-join-lines-matches-ki ()
  (ri-extend-test--with-buffer "foo\n    spam bar"
    (setq sr-submode 'word)
    (goto-char (point-max))
    (backward-char)
    (should (equal (ri--selection-bounds) (cons 14 17)))
    (ri-join-lines)
    (should (equal (buffer-string) "foospam bar"))
    (should (= (point) 11))
    (should (equal (ri--selection-bounds) (cons 9 12)))
    ;; The first line has no previous line, so joining it is a no-op.
    (ri-join-lines)
    (should (equal (buffer-string) "foospam bar"))))

(ert-deftest ri-extend-test-join-lines-preserves-extend-selection ()
  (ri-extend-test--with-buffer "foo\n    spam bar"
    (setq sr-submode 'word)
    (goto-char (point-max))
    (backward-char)
    (should (ri--enter-extend))
    (should (equal (ri--selection-bounds) (cons 14 17)))
    (ri-join-lines)
    (should (equal (buffer-string) "foospam bar"))
    (should (ri--selection-active-p))
    (should (equal (ri--selection-bounds) (cons 9 12)))
    (should (= (point) 11))
    (should (eq (ri--selection-state-active-edge ri--selection) 'end))
    (ri-join-lines)
    (should (equal (ri--selection-bounds) (cons 9 12)))
    (ri--exit-extend)))

(ert-deftest ri-extend-test-indent-dedent-single-line-matches-ki ()
  (ri-extend-test--with-buffer "fom"
    (setq sr-submode 'char)
    (ri-indent)
    (should (equal (buffer-string) "    fom"))
    (should (= (point) 5))
    (should (equal (ri--selection-bounds) (cons 5 6)))
    (ri-dedent)
    (should (equal (buffer-string) "fom"))
    (should (= (point) 1))
    (should (equal (ri--selection-bounds) (cons 1 2)))))

(ert-deftest ri-extend-test-indent-dedent-preserves-extend-edges ()
  (dolist (swap '(nil t))
    (ri-extend-test--with-buffer
        "fn main() {\n    foo()\n}\nafter\n"
      (setq sr-submode 'line-star)
      (should (ri--enter-extend))
      (ri-extend-nav-down)
      (ri-extend-nav-down)
      (when swap
        (ri-swap-cursor))
      (let ((active-edge
             (ri--selection-state-active-edge ri--selection)))
        (ri-indent)
        (should
         (equal (buffer-string)
                "    fn main() {\n        foo()\n    }\nafter\n"))
        (should (ri--selection-active-p))
        (should (eq (ri--selection-state-active-edge ri--selection)
                    active-edge))
        (should (equal (ri--selection-bounds) (cons 5 36)))
        (should
         (equal (buffer-substring-no-properties 5 36)
                "fn main() {\n        foo()\n    }"))
        (should (= (point) (if (eq active-edge 'end) 35 5)))
        (ri-dedent)
        (should
         (equal (buffer-string)
                "fn main() {\n    foo()\n}\nafter\n"))
        (should (equal (ri--selection-bounds) (cons 1 24)))
        (should (= (point) (if (eq active-edge 'end) 23 1)))))))

(ert-deftest ri-extend-test-dedent-removes-only-available-indentation ()
  (ri-extend-test--with-buffer
      "fn main() {\n    foo()\n}\nafter\n"
    (setq sr-submode 'line-star)
    (should (ri--enter-extend))
    (ri-extend-nav-down)
    (ri-extend-nav-down)
    (ri-dedent)
    (should
     (equal (buffer-string)
            "fn main() {\nfoo()\n}\nafter\n"))
    (should
     (equal
      (buffer-substring-no-properties
       (car (ri--selection-bounds))
       (cdr (ri--selection-bounds)))
      "fn main() {\nfoo()\n}"))
    (should (= (point) (1- (cdr (ri--selection-bounds)))))))

(ert-deftest ri-extend-test-mode-line-remaps-eglot-label ()
  (with-temp-buffer
    (ri--mode-line-enable)
    (let ((eglot-remap (assq 'eglot-mode-line face-remapping-alist)))
      (should eglot-remap)
      (should (memq 'ri-mode-line eglot-remap)))
    (should (equal (face-attribute 'ri-mode-line :foreground nil t)
                   "#ffffff"))
    (should (equal (face-attribute 'ri-mode-line :background nil t)
                   "#3478c6"))))

(provide 'ri-extend-test)
;;; ri-extend-test.el ends here
