## System clipboard on macOS in terminal

in init.el:

```elisp
(use-package osx-clipboard
  :ensure t
  :if (eq system-type 'darwin)
  :config
  (osx-clipboard-mode +1))
```
