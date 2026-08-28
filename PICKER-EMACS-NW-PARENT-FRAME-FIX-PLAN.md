# Picker `emacs -nw` Parent-Frame Fix Plan

## Problem

`Pick > File` fails in a directly started terminal Emacs:

```text
emacs -nw
Invalid `parent-frame` frame parameter
```

The same picker works when the terminal frame is created by:

```sh
emacsclient -t -a ""
```

Ri targets Emacs 31.1 or newer and terminals supporting the Kitty Keyboard Protocol, such as Kitty, Ghostty, and WezTerm. Emacs 31 added native TTY child frames; the picker should use that support in both startup modes.

## Evidence and Root Cause

All picker entry points (`File`, `Buffer`, `Symbol (Document)`, and `Symbol (Workspace)`) reach `ri-pick-start` in `ri-pick/ri-pick.el`. That function calls `display-buffer-in-child-frame` with parameters produced by `ri-pick--frame-parameters`.

The parameter list pins the child to `parent` through `parent-frame` and reuses the parent's minibuffer, but it does not pin the new frame to the parent's terminal. Emacs therefore infers the new frame's terminal while processing `make-frame`.

Emacs validates that a child frame and its parent belong to the same terminal. A mismatch triggers the exact error:

```text
Invalid `parent-frame` frame parameter
```

The direct `emacs -nw` and daemon/client startup paths construct their root TTY frames differently, so relying on implicit terminal inference is fragile. The client path currently inherits the expected terminal; the reported direct-start path does not.

A probe on the currently installed Emacs 32.0.50 succeeds even without an explicit terminal, so the failure is build/path-dependent. Verification must include the affected Emacs 31.1+ build rather than treating current Emacs master behavior as sufficient.

## Decision

Pass the parent's terminal explicitly when creating the picker child frame:

```elisp
(terminal . ,(frame-terminal parent))
```

Add this to `ri-pick--frame-parameters` beside `parent-frame` and `minibuffer`. This is the smallest root-cause fix: the child frame's terminal, parent, and minibuffer all come from the same source frame, satisfying Emacs' frame invariant without changing picker behavior.

Keep the fix in the shared picker frame parameters. Do not special-case `ri-pick-open-files`; every picker uses the same child-frame creation path and has the same exposure.

## Implementation

### 1. Confirm the failing invariant on the affected build

Run the reported `emacs -nw` path with `debug-on-error` enabled and open `Pick > File`. Record:

- `emacs-version`;
- `(featurep 'tty-child-frames)`;
- `(frame-terminal (selected-frame))` before opening the picker;
- the backtrace showing `display-buffer-in-child-frame` / `make-frame` and the `parent-frame` error.

Repeat once with `emacsclient -t -a ""` to preserve the known-good baseline. The target build must report non-nil for `tty-child-frames`; KKP support alone does not provide Emacs' child-frame implementation.

### 2. Bind the child to the parent's terminal

Update only `ri-pick--frame-parameters` in `ri-pick/ri-pick.el`:

- add `(terminal . ,(frame-terminal parent))`;
- retain `(parent-frame . ,parent)`;
- retain `(minibuffer . ,(minibuffer-window parent))`;
- leave geometry, decorations, cursor parameters, and `share-child-frame` unchanged.

Do not wrap `display-buffer` in frame-selection side effects. Explicit frame parameters are more reliable than temporarily changing global selection and directly express the required invariant.

Do not add a fallback side window. Emacs 31.1 is Ri's minimum version and provides native TTY child frames; silently changing the UI would hide a frame-association bug rather than fix it.

### 3. Preserve cleanup and source restoration

Keep `ri-pick-start`'s existing `unwind-protect` and `ri-pick--cleanup` flow unchanged. The fix only affects frame creation. Cancellation must continue to restore the original frame, window, buffer, point, and any active Extend selection.

Do not modify `status-frame` unless its own public show path reproduces the same failure. It is a separate child-frame owner and changing it without a reproduction would expand the patch unnecessarily.

## Regression Check

The repository intentionally removed the former picker test file, so do not recreate a test suite merely to assert one frame-parameter alist entry. Use the real TTY surface, where Emacs enforces the terminal/parent invariant.

On the affected Emacs 31.1+ executable, in each supported KKP terminal available (at minimum the terminal that reported the bug):

1. Start `emacs -nw` and confirm `(featurep 'tty-child-frames)` is non-nil.
2. Load Ri, enable it, and open `Pick > File` with `SPC k d`.
3. Confirm the picker opens without the `parent-frame` error.
4. While the picker is open, confirm its frame and source frame share the same terminal:

   ```elisp
   (eq (frame-terminal
        (window-frame (ri-pick--session-window ri-pick--session)))
       (frame-terminal
        (ri-pick--session-source-frame ri-pick--session)))
   ```

5. Type and delete query text, move through results, accept a file, cancel a second invocation, and resize the terminal. Confirm rendering, selection, and cleanup remain correct.
6. Open `Pick > Buffer` once to verify the shared picker path rather than only the File caller.
7. Repeat the open/query/cancel smoke check with `emacsclient -t -a ""` to ensure the existing working path remains working.

If a graphical frame is available, perform one open/cancel smoke check there because `ri-pick--frame-parameters` is shared by TTY and GUI child frames.

## Acceptance Criteria

- `Pick > File` opens from a direct `emacs -nw` session in a KKP-capable terminal on Emacs 31.1+ with `tty-child-frames` available.
- The child frame and its parent always have identical `frame-terminal` values.
- `emacsclient -t -a ""` continues to work.
- Other picker entry points continue to use the same corrected frame path.
- Accept, cancel, resize, and source-context restoration behavior is unchanged.
- No fallback UI, new abstraction, dependency, or unrelated frame change is introduced.

## Documentation and Tracking

After the fix passes both startup modes:

- mark the corresponding item in `TODO.md` complete;
- update `README.md` only if verification reveals a real startup requirement beyond the existing Emacs 31.1 and Kitty Keyboard Protocol requirements.

## References

- [Emacs 31 NEWS: TTY child-frame support](https://github.com/emacs-mirror/emacs/blob/emacs-31/etc/NEWS.31)
- [Emacs frame validation and terminal-frame construction](https://github.com/emacs-mirror/emacs/blob/emacs-31/src/frame.c)
- [Emacs `display-buffer-in-child-frame`](https://github.com/emacs-mirror/emacs/blob/emacs-31/lisp/window.el)
