# status-frame

Minimal Emacs 31 package for `emacs -nw` using TTY child frames.
It creates a multi-row child-frame panel directly above the bottom mode line.

```elisp
(add-to-list 'load-path "/path/to/status-frame")
(require 'status-frame)

(status-frame-show "line 1\nline 2\nline 3\nline 4")
```

Default height is 4 terminal rows:

```elisp
(setq status-frame-height 6)
```

or dynamically:

```elisp
(status-frame-set-height 6)
```

API:

```elisp
(status-frame-show STRING)
(status-frame-set-text STRING)
(status-frame-set-height HEIGHT)
(status-frame-hide)
(status-frame-delete)
```

Requires:

```elisp
(featurep 'tty-child-frames)
```
