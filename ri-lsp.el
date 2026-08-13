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

(defun ri-lsp--run (capability function &rest arguments)
  "Preflight CAPABILITY, leave Extend, then call FUNCTION with ARGUMENTS.
An unmanaged buffer or unsupported server capability fails before Ri changes
point or the current Extend selection."
  (unless (eglot-current-server)
    (user-error "No Eglot server manages this buffer"))
  (eglot-server-capable-or-lose capability)
  (when (ri--selection-active-p)
    (ri--exit-extend)
    (ri--update-highlight)
    (force-mode-line-update))
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

(provide 'ri-lsp)
;;; ri-lsp.el ends here
