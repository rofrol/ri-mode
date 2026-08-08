## System clipboard on macOS in terminal

Add to init.el:

```elisp
(use-package osx-clipboard
  :ensure t
  :if (eq system-type 'darwin)
  :config
  (osx-clipboard-mode +1))
```

## Tree-sitter

add to init.el:

```elisp
;; Will change in Emacs 31 https://www.rahuljuliato.com/posts/emacs-31-around-the-corner

(setq treesit-language-source-alist
      '((elisp . ("https://github.com/Wilfred/tree-sitter-elisp"))))

(defun my/treesit-generate-parser (&rest args)
  "If there is no parser.c, run tree-sitter generate."
  (when (and (equal "parser.c" (car (last args)))
             (not (file-exists-p (expand-file-name "parser.c")))
             (executable-find "tree-sitter"))
    (let ((default-directory (file-name-parent-directory default-directory)))
      (message "Generating parser.c with tree-sitter...")
      (treesit--call-process-signal
       (executable-find "tree-sitter") nil t nil "generate"))))

(advice-add 'treesit--call-process-signal :before #'my/treesit-generate-parser)

(dolist (lang (mapcar #'car treesit-language-source-alist))
  (unless (treesit-language-available-p lang)
    (message "Installing tree-sitter grammar for %s..." lang)
    (treesit-install-language-grammar lang)))
```
