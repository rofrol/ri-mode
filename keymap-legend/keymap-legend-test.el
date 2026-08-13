;;; keymap-legend-test.el --- Tests for keymap-legend.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'keymap-legend)

(defun keymap-legend-test--model-with-entry (entry &optional release)
  "Return a render model with ENTRY in the first physical cell."
  (let ((matrix (keymap-legend--empty-matrix)))
    (setf (nth 0 (nth 0 matrix))
          (list :row 0
                :column 0
                :normal-event ?a
                :shift-event ?A
                :normal entry
                :shift nil
                :alt nil))
    (list :matrix matrix
          :entries (if entry (list entry) nil)
          :overflow nil
          :release release)))

(ert-deftest keymap-legend-test-labels-have-a-hard-display-width-limit ()
  (let* ((keymap-legend-max-label-width 10)
         (long-label (make-string 80 ?x))
         (entry (list :key "a" :description long-label))
         (wide (keymap-legend--render-for-width
                (keymap-legend-test--model-with-entry entry)
                200))
         (narrow (keymap-legend--render-for-width
                  (keymap-legend-test--model-with-entry entry)
                  20))
         (overflow (keymap-legend--render-for-width
                    (list :matrix (keymap-legend--empty-matrix)
                          :entries nil
                          :overflow (list entry)
                          :release nil)
                    200))
         (expected "xxxxxxxxx…"))
    (should (equal (keymap-legend--limit-label long-label) expected))
    (should (= (string-width expected) keymap-legend-max-label-width))
    (should (< (plist-get wide :natural-width) 80))
    (should (string-match-p (regexp-quote expected)
                            (plist-get wide :text)))
    (should (string-match-p (regexp-quote expected)
                            (plist-get narrow :text)))
    (should (string-match-p (regexp-quote expected)
                            (plist-get overflow :text)))
    (should (eq (plist-get narrow :mode) 'compact))
    (should-not (string-match-p (regexp-quote long-label)
                                (plist-get wide :text)))
    (should-not (string-match-p (regexp-quote long-label)
                                (plist-get narrow :text)))
    (should-not (string-match-p (regexp-quote long-label)
                                (plist-get overflow :text)))))

(ert-deftest keymap-legend-test-default-limit-keeps-coarse-redo ()
  (let* ((entry (list :key "l" :description "Coarse Redo"))
         (rendered
          (keymap-legend--render-for-width
           (keymap-legend-test--model-with-entry entry)
           200)))
    (should (string-match-p
             (regexp-quote "Coarse Redo")
             (plist-get rendered :text)))))

(ert-deftest keymap-legend-test-release-label-is-bounded ()
  (let* ((keymap-legend-max-label-width 10)
         (long-label (make-string 80 ?x))
         (model (keymap-legend-test--model-with-entry nil long-label))
         (rendered (keymap-legend--render-for-width model 200)))
    (should (string-match-p
             (regexp-quote "Release hold: xxxxxxxxx…")
             (plist-get rendered :text)))
    (should-not (string-match-p (regexp-quote long-label)
                                (plist-get rendered :text)))))

(ert-deftest keymap-legend-test-keeps-command-labels-generic ()
  (should (equal (keymap-legend--command-description #'describe-variable)
                 "Describe Variable"))
  (should (equal (keymap-legend--command-description #'describe-prefix-bindings)
                 "Describe Prefix Bindings"))
  (should (equal (keymap-legend--command-description #'apropos)
                 "Apropos"))
  (should (equal (keymap-legend--command-description #'ignore)
                 "Ignore")))


(provide 'keymap-legend-test)
;;; keymap-legend-test.el ends here
