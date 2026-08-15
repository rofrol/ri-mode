;;; ri-transform-test.el --- Tests for ri-transform.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ri)

(defmacro ri-transform-test--with-fresh-chords (&rest body)
  "Run BODY with isolated chord registrations and held state."
  (declare (indent 0) (debug t))
  `(let ((kkp-chord--held nil)
         (kkp-chord--mod-maps (make-hash-table :test 'eql))
         (kkp-chord--tap-actions (make-hash-table :test 'eql))
         (kkp-chord--predicates (make-hash-table :test 'eql))
         (kkp-chord--press-actions (make-hash-table :test 'eql))
         (kkp-chord--release-actions (make-hash-table :test 'eql))
         (kkp-chord-after-release-hook nil))
     ,@body))

(ert-deftest ri-transform-test-registers-menu-instead-of-chord ()
  (ri-transform-test--with-fresh-chords
    (let ((mini-modal-map (make-sparse-keymap))
          (minor-mode-alist nil)
          (find-file-hook nil)
          (sr-highlight-predicate nil)
          (status-frame-height 0))
      (dolist (table (list kkp-chord--mod-maps
                           kkp-chord--tap-actions
                           kkp-chord--predicates
                           kkp-chord--press-actions
                           kkp-chord--release-actions))
        (puthash ?F t table))
      (cl-letf (((symbol-function 'modal-cursor-mode) #'ignore)
                ((symbol-function 'mini-modal-setup) #'ignore)
                ((symbol-function 'kkp-chord-mode) #'ignore)
                ((symbol-function 'global-kkp-mode) #'ignore)
                ((symbol-function 'buffer-list)
                 (lambda (&optional _frame) nil)))
        (ri-enable)
        (should (eq (lookup-key mini-modal-map "F")
                    #'ri-transform-menu))
        (should (eq (lookup-key ri--normal-help-map "F")
                    #'ri-transform-menu))
        (should-not (ri--layer-spec ?F))
        (dolist (table (list kkp-chord--mod-maps
                             kkp-chord--tap-actions
                             kkp-chord--predicates
                             kkp-chord--press-actions
                             kkp-chord--release-actions))
          (should-not (gethash ?F table)))))))

(ert-deftest ri-transform-test-menu-survives-trigger-release ()
  (ri-transform-test--with-fresh-chords
    (let ((ri--menu-state nil)
          visible
          transient-map
          transient-keep
          transient-exit)
      (cl-letf (((symbol-function 'keymap-legend-show)
                 (lambda (&rest _args) (setq visible t)))
                ((symbol-function 'keymap-legend-hide)
                 (lambda () (setq visible nil)))
                ((symbol-function 'ri--hide-frame) #'ignore)
                ((symbol-function 'set-transient-map)
                 (lambda (map &optional keep-pred on-exit)
                   (setq transient-map map
                         transient-keep keep-pred
                         transient-exit on-exit))))
        (ri-transform-menu)
        (should visible)
        (should (eq ri--menu-state 'transform))
        (should (eq transient-map ri--transform-menu-map))
        (should (functionp transient-keep))
        (should (funcall transient-keep))

        ;; KKP swallows the key-up event; it must not close Transform.
        (should (equal (kkp-chord--translate-advice
                        #'identity (string-to-list "102:70;1:3u"))
                       []))
        (should visible)
        (should (eq ri--menu-state 'transform))

        ;; The menu remains active until its explicit exit callback runs.
        (funcall transient-exit)
        (should-not visible)
        (should-not ri--menu-state)))))

(ert-deftest ri-transform-test-selected-command-closes-menu ()
  (let ((ri--menu-state 'transform)
        visible
        deactivated)
    (cl-letf (((symbol-function 'ri--selection-bounds)
               (lambda () nil))
              ((symbol-function 'keymap-legend-hide)
               (lambda () (setq visible nil)))
              ((symbol-function 'ri--hide-frame) #'ignore)
              ((symbol-function 'set-transient-map)
               (lambda (map &optional _keep-pred _on-exit)
                 (when (null map)
                   (setq deactivated t))))
              ((symbol-function 'keymap-legend-show)
               (lambda (&rest _args) (setq visible t))))
      (setq visible t)
      (ri-transform-upper)
      (should deactivated)
      (should-not visible)
      (should-not ri--menu-state))))

(provide 'ri-transform-test)
;;; ri-transform-test.el ends here
