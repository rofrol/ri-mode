;;; ri-startup-benchmark.el --- Fresh-process Ri startup benchmark -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root with:
;;
;;   emacs -Q --batch -L "$KKP_DIR" -L . \
;;     -l ri-startup-benchmark.el \
;;     --eval '(ri-startup-benchmark-run)'

;;; Code:

(require 'subr-x)

(defconst ri-startup-benchmark--sentinel "RI_STARTUP_DONE")

(defun ri-startup-benchmark--median (values)
  "Return the median of numeric VALUES."
  (let* ((sorted (sort (copy-sequence values) #'<))
         (length (length sorted))
         (middle (/ length 2)))
    (if (zerop (% length 2))
        (/ (+ (nth (1- middle) sorted) (nth middle sorted)) 2.0)
      (nth middle sorted))))

(defun ri-startup-benchmark--mad (values)
  "Return the median absolute deviation of numeric VALUES."
  (let ((median (ri-startup-benchmark--median values)))
    (ri-startup-benchmark--median
     (mapcar (lambda (value) (abs (- value median))) values))))

(defun ri-startup-benchmark--revision (root)
  "Return ROOT's short Git revision, or \"unknown\"."
  (if-let* ((git (executable-find "git"))
            (default-directory root)
            (output (with-temp-buffer
                      (when (zerop (call-process git nil t nil
                                                 "rev-parse" "--short" "HEAD"))
                        (string-trim (buffer-string))))))
      output
    "unknown"))

(defun ri-startup-benchmark--child-arguments (scenario root kkp-dir state-dir)
  "Build child arguments for SCENARIO using ROOT, KKP-DIR, and STATE-DIR."
  (let ((setup (format
                "(setq user-emacs-directory %S default-directory %S gc-cons-threshold most-positive-fixnum)"
                (file-name-as-directory state-dir)
                (file-name-as-directory state-dir)))
        (done (format "(progn (garbage-collect) (princ %S))"
                      ri-startup-benchmark--sentinel)))
    (append
     (list "-Q" "--batch" "--eval" setup)
     (pcase scenario
       ('control nil)
       ('load (list "-L" kkp-dir "-L" root "-l"
                    (expand-file-name "ri.el" root)))
       ('enable (list "-L" kkp-dir "-L" root "-l"
                      (expand-file-name "ri.el" root)
                      "--eval" "(ri-enable)"))
       (_ (error "Unknown startup scenario: %S" scenario)))
     (list "--eval" done))))

(defun ri-startup-benchmark--sample (emacs scenario root kkp-dir state-dir)
  "Measure one fresh EMACS process for SCENARIO and return milliseconds."
  (let ((output (generate-new-buffer " *ri-startup-child*"))
        (started (current-time)))
    (unwind-protect
        (let* ((status (apply #'call-process emacs nil output nil
                              (ri-startup-benchmark--child-arguments
                               scenario root kkp-dir state-dir)))
               (elapsed (* 1000.0 (float-time
                                   (time-subtract (current-time) started))))
               (text (with-current-buffer output (buffer-string))))
          (unless (and (equal status 0)
                       (string-match-p ri-startup-benchmark--sentinel text))
            (error "Startup child %S failed (%S): %s"
                   scenario status (string-trim text)))
          elapsed)
      (kill-buffer output))))

(defun ri-startup-benchmark--run-round (emacs root kkp-dir state-dir results)
  "Measure every scenario once and append samples to RESULTS."
  (dolist (scenario '(control load enable))
    (push (ri-startup-benchmark--sample
           emacs scenario root kkp-dir state-dir)
          (alist-get scenario results))))

(defun ri-startup-benchmark--print-metric (name value)
  "Print millisecond metric NAME with numeric VALUE."
  (princ (format "%s=%.3f\n" name value)))

;;;###autoload
(defun ri-startup-benchmark-run ()
  "Benchmark fresh control, Ri load, and Ri enable child processes."
  (interactive)
  (let* ((root (file-name-directory
                (or load-file-name
                    (locate-library "ri-startup-benchmark")
                    (error "Cannot determine repository root"))))
         (kkp-dir (when-let* ((value (getenv "KKP_DIR")))
                    (expand-file-name value)))
         (runs (string-to-number (or (getenv "RI_STARTUP_RUNS") "9")))
         (emacs (expand-file-name invocation-name invocation-directory))
         (state-dir (make-temp-file "ri-startup-" t))
         (results '((control) (load) (enable))))
    (unless (and kkp-dir
                 (file-exists-p (expand-file-name "kkp.el" kkp-dir)))
      (error "KKP_DIR must name the directory containing kkp.el"))
    (unless (> runs 0)
      (error "RI_STARTUP_RUNS must be a positive integer"))
    (unwind-protect
        (progn
          (ri-startup-benchmark--run-round
           emacs root kkp-dir state-dir '((control) (load) (enable)))
          (dotimes (_ runs)
            (ri-startup-benchmark--run-round
             emacs root kkp-dir state-dir results))
          (let* ((control (ri-startup-benchmark--median
                           (alist-get 'control results)))
                 (load (ri-startup-benchmark--median
                        (alist-get 'load results)))
                 (enable (ri-startup-benchmark--median
                          (alist-get 'enable results)))
                 (load-increment (- load control))
                 (enable-increment (- enable load)))
            (princ (format "emacs_version=%s\n" emacs-version))
            (princ (format "system_configuration=%s\n" system-configuration))
            (princ (format "repository_revision=%s\n"
                           (ri-startup-benchmark--revision root)))
            (princ (format "repetitions=%d\n" runs))
            (ri-startup-benchmark--print-metric "control_median_ms" control)
            (ri-startup-benchmark--print-metric
             "control_mad_ms"
             (ri-startup-benchmark--mad (alist-get 'control results)))
            (ri-startup-benchmark--print-metric "load_median_ms" load)
            (ri-startup-benchmark--print-metric "enable_median_ms" enable)
            (ri-startup-benchmark--print-metric
             "load_increment_ms" load-increment)
            (ri-startup-benchmark--print-metric
             "enable_increment_ms" enable-increment)
            (ri-startup-benchmark--print-metric
             "load_over_control_pct" (* 100.0 (/ load-increment control)))
            (ri-startup-benchmark--print-metric
             "enable_over_load_pct" (* 100.0 (/ enable-increment load)))))
      (delete-directory state-dir t))))

(provide 'ri-startup-benchmark)
;;; ri-startup-benchmark.el ends here
