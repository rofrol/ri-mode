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
                    #'ri-undo-only))
        (should (eq (lookup-key ri--undo-redo-layer-map "j")
                    #'ri-smart-undo))
        (should (eq (lookup-key ri--undo-redo-layer-map "l")
                    #'ri-smart-redo))
        (should (eq (lookup-key ri--undo-redo-layer-map "u")
                    #'ri-fine-undo))
        (should (eq (lookup-key ri--undo-redo-layer-map "o")
                    #'ri-fine-redo))
        (should (eq (lookup-key ri--normal-help-map "z")
                    #'ri-undo-only))
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

(ert-deftest ri-chord-test-z-tap-undoes-buffer-without-consuming-extend ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "ab")
      (setq buffer-undo-list nil)
      (insert " change")
      (undo-boundary)
      (goto-char (point-min))
      (setq sr-submode 'char)
      (should (ri--enter-extend))
      (ri-extend-nav-right)
      (unwind-protect
          (let ((bounds (ri--selection-bounds))
                (edge (ri--selection-state-active-edge ri--selection))
                (selected-point (point))
                (history (ri--selection-state-undo-stack ri--selection))
                (mini-modal-mode t)
                (ri--menu-state nil)
                (ri--help-prefix-active nil)
                (last-command nil))
            (ri-chord-setup)
            (cl-letf (((symbol-function 'this-command-keys-vector)
                       (lambda () [?z]))
                      ((symbol-function 'ri--hide-frame) #'ignore)
                      ((symbol-function 'keymap-legend-show) #'ignore)
                      ((symbol-function 'keymap-legend-hide) #'ignore)
                      ((symbol-function 'modal-cursor-refresh) #'ignore))
              (let ((last-command-event ?z))
                (call-interactively #'ri--press-layer))
              (should (equal kkp-chord--held '((122))))
              (should
               (equal
                (kkp-chord--translate-advice
                 #'ignore (string-to-list "122;:3u"))
                [])))
            (should (equal (buffer-string) "ab"))
            (should (ri--selection-active-p))
            (should (equal (ri--selection-bounds) bounds))
            (should (eq (ri--selection-state-active-edge ri--selection)
                        edge))
            (should (= (point) selected-point))
            (should
             (eq (ri--selection-state-undo-stack ri--selection)
                 history)))
        (ri--exit-extend)))))

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
             `(("j" . ,#'ri-tabs-switch-to-left-marked-buffer)
               ("l" . ,#'ri-tabs-switch-to-right-marked-buffer)
               ("y" . ,#'ri-tabs-switch-to-first-marked-buffer)
               ("p" . ,#'ri-tabs-switch-to-last-marked-buffer)
               ("u" . ,#'ri-tabs-switch-to-previous-buffer)
               ("o" . ,#'ri-tabs-switch-to-next-buffer)
               ("k" . ,#'ri-toggle-buffer-mark)
               ("n" . ,#'kill-current-buffer)
               ("i" . ,#'ri-tabs-unmark-other-buffers)
               ("m" . ,#'ri-tabs-switch-to-alternate-buffer)))
          (should (eq (lookup-key ri--buffer-layer-map (car binding))
                      (cdr binding))))
        (should (eq (lookup-key ri--normal-help-map "e") #'ignore))))))

(ert-deftest ri-chord-test-navigation-layers-tap-commits-hold-restores ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (insert "alpha,beta\ngamma\n")
      (let ((mini-modal-mode t)
            (ri--menu-state nil)
            (ri--help-prefix-active nil)
            current-key)
        (ri-chord-setup)
        (dolist
            (case
             `((?a "≡ LINE" ,#'ri-extend-set-line-mode
                   ,ri--line-layer-map "k" ,#'ri-momentary-line-down
                   ("i" "k") line 12 char)
               (?s "WORD+" ,#'ri-extend-set-word-plus-mode
                   ,ri--word-plus-layer-map "l"
                   ,#'ri-momentary-word-plus-right
                   ("i" "j" "k" "l") word-plus 6 char)
               (?w "CHAR" ,#'ri-extend-set-subword-mode
                   ,ri--char-layer-map "l" ,#'ri-momentary-char-right
                   ("i" "j" "k" "l") char 2 line)))
          (pcase-let ((`(,key ,label ,tap ,map ,right-key ,right
                              ,motions ,layer-submode ,expected-point
                              ,tap-start)
                       case))
            (let ((spec (ri--layer-spec key)))
              (should (equal (plist-get spec :label) label))
              (should (eq (plist-get spec :tap) tap))
              (should-not (plist-get spec :activate-on-press))
              (should (plist-get spec :restore-on-release))
              (should-not (plist-get spec :release))
              (should (eq (plist-get spec :map) map)))
            (should (eq (lookup-key map right-key) right))
            (dolist (motion motions)
              (should (commandp (lookup-key map motion)))))
          (should (eq (lookup-key ri--normal-help-map "a")
                      #'ri-extend-set-line-mode))
          (should (eq (lookup-key ri--normal-help-map "s")
                      #'ri-extend-set-word-plus-mode))
          (should (eq (lookup-key ri--normal-help-map "w")
                      #'ri-extend-set-subword-mode))
          (cl-letf (((symbol-function 'this-command-keys-vector)
                     (lambda () (vector current-key)))
                    ((symbol-function 'ri--hide-frame) #'ignore)
                    ((symbol-function 'modal-cursor-refresh) #'ignore))
            (dolist
                (case
                 `((?a ,#'ri-momentary-line-down line 12)
                   (?s ,#'ri-momentary-word-plus-right word-plus 6)
                   (?w ,#'ri-momentary-char-right char 2)))
              (pcase-let ((`(,key ,right ,layer-submode ,expected-point)
                           case))
                (let ((release (format "%d;:3u" key)))
                  ;; Tap: press and release without a sub-key commits the tap
                  ;; target; the press itself must not switch the submode.
                  (setq current-key key
                        sr-submode (pcase key
                                     (?a 'char)
                                     (?s 'char)
                                     (?w 'line)))
                  (goto-char (point-min))
                  (let ((last-command-event key))
                    (call-interactively #'ri--press-layer))
                  (should (eq sr-submode (pcase key
                                           (?a 'char)
                                           (?s 'char)
                                           (?w 'line))))
                  (should
                   (equal
                    (kkp-chord--translate-advice
                     #'ignore (string-to-list release))
                    []))
                  (should (eq sr-submode (pcase key
                                           (?a 'line)
                                           (?s 'word-plus)
                                           (?w 'subword))))

                  ;; Hold: a sub-key navigates in the layer unit, and the
                  ;; release restores the tap-start submode without moving
                  ;; point.
                  (setq sr-submode (pcase key
                                     (?a 'char)
                                     (?s 'char)
                                     (?w 'line)))
                  (goto-char (point-min))
                  (let ((last-command-event key))
                    (call-interactively #'ri--press-layer))
                  (let ((command (key-binding (pcase key
                                                (?a "k")
                                                (_ "l")))))
                    (should (eq command right))
                    (kkp-chord--mark-plain-command)
                    (call-interactively command))
                  (should (= (point) expected-point))
                  (should (eq sr-submode layer-submode))
                  (should
                   (equal
                    (kkp-chord--translate-advice
                     #'ignore (string-to-list release))
                    []))
                  (should (eq sr-submode (pcase key
                                           (?a 'char)
                                           (?s 'char)
                                           (?w 'line))))
                  (should (= (point) expected-point)))))))))))

(ert-deftest ri-chord-test-hold-w-i-uses-char-highlight ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (insert "ab\ncd")
      (goto-char 4)
      (let ((mini-modal-mode t)
            (ri--menu-state nil)
            (ri--help-prefix-active nil)
            (sr-submode 'line))
        (ri-chord-setup)
        (cl-letf (((symbol-function 'this-command-keys-vector)
                   (lambda () [?w]))
                  ((symbol-function 'ri--hide-frame) #'ignore)
                  ((symbol-function 'modal-cursor-refresh) #'ignore))
          (let ((last-command-event ?w))
            (call-interactively #'ri--press-layer))
          (should (eq sr-submode 'line))
          (should (equal (sr--get-current-unit-bounds) (cons 4 6)))
          (let ((command (key-binding "i")))
            (should (eq command #'ri-momentary-char-up))
            (kkp-chord--mark-plain-command)
            (call-interactively command))
          (should (eq sr-submode 'char))
          (should (= (point) 1))
          (should (equal (sr--get-current-unit-bounds) (cons 1 2)))
          (should
           (cl-some (lambda (overlay)
                      (eq (overlay-get overlay 'face) 'sr-highlight-face))
                    (overlays-at 1)))
          (should-not
           (cl-some (lambda (overlay)
                      (eq (overlay-get overlay 'face) 'sr-highlight-face))
                    (overlays-at 2)))
          (kkp-chord--on-release ?w)
          (should (eq sr-submode 'line))
          (should (= (point) 1))
          (should (equal (sr--get-current-unit-bounds) (cons 1 3)))
          (should
           (cl-some (lambda (overlay)
                      (eq (overlay-get overlay 'face) 'sr-highlight-face))
                    (overlays-at 1)))
          (should
           (cl-some (lambda (overlay)
                      (eq (overlay-get overlay 'face) 'sr-highlight-face))
                    (overlays-at 2))))))))

(ert-deftest ri-chord-test-hold-a-k-uses-line-highlight ()
  (ri-chord-test--with-fresh-chords
    (with-temp-buffer
      (insert "ab\ncd")
      (goto-char 1)
      (let ((mini-modal-mode t)
            (ri--menu-state nil)
            (ri--help-prefix-active nil)
            (sr-submode 'char))
        (ri-chord-setup)
        (cl-letf (((symbol-function 'this-command-keys-vector)
                   (lambda () [?a]))
                  ((symbol-function 'ri--hide-frame) #'ignore)
                  ((symbol-function 'modal-cursor-refresh) #'ignore))
          (let ((last-command-event ?a))
            (call-interactively #'ri--press-layer))
          (should (eq sr-submode 'char))
          (let ((command (key-binding "k")))
            (should (eq command #'ri-momentary-line-down))
            (kkp-chord--mark-plain-command)
            (call-interactively command))
          (should (eq sr-submode 'line))
          (should (= (point) 4))
          (should (equal (sr--get-current-unit-bounds) (cons 4 6)))
          (should
           (cl-some (lambda (overlay)
                      (eq (overlay-get overlay 'face) 'sr-highlight-face))
                    (overlays-at 4)))
          (should-not
           (cl-some (lambda (overlay)
                      (eq (overlay-get overlay 'face) 'sr-highlight-face))
                    (overlays-at 1)))
          (kkp-chord--on-release ?a)
          (should (eq sr-submode 'char))
          (should (= (point) 4))
          (should (equal (sr--get-current-unit-bounds) (cons 4 5))))))))

(ert-deftest ri-chord-test-mark-user-error-is-preserved-for-key-release ()
  (let ((ri--restore-message-after-release nil)
        (ri--restore-message-until-command-end nil))
    (cl-letf (((symbol-function 'ri-tabs-toggle-buffer-mark)
               (lambda () (user-error "Buffer is not visiting a visible file"))))
      (should-error (ri-toggle-buffer-mark) :type 'user-error)
      (should (equal ri--restore-message-after-release
                     "Buffer is not visiting a visible file")))))

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


(ert-deftest ri-chord-test-parser-keeps-kitty-text-codepoint ()
  (let ((parsed (kkp-chord--parse (string-to-list "108;3:1;322u"))))
    (should (= (plist-get parsed :keycode) ?l))
    (should (= (plist-get parsed :modifier-num) 2))
    (should (= (plist-get parsed :event-type) kkp-chord--event-press))
    (should (equal (plist-get parsed :text-codepoints) '(322)))))

(ert-deftest ri-chord-test-altgr-l-becomes-polish-l-stroke ()
  (let ((translated
         (kkp-chord--translate-advice
          (lambda (_input) 'normal)
          (string-to-list "108;3:1;322u"))))
    (should (equal translated (vector ?ł)))))

(ert-deftest ri-chord-test-meta-l-remains-meta-l ()
  (let ((translated
         (kkp-chord--translate-advice
          (lambda (_input) 'normal)
          (string-to-list "108;3:1;108u"))))
    (should (eq translated 'normal))))

(ert-deftest ri-chord-test-shift-meta-l-remains-normal-kkp-input ()
  (let ((translated
         (kkp-chord--translate-advice
          (lambda (_input) 'normal)
          (string-to-list "108:76;4:1;76u"))))
    (should (eq translated 'normal))))

(provide 'ri-chord-test)
;;; ri-chord-test.el ends here
