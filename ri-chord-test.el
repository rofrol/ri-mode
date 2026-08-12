;;; ri-chord-test.el --- Tests for RI KKP chord dispatch -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri)
(require 'help)

(defmacro ri-chord-test--with-fresh-chords (&rest body)
  "Run BODY with isolated chord registrations and held state."
  (declare (indent 0) (debug t))
  `(let ((kkp-chord--held nil)
         (kkp-chord--transient-exit nil)
         (kkp-chord--transient-keycode nil)
         (kkp-chord--mod-maps (make-hash-table :test 'eql))
         (kkp-chord--tap-actions (make-hash-table :test 'eql))
         (kkp-chord--predicates (make-hash-table :test 'eql))
         (kkp-chord--press-actions (make-hash-table :test 'eql))
         (kkp-chord--release-actions (make-hash-table :test 'eql)))
     (unwind-protect
         (progn ,@body)
       (kkp-chord--deactivate-transient-map)
       (keymap-legend-hide))))

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

(ert-deftest ri-chord-test-help-prefix-shows-filtered-default-legend ()
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
                      ri--help-prefix-map))
          (should-not shown)
          (cl-letf (((symbol-function 'this-command-keys-vector)
                     (lambda () (vector ?\C-h))))
            (should (eq (ri--help-prefix-filter 'help-command)
                        ri--help-prefix-map)))
          (should (equal (list (nth 0 shown) (nth 2 shown))
                         '("C-h Help" (:title "C-h Help"))))
          (let ((map (nth 1 shown)))
            (should (keymapp map))
            (should (eq (lookup-key map "v") #'describe-variable))
            (should-not (lookup-key map [f1]))
            (should-not (lookup-key map [backspace]))
            (should-not (lookup-key map (kbd "C-\\"))))
          (should (eq (lookup-key ri--help-prefix-map "?")
                      #'ri--help-for-help))
          (should (keymapp (lookup-key ri--help-prefix-map (kbd "ESC"))))
          (should (eq (keymap-parent ri--help-prefix-map)
                      (symbol-function 'help-command)))
          (should ri--help-prefix-active)
          (should (memq #'ri--exit-help-prefix pre-command-hook))
          (ri--exit-help-prefix)
          (should hidden)
          (should-not ri--help-prefix-active)
          (should-not (memq #'ri--exit-help-prefix pre-command-hook)))))))

(ert-deftest ri-chord-test-c-h-legend-uses-concise-labels ()
  (let ((map (ri--help-prefix-legend-map)))
    (dolist (case '((?h "Hello")
                    (?v "Desc Var")
                    (?a "Apro Cmd")))
      (let (binding)
        (map-keymap
         (lambda (event value)
           (when (eql event (car case))
             (setq binding value)))
         map)
        (should (equal (nth 1 binding) (cadr case)))))
    (should (eq (lookup-key map "v") #'describe-variable))
    (should (equal (ri--help-prefix-label #'describe-variable)
                   "Desc Var"))
    (should (equal (ri--help-prefix-label #'view-hello-file)
                   "Hello"))
    (should (equal (ri--help-prefix-label #'apropos)
                   "Apro"))))

(ert-deftest ri-chord-test-help-prefix-does-not-reopen-during-command ()
  (with-temp-buffer
    (let (shown)
      (cl-letf (((symbol-function 'keymap-legend-show)
                 (lambda (&rest _) (setq shown t)))
                ((symbol-function 'this-command-keys-vector)
                 (lambda () (vector ?\C-h ?h))))
        (let ((ri--help-prefix-active nil))
          (should (eq (ri--help-prefix-filter 'view-hello-file)
                      'view-hello-file))
          (should-not shown)
          (should-not ri--help-prefix-active)
          (should-not (memq #'ri--exit-help-prefix pre-command-hook)))))))

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
                (lambda () (interactive)
                  (should hidden)
                  (should-not ri--help-prefix-active)
                  (setq called t)))
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

(ert-deftest ri-chord-test-help-for-help-survives-shift-slash-release ()
  (let ((unread-command-events
         (append (string-to-list
                  "\e[47:63;2:3u\e[57441;1:3u")
                 (list ?q)))
        (input-decode-map (copy-keymap input-decode-map))
        (kkp-chord-after-release-hook nil))
    (define-key
     input-decode-map "\e[4"
     (lambda (&optional _prompt)
       (kkp-chord--translate-advice
        #'ignore (kkp--read-terminal-events ?4))))
    (define-key
     input-decode-map "\e[5"
     (lambda (&optional _prompt)
       (kkp-chord--translate-advice
        #'ignore (kkp--read-terminal-events ?5))))
    (unwind-protect
        (save-window-excursion
          (ri--help-for-help)
          (should-not unread-command-events))
      (when-let* ((buffer (get-buffer help-for-help-buffer-name)))
        (kill-buffer buffer)))))

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

(ert-deftest ri-chord-test-z-layer-dispatches-undo-and-redo ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "base")
      (setq buffer-undo-list nil)
      (insert " change")
      (undo-boundary)
      (let ((mini-modal-mode t)
            (ri--menu-state nil)
            (ri--help-prefix-active nil))
        (ri-chord-setup)
        (should (eq (gethash ?z kkp-chord--mod-maps)
                    ri--undo-redo-layer-map))
        (should (eq (gethash ?z kkp-chord--tap-actions)
                    #'ri-smart-undo))
        (should (eq (lookup-key ri--undo-redo-layer-map "j")
                    #'ri-smart-undo))
        (should (eq (lookup-key ri--undo-redo-layer-map "l")
                    #'ri-smart-redo))
        (should (eq (lookup-key ri--undo-redo-layer-map "u")
                    #'ri-fine-undo))
        (should (eq (lookup-key ri--undo-redo-layer-map "o")
                    #'ri-fine-redo))
        ;; A plain press remains in this vector while its CSI-u release is
        ;; decoded.  That must not suppress the accepted layer's tap action.
        (cl-letf (((symbol-function 'this-command-keys-vector)
                   (lambda () [?z]))
                  ((symbol-function 'ri--hide-frame) #'ignore)
                  ((symbol-function 'modal-cursor-refresh) #'ignore))
          (cl-labels
              ((send (input)
                 (should
                  (equal
                   (kkp-chord--translate-advice
                    #'ignore (string-to-list input))
                   []))))
            ;; A plain printable press plus a CSI-u release is the path used
            ;; when the terminal does not escape every ordinary key.
            (let ((last-command-event ?z))
              (call-interactively #'ri--press-layer))
            (should keymap-legend--state)
            (should (equal (plist-get keymap-legend--state :title)
                           "≡ Undo/Redo"))
            (let ((text
                   (with-current-buffer keymap-legend-buffer-name
                     (buffer-string))))
              (should (string-match-p "Undo" text))
              (should (string-match-p "Coarse Redo" text)))
            (send "122;:3u")
            (should-not keymap-legend--state)
            (should (equal (buffer-string) "base"))
            ;; Plain sub-key presses use the active transient layer map.
            (let ((last-command-event ?z))
              (call-interactively #'ri--press-layer))
            (let ((command (key-binding "l")))
              (should (eq command #'ri-smart-redo))
              (let ((this-command command))
                (kkp-chord--mark-plain-command)
                (call-interactively command)))
            (send "122;:3u")
            (should (equal (buffer-string) "base change"))
            (let ((last-command-event ?z))
              (call-interactively #'ri--press-layer))
            (let ((command (key-binding "j")))
              (should (eq command #'ri-smart-undo))
              (let ((this-command command))
                (kkp-chord--mark-plain-command)
                (call-interactively command)))
            (send "122;:3u")
            (should (equal (buffer-string) "base"))))))))

(ert-deftest ri-chord-test-buffer-layer-registers-ki-bindings ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (let ((mini-modal-mode t)
            (ri--menu-state nil)
            (ri--help-prefix-active nil))
        (ri-chord-setup)
        (let ((spec (ri--layer-spec ?e)))
          (should (equal (plist-get spec :label) "≡ Buffer"))
          (should-not (plist-get spec :tap))
          (should (eq (plist-get spec :map) ri--buffer-layer-map)))
        (should (eq (gethash ?e kkp-chord--mod-maps)
                    ri--buffer-layer-map))
        (dolist
            (binding
             `(("j" . ,#'ki-tabs-switch-to-left-marked-buffer)
               ("l" . ,#'ki-tabs-switch-to-right-marked-buffer)
               ("y" . ,#'ki-tabs-switch-to-first-marked-buffer)
               ("p" . ,#'ki-tabs-switch-to-last-marked-buffer)
               ("u" . ,#'ki-tabs-switch-to-previous-buffer)
               ("o" . ,#'ki-tabs-switch-to-next-buffer)
               ("k" . ,#'ki-tabs-toggle-buffer-mark)
               ("n" . ,#'kill-current-buffer)
               ("i" . ,#'ki-tabs-unmark-other-buffers)
               ("m" . ,#'ki-tabs-switch-to-alternate-buffer)))
          (should (eq (lookup-key ri--buffer-layer-map (car binding))
                      (cdr binding))))
        (should (eq (lookup-key ri--normal-help-map "e") #'ignore))))))

(ert-deftest ri-chord-test-help-key-prompt-survives-shift-release ()
  (let ((ri--help-prefix-active t)
        (ri--restore-message-after-release nil)
        (pre-command-hook nil)
        (post-command-hook nil)
        (kkp-chord-after-release-hook
         '(ri--restore-message-after-release))
        (this-command #'Info-goto-emacs-key-command-node)
        (echo-message nil)
        (restore-count 0))
    (cl-letf (((symbol-function 'keymap-legend-hide) #'ignore)
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq echo-message
                       (apply #'format format-string args))
                 (cl-incf restore-count))))
      (ri--exit-help-prefix)
      ;; Kitty emits separate releases for shifted K and physical Shift.
      ;; Both can clear the echo area, so restore the prompt after each.
      (dolist (input '("107:75;2:3u" "57441;1:3u"))
        (setq echo-message nil)
        (should
         (equal
          (kkp-chord--translate-advice
           #'ignore (string-to-list input))
          []))
        (should
         (equal
          (and echo-message
               (substring-no-properties echo-message))
          "Find documentation for key: "))))
    (should (= restore-count 2))
    (run-hooks 'post-command-hook)
    (should-not ri--restore-message-after-release)))

(provide 'ri-chord-test)
;;; ri-chord-test.el ends here
