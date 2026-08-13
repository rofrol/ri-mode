;;; ri-lsp.el --- Eglot-backed navigation for Ri -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;; SPDX-License-Identifier: Apache-2.0
;; Author: Roman Frołow

;;; Commentary:

;; Ki-compatible symbol navigation backed by Eglot and Emacs Xref.
;; No operation in this library uses tree-sitter as a location fallback.

;;; Code:

(require 'eglot)
(require 'xref)
(require 'ri-extend)
(require 'ri-pick)

(defun ri-lsp--server-for (capability)
  "Return the current Eglot server after checking CAPABILITY."
  (let ((server (eglot-current-server)))
    (unless server
      (user-error "No Eglot server manages this buffer"))
    (eglot-server-capable-or-lose capability)
    server))

(defun ri-lsp--leave-extend ()
  "Leave Extend before an accepted LSP navigation changes location."
  (when (ri--selection-active-p)
    (ri--exit-extend)
    (ri--update-highlight)
    (force-mode-line-update)))

(defun ri-lsp--run (capability function &rest arguments)
  "Preflight CAPABILITY, leave Extend, then call FUNCTION with ARGUMENTS.
An unmanaged buffer or unsupported server capability fails before Ri changes
point or the current Extend selection."
  (ri-lsp--server-for capability)
  (ri-lsp--leave-extend)
  (apply function arguments))

(defun ri-lsp--find-outgoing-calls ()
  "Show callees of the symbol at point with Eglot."
  (ri-lsp--run :callHierarchyProvider
               #'eglot-show-call-hierarchy 'base))

(defun ri-lsp--find-incoming-calls ()
  "Show callers of the symbol at point with Eglot."
  (ri-lsp--run :callHierarchyProvider
               #'eglot-show-call-hierarchy 'incoming))

(defun ri-lsp--find-definition ()
  "Find definitions of the symbol at point with Eglot's Xref backend."
  (ri-lsp--run :definitionProvider
               #'call-interactively #'xref-find-definitions))

(defun ri-lsp--find-declaration ()
  "Find declarations of the symbol at point with Eglot."
  (ri-lsp--run :declarationProvider #'eglot-find-declaration))

(defun ri-lsp--find-type-definition ()
  "Find type definitions of the symbol at point with Eglot."
  (ri-lsp--run :typeDefinitionProvider #'eglot-find-typeDefinition))

(defun ri-lsp--find-references-with-declaration ()
  "Find references including the declaration with Eglot's Xref backend."
  (ri-lsp--run :referencesProvider
               #'call-interactively #'xref-find-references))

(defun ri-lsp--find-references-without-declaration ()
  "Find references excluding the declaration with Eglot's Xref UI."
  ;; Eglot's public Xref backend always requests includeDeclaration=true.
  ;; Keep this sole internal API use isolated so Ref- still shares Eglot's
  ;; capability checks, location conversion, and Xref presentation.
  (ri-lsp--run
   :referencesProvider
   #'eglot--lsp-xref-helper
   :textDocument/references
   :extra-params '(:context (:includeDeclaration :json-false))))

(defun ri-lsp--find-implementations ()
  "Find implementations of the symbol at point with Eglot."
  (ri-lsp--run :implementationProvider #'eglot-find-implementation))

(defun ri-lsp--imenu-position (value)
  "Return a buffer position represented by imenu VALUE, or nil."
  (cond
   ((integer-or-marker-p value) value)
   ((overlayp value) (overlay-start value))))

(defun ri-lsp--flatten-imenu (entries buffer &optional parents)
  "Flatten imenu ENTRIES from BUFFER below PARENTS into picker items."
  (cl-mapcan
   (lambda (entry)
     (let* ((raw-name (car-safe entry))
            (name (and raw-name (substring-no-properties raw-name)))
            (value (cdr-safe entry))
            (position (ri-lsp--imenu-position value)))
       (cond
        ((or (null name) (string= name "*Rescan*")) nil)
        (position
         (let* ((kind (get-text-property 0 'imenu-kind raw-name))
                (label (string-join (append parents (list name)) " › ")))
           (list
            (ri-pick-item-create
             :label label
             :annotation (or kind "")
             :search (string-join
                      (delq nil (list label (and kind (format "%s" kind))))
                      " ")
             :target (list :buffer buffer
                           :position (copy-marker position))))))
        ((listp value)
         (ri-lsp--flatten-imenu value buffer (append parents (list name))))
        (t nil))))
   entries))

(defun ri-lsp--refresh-after-jump ()
  "Refresh Ri selection highlighting after an accepted LSP jump."
  (ri--update-highlight)
  (force-mode-line-update)
  (when (get-buffer-window (current-buffer) t)
    (recenter)))

(defun ri-lsp--accept-document-symbol (item)
  "Navigate to the document symbol targeted by picker ITEM."
  (let* ((target (ri-pick-item-target item))
         (buffer (plist-get target :buffer))
         (position (plist-get target :position)))
    (unless (and (buffer-live-p buffer) (marker-position position))
      (user-error "Selected document symbol no longer exists"))
    (ri-lsp--leave-extend)
    (xref-push-marker-stack)
    (switch-to-buffer buffer)
    (goto-char position)
    (ri-lsp--refresh-after-jump)))

(defun ri-lsp-pick-document-symbols (&optional on-close)
  "Pick an Eglot document symbol and call ON-CLOSE when the picker closes."
  (interactive)
  (ri-lsp--server-for :documentSymbolProvider)
  (let* ((buffer (current-buffer))
         (items (ri-lsp--flatten-imenu (eglot-imenu) buffer)))
    (ri-pick-start "Symbol (Document)" items
                   #'ri-lsp--accept-document-symbol
                   :on-close on-close)))

(defun ri-lsp--symbol-kind-name (kind)
  "Return Eglot's display name for LSP symbol KIND."
  (or (alist-get kind eglot--symbol-kind-names) "Unknown"))

(defun ri-lsp--workspace-symbol-items (symbols root)
  "Convert workspace SYMBOLS into picker items displayed relative to ROOT."
  (mapcar
   (lambda (symbol)
     (let* ((name (or (plist-get symbol :name) ""))
            (container (plist-get symbol :containerName))
            (kind (ri-lsp--symbol-kind-name (plist-get symbol :kind)))
            (location (plist-get symbol :location))
            (uri (plist-get location :uri))
            (range (plist-get location :range))
            (path (and uri (eglot-uri-to-path uri)))
            (line (and range
                       (1+ (or (plist-get
                                (plist-get range :start) :line)
                               0))))
            (display-path
             (and path
                  (if (file-in-directory-p path root)
                      (file-relative-name path root)
                    (abbreviate-file-name path))))
            (where (cond
                    ((and display-path line)
                     (format "%s:%d" display-path line))
                    (display-path display-path)
                    (t "")))
            (annotation
             (string-join
              (seq-filter
               (lambda (part) (and part (not (string-empty-p part))))
               (list container kind where))
              " · ")))
       (ri-pick-item-create
        :label name
        :annotation annotation
        :search (string-join
                 (seq-filter
                  (lambda (part) (and part (not (string-empty-p part))))
                  (list name container kind display-path))
                 " ")
        :target symbol)))
   symbols))

(defun ri-lsp--workspace-provider (buffer server root query success error)
  "Request workspace symbols for QUERY from SERVER on behalf of BUFFER.
ROOT controls path presentation.  SUCCESS and ERROR are picker callbacks."
  (unless (buffer-live-p buffer)
    (user-error "The workspace-symbol source buffer no longer exists"))
  (with-current-buffer buffer
    (eglot--async-request
     server :workspace/symbol `(:query ,query)
     :success-fn
     (lambda (symbols)
       (funcall success (ri-lsp--workspace-symbol-items symbols root)))
     :error-fn
     (lambda (response-error)
       (funcall error
                (or (plist-get response-error :message)
                    (format "%s" response-error))))
     :hint :workspace/symbol))
  (lambda ()
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (eglot--cancel-inflight-async-requests '(:workspace/symbol))))))

(defun ri-lsp--accept-workspace-symbol (item)
  "Navigate to the workspace symbol targeted by picker ITEM."
  (let* ((symbol (ri-pick-item-target item))
         (location (plist-get symbol :location))
         (uri (plist-get location :uri))
         (range (plist-get location :range)))
    (unless (and uri range)
      (user-error "Selected workspace symbol has no concrete location"))
    (ri-lsp--leave-extend)
    (xref-push-marker-stack)
    (find-file (eglot-uri-to-path uri))
    (goto-char (car (eglot-range-region range)))
    (ri-lsp--refresh-after-jump)))

(defun ri-lsp-pick-workspace-symbols (&optional on-close)
  "Pick an Eglot workspace symbol and call ON-CLOSE when the picker closes."
  (interactive)
  (let* ((server (ri-lsp--server-for :workspaceSymbolProvider))
         (buffer (current-buffer))
         (project (project-current nil))
         (root (file-name-as-directory
                (expand-file-name
                 (if project (project-root project) default-directory)))))
    (ri-pick-start
     "Symbol (Workspace)" nil #'ri-lsp--accept-workspace-symbol
     :provider
     (lambda (query success error)
       (ri-lsp--workspace-provider
        buffer server root query success error))
     :on-close on-close)))

(provide 'ri-lsp)
;;; ri-lsp.el ends here
