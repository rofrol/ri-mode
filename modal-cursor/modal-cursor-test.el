;;; modal-cursor-test.el --- Tests for modal-cursor.el -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'modal-cursor)

(defvar modal-cursor-test--normal nil)

(ert-deftest modal-cursor-test-refresh-follows-watched-state ()
  (with-temp-buffer
    (let ((modal-cursor-watched-mode 'modal-cursor-test--normal)
          sent)
      (cl-letf (((symbol-function 'modal-cursor--tty-p) (lambda () t))
                ((symbol-function 'send-string-to-terminal)
                 (lambda (string &optional _terminal)
                   (push string sent))))
        (dolist (case '((t box "\e[2 q")
                        (nil (bar . 1) "\e[6 q")))
          (pcase-let ((`(,normal ,type ,sequence) case))
            (setq modal-cursor-test--normal normal
                  sent nil)
            (modal-cursor-refresh)
            (should (equal cursor-type type))
            (should (equal sent (list sequence)))))))))

(ert-deftest modal-cursor-test-reasserts-normal-shape-before-redisplay ()
  (with-temp-buffer
    (let ((modal-cursor-watched-mode 'modal-cursor-test--normal)
          (modal-cursor-test--normal t)
          sent)
      (cl-letf (((symbol-function 'modal-cursor--tty-p) (lambda () t))
                ((symbol-function 'send-string-to-terminal)
                 (lambda (string &optional _terminal)
                   (push string sent))))
        (modal-cursor--update)
        (should (memq #'modal-cursor--pre-redisplay
                      pre-redisplay-functions))
        (setq sent nil)
        (run-hook-with-args 'pre-redisplay-functions (selected-window))
        (should (equal sent '("\e[2 q")))))))

(provide 'modal-cursor-test)
;;; modal-cursor-test.el ends here
