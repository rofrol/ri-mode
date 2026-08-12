# ri-mode

`ri-mode` is a terminal-first modal editing layer for Emacs 31.1 or
newer. Its tap-and-hold key layers require a terminal that supports the
Kitty Keyboard Protocol, such as Kitty, Ghostty, or WezTerm.

Ri starts in ordinary editing buffers, but skips minibuffers and
special modes.

## Setup

`ri-mode` bundles all Ri-specific helper libraries. The only external
dependency is [`kkp`](https://github.com/benjaminor/kkp).

### Local development

For local development from a checkout, point `use-package` at the repository
root:

```elisp
(use-package ri
  :load-path "~/personal_projects/emacs/ri-mode"
  :demand t
  :config
  (ri-enable))
```

### Install from MELPA (not yet avaiable)

Install `kkp` and `ri` from MELPA and load Ri with `use-package`:

```elisp
(use-package kkp
  :ensure t
  :demand t)

(use-package ri
  :ensure t
  :after kkp
  :demand t
  :config
  (ri-enable))
```

The MELPA recipe must include the bundled library directories. Once
installed, `ri.el` adds those directories to `load-path` internally, so
the user's configuration does not need any `:load-path` entries.

## Usage

The mode line shows the current state:

- `INST` is regular Emacs insert mode. Press `Esc` to enter `NORM`.
- `NORM[UNIT]` is normal mode, where `UNIT` is the currently highlighted
  semantic unit. Press `h` to insert at its start or `;` to insert at
  its end.
- `NORM[UNIT] Extend` means that Extend selection is active. Press
  `Esc` to leave Extend while staying in `NORM`.

Press `?` in `NORM` at any time for the complete, current keymap. The
main bindings are:

| Key                  | Action                                                       |
| -------------------- | ------------------------------------------------------------ |
| `j` / `l`            | Move left / right                                            |
| `i` / `k`            | Move up / down                                               |
| `u` / `o`            | Move to the previous / next unit                             |
| `y` / `p`            | Move to the first / last unit                                |
| `.`                  | Move to the parent line                                      |
| `a`, `A`, `E`, `W`   | Use `LINE`, `LINE*`, `PARAGRAPH`, or `CHAR` units           |
| `s`, `S`, `M-s`, `w` | Use `WORD`, `WORD*`, `WORD+`, or `SUBWORD` units             |
| `d`                  | Use a tree-sitter `NODE` unit                                |
| `f`                  | Start Extend; navigation then grows or shrinks the selection |
| `/`                  | Move the cursor to the other edge of the unit or selection   |
| `c`, `r`, `g`, `v`, `x` | Copy, delete, change, paste, or cut the unit/selection |
| `e` (hold)           | Open the Ki-style Buffer momentary layer                     |
| `I`                  | Join the current line to the previous line                  |
| `J` / `L`            | Dedent / indent nonblank selected lines by four columns      |
| `F`                  | Open the Transform menu                                      |
| `z` / `Z`            | Undo / redo; hold `z` for the Undo/Redo layer                |
| `RET`                | Save the buffer                                              |
| `SPC`                | Open the command menu                                        |
| `C-h`                | Show the default Emacs help keymap and read one help key |

The `c`, `r`, `e`, `g`, `t`, `v`, `x`, and `z` keys also act as
momentary layers. Hold one of them to display its available actions,
press the shown key while still holding it, then release. These layers
provide duplicate, eat, buffer, open, swap, paste, cut, and undo/redo
operations.

The Buffer layer matches Ki: `j`/`l` cycle marked buffers with wrapping,
`y`/`p` select the first/last marked buffer, `u`/`o` move through all
open files—including unmarked files—without wrapping, `k` toggles the
current buffer mark, `n` closes the current buffer, `i` unmarks the
others, and `m` switches to the alternate file. In the `z` layer,
`j`/`l` perform coarse undo/redo
and `u`/`o` perform character-granular undo/redo. A quick tap of `c`,
`r`, `g`, `v`, `x`, or `z` performs its primary action.

File marks are persistent: `e k` writes the mark immediately, and the
mark survives both buffer closure and an Emacs restart. Closing with
`e n` or the tab close action only kills the buffer; it does not unmark
the file. Only explicit mark commands (`e k`, `e i`, or their
`ri-tabs-*` command equivalents) change persistent membership. Closed
marked files are neither displayed nor reopened automatically, and
marked-file navigation continues to consider live buffers only.

`NODE` mode requires a tree-sitter grammar for the current major mode;
see the Tree-sitter setup below.

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
(defun my/treesit-generate-parser (&rest args)
  "If there is no parser.c, run tree-sitter generate."
  (when (and (equal "parser.c" (car (last args)))
             (not (file-exists-p (expand-file-name "parser.c")))
             ;; on macOS: brew install tree-sitter-cli
             (executable-find "tree-sitter"))
    (let ((default-directory (file-name-parent-directory default-directory)))
      (message "Generating parser.c with tree-sitter...")
      (treesit--call-process-signal
       (executable-find "tree-sitter") nil t nil "generate"))))

(advice-add 'treesit--call-process-signal :before #'my/treesit-generate-parser)

(setq treesit-language-source-alist
      '((elisp "https://github.com/Wilfred/tree-sitter-elisp")
        (odin  "https://github.com/tree-sitter-grammars/tree-sitter-odin")))

(dolist (lang (mapcar #'car treesit-language-source-alist))
  (unless (treesit-language-available-p lang)
    (message "Installing tree-sitter grammar for %s..." lang)
    (treesit-install-language-grammar lang)))

(use-package odin-ts-mode
  :vc (:url "https://github.com/Sampie159/odin-ts-mode.git")
  :mode "\\.odin\\'"
  :hook (odin-ts-mode . eglot-ensure))
```
