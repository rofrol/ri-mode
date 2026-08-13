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
| `,`                  | Open the Ki-style Surround menu                              |
| `z` / `Z`            | Undo / redo; hold `z` for the Undo/Redo layer                |
| `RET`                | Save the buffer                                              |
| `SPC`                | Open the command menu                                        |
| `C-h`                | Show the default Emacs help keymap and read one help key |

The Surround menu is a prefix menu rather than a hold layer, matching Ki's
spatial enclosure layout. Press `,` and then `s` to surround, `r` to delete a
surround, `f` to change one, `d` to select inside, or `e` to select around.
Enclosure keys are `m` for `()`, `,` for `[]`, `.` for `{}`, `/` for `<>`,
`j` for single quotes, `k` for double quotes, and `l` for backticks. In the
Surround submenu, `;` prompts for an HTML/XML tag. For example, `, s ,` wraps
the current unit/selection in square brackets, and `, f m .` changes `()` to
`{}`. Select Inside/Around enters Extend with exact enclosure bounds.

The Space layer includes Ki's global LSP key positions: `SPC Z` shows
outgoing calls, `SPC z` incoming calls, `SPC x` definitions, `SPC X`
declarations, `SPC c` type definitions, `SPC V` references including the
declaration, `SPC v` references excluding the declaration, and `SPC b`
implementations. These commands require an active Eglot server and the
corresponding server capability. Results use Emacs's native Xref or Eglot
hierarchy UI and do not require tree-sitter. When invoked during Extend, a
supported navigation exits Extend before moving; an unavailable server or
capability leaves the exact selection unchanged.

The Space layer also contains Ki's Pick submenu. Press `SPC k f` to pick an
open file buffer, `SPC k d` to pick a file from the current project,
`SPC k s` to pick an Eglot document symbol, or `SPC k S` to search Eglot
workspace symbols. The picker is a centered child-frame window with fuzzy
query input and leaves its current keymap legend visible at the bottom.
`C-j`/`C-k` or the arrow keys move through results, `RET` opens the selected
item, and `Esc` or `C-g` cancels. File candidates follow `project.el` backend
ignore rules; Buffer includes live file-visiting buffers. Document and
Workspace symbol pickers require the corresponding Eglot capability.
Cancelling preserves the exact source point and any active Extend selection.

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

File tabs use one Ri-owned top side-window surface spanning each ordinary
frame. Splitting a frame does not duplicate the bar. The active tab follows
the frame's selected editing window, and selecting a file tab changes only
that window's buffer; other editing windows and their layout remain unchanged.
Ri lays tabs out explicitly: widths follow rendered content, complete tabs wrap
to additional rows when they no longer fit, and the surface shrinks back when
more horizontal space becomes available. Native `tab-bar-mode` workspace tabs
and their configuration are left untouched. File labels normally use only the
basename. If basenames collide, a sole owner-local file keeps the basename
while foreign duplicates receive the shortest parent-directory suffix needed
to distinguish them; multiple owner-local duplicates are also qualified only
as much as necessary.

File marks are persistent: `e k` writes the mark immediately, and the
mark survives both buffer closure and an Emacs restart. When Ki tabs
activates after restart—or is disabled and enabled again—it reopens
every available still-marked file without selecting or displaying it.
Closing with `e n` or the tab close action only kills the buffer, so it
stays closed for the current activation and returns on the next
activation or restart. Explicit mark commands (`e k`, `e i`, or their
`ri-tabs-*` equivalents) are the only operations that change persistent
membership; explicitly unmarking a file prevents future restoration.
Unavailable paths remain marked and are retried on a later activation.
Marked-file navigation continues to consider live buffers only.

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
