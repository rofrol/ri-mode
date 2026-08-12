;;; kkp-chord.el --- Tap-hold chord system via Kitty Keyboard Protocol -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Roman Frołow
;;
;; Author: Roman Frołow
;; Maintainer: Roman Frołow
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (kkp "0.1"))
;; Keywords: convenience, terminals
;; URL: https://github.com/rofrol/kkp-chord
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.
;;
;;; Commentary:

;;
;; kkp-chord.el builds on kkp.el to provide tap-hold chord key
;; behavior (a.k.a. "home row mods").
;;
;; kkp.el's `report-alternate-keys' enhancement sends flag bit 2
;; (alternate keys) but NOT bit 1 (event types: press/repeat/release).
;; This file adds the missing `report-event-types' flag (bit 1) so the
;; terminal sends `:event-type' suffixes on every key event.
;;
;; With event types available, kkp-chord:
;;   - Swallows release events (kkp otherwise translates them as
;;     spurious keypresses).
;;   - Tracks held chord-modifier keys.
;;   - Remaps other keys through the modifier's keymap while held.
;;   - Triggers a tap action when released without intervening keys.
;;
;; Usage:
;;
;;   (require 'kkp-chord)
;;
;;   (kkp-chord-define ?c
;;     :tap #'ri-copy-unit
;;     :when (lambda () (bound-and-true-p ri-mode))
;;     :map (let ((m (make-sparse-keymap)))
;;            (define-key m "k" #'ri-dup-below)
;;            m))
;;
;;   (kkp-chord-mode 1)

;;; Code:

(require 'cl-lib)
(require 'kkp)
(require 'subr-x)

(defvar kkp-chord-after-release-hook nil
  "Hook run after a Kitty key-release event has been swallowed.
Functions are called with no arguments.  This is useful for UI that must
be refreshed after a release event, since the release itself can clear
the echo area even though it does not become an Emacs command.")

;; ---------------------------------------------------------------------------
;; Fix: add event-type reporting (bit 1, value 2) to KKP flags.
;;
;; Kitty Keyboard Protocol progressive enhancement flags:
;;   bit 0 (1): disambiguate escape codes
;;   bit 1 (2): report event types (1=press, 2=repeat, 3=release)
;;   bit 2 (4): report alternate keys
;;   bit 3 (8): report ALL keys as escape codes
;;
;; kkp.el sets bits 0 + 2 = 5.  We add bits 1 + 3 → 15.
;; Without bit 1, press/release events are indistinguishable.
;; Without bit 3, regular keys ('c', 'k') are plain bytes — they
;;   bypass kkp's CSI handler and our advice never sees them.
;; ---------------------------------------------------------------------------
(unless (assoc 'report-event-types kkp--progressive-enhancement-flags)
  (push '(report-event-types . (:bit 2)) kkp--progressive-enhancement-flags))
(add-to-list 'kkp-active-enhancements 'report-event-types)

(unless (assoc 'report-all-keys-as-escape-codes kkp--progressive-enhancement-flags)
  (push '(report-all-keys-as-escape-codes . (:bit 8)) kkp--progressive-enhancement-flags))
(add-to-list 'kkp-active-enhancements 'report-all-keys-as-escape-codes)

(defconst kkp-chord--required-enhancement-mask
  (logior 2 8)
  "KKP flag bits required for event types and escaped ordinary keys.")

(defun kkp-chord--update-active-terminal (terminal)
  "Re-negotiate KKP flags in TERMINAL to include chord-required bits.
Safe to call when KKP is not yet active in TERMINAL."
  (when (and (terminal-live-p terminal)
             (kkp--active-p terminal))
    (let ((new-flags (kkp--calculate-flags-integer))
          (current-flags (kkp--state-enhancements
                          (kkp--terminal-state terminal))))
      (when (and current-flags
                 (= (logand new-flags
                            kkp-chord--required-enhancement-mask)
                    kkp-chord--required-enhancement-mask)
                 (/= (logand new-flags
                             kkp-chord--required-enhancement-mask)
                     (logand current-flags
                             kkp-chord--required-enhancement-mask)))
        (kkp--set-encoding-flags terminal new-flags)
        (when-let* ((actual (kkp--reply-flags
                             (kkp--query-terminal-sync "?u" ?u))))
          (setf (kkp--state-enhancements (kkp--ensure-state terminal))
                actual))))))
(defun kkp-chord--update-all-terminals ()
  "Ensure every active KKP terminal has event-type reporting enabled."
  (dolist (terminal (terminal-list))
    (kkp-chord--update-active-terminal terminal)))

;; ---------------------------------------------------------------------------
;; Internal state
;; ---------------------------------------------------------------------------

(defgroup kkp-chord nil
  "Tap-hold chords using KKP key press/release events."
  :group 'kkp
  :prefix "kkp-chord-")

(defvar kkp-chord--held nil
  "Alist of (KEYCODE . INTERVENING-P) for currently held chord modifiers.
KEYCODE is an integer (e.g., 99 for ?c).
INTERVENING-P is non-nil if at least one other key was pressed while
this modifier was held.  Used to decide tap vs. hold on release.")

(defvar kkp-chord--transient-exit nil
  "Exit function for the keymap activated by a plain modifier press.")

(defvar kkp-chord--transient-keycode nil
  "Keycode whose plain press activated `kkp-chord--transient-exit'.")

(defvar kkp-chord--mod-maps (make-hash-table :test 'eql)
  "Hash: keycode → keymap.  Consulted while this key is held.
Entries are sparse keymaps whose bindings use single-character
strings as keys; values are command functions.")

(defvar kkp-chord--tap-actions (make-hash-table :test 'eql)
  "Hash: keycode → function.  Called (no args) when the key is tapped.")

(defvar kkp-chord--predicates (make-hash-table :test 'eql)
  "Hash: keycode → predicate function.
Before remapping or tapping a chord modifier, the predicate (called
with no arguments) must return non-nil.  When nil, the key event
passes through to normal KKP translation.")

(defvar kkp-chord--press-actions (make-hash-table :test 'eql)
  "Hash: keycode → function called when a chord modifier is pressed.")

(defvar kkp-chord--release-actions (make-hash-table :test 'eql)
  "Hash: keycode → function called when a chord modifier is released.")

(defvar kkp-chord--advice-active nil
  "Non-nil when the advice on `kkp--translate-terminal-input' is in place.")

(defconst kkp-chord--event-press 1
  "KKP event type for a key press.")

(defconst kkp-chord--event-release 3
  "KKP event type for a key release.")

(defconst kkp-chord--event-repeat 2
  "KKP event type for a repeated key.")

;; ---------------------------------------------------------------------------
;; Parse KKP terminal input
;; ---------------------------------------------------------------------------

(defun kkp-chord--parse (terminal-input)
  "Parse TERMINAL-INPUT (list of char codes) into a plist.
Returns (:keycode N :event-type N :modifier-num N).

TERMINAL-INPUT format (with event-types enabled):
  CSI keycode[:shifted-key];modifier[:event-type];text u

Example: (57 57 59 58 49 117) = \"99;:1u\" → keycode=99,
event-type=1, modifier-num=0."
  (let* ((str (apply #'string terminal-input))
         ;; Strip the last character (terminator: u, ~, or letter)
         (body (substring str 0 -1))
         (parts (split-string body ";"))
         ;; First part: keycode[:shifted-key[:base-layout-key]]
         (keycode-part (nth 0 parts))
         (keycode-str (car (split-string keycode-part ":")))
         (keycode (string-to-number keycode-str))
         ;; Second part: modifier[:event-type]
         (mod-part (nth 1 parts))
         (modifier-num 0)
         event-type)
    (when mod-part
      (let* ((mod-subparts (split-string mod-part ":"))
             (modifier-str (car mod-subparts)))
        (when (and modifier-str
                   (not (string-empty-p modifier-str)))
          ;; KKP encodes the actual modifier bits as one plus the value.
          (setq modifier-num (1- (string-to-number modifier-str))))
        (when (and (cadr mod-subparts)
                   (not (string-empty-p (cadr mod-subparts))))
          (setq event-type (string-to-number (cadr mod-subparts))))))
    (list :keycode keycode
          :event-type (or event-type 1)
          :modifier-num modifier-num)))

;; ---------------------------------------------------------------------------
;; Chord modifier lookup
;; ---------------------------------------------------------------------------

(defun kkp-chord--active-p (keycode)
  "Return non-nil if KEYCODE's chord modifier predicate passes."
  (let ((pred (gethash keycode kkp-chord--predicates)))
    (or (null pred) (funcall pred))))

(defun kkp-chord--mark-held-intervening (&optional except-keycode)
  "Mark every held modifier except EXCEPT-KEYCODE as having an intervening key."
  (dolist (entry kkp-chord--held)
    (unless (eql (car entry) except-keycode)
      (setcdr entry t))))

(defun kkp-chord--lookup (keycode)
  "Look up KEYCODE in all active chord modifier keymaps.
Return the command if found, or nil.  Mark every held modifier as
having had an intervening key press, including modifiers searched
after the one whose map contains the command."
  (kkp-chord--mark-held-intervening)
  (catch 'found
    (dolist (entry kkp-chord--held)
      (let ((mod-keycode (car entry))
            (mod-map (gethash (car entry) kkp-chord--mod-maps)))
        (when (and mod-map (kkp-chord--active-p mod-keycode))
          (when-let* ((command (lookup-key mod-map (string keycode))))
            (when (commandp command)
              (throw 'found command))))))
    nil))

;; KKP's `report-all-keys-as-escape-codes' enhancement reports physical
;; modifier keys too.  Their modifier bits are already carried by the
;; following key event, so forwarding these events would produce commands
;; such as `M-<Alt_L>' instead of leaving the modifier key inert.
(defconst kkp-chord--modifier-keycodes
  '(57441 57442 57443 57444 57445 57446
    57447 57448 57449 57450 57451 57452 57453 57454)
  "KKP keycodes for physical modifier keys.")

(defun kkp-chord--modifier-key-p (keycode)
  "Return non-nil when KEYCODE is a physical modifier key."
  (memq keycode kkp-chord--modifier-keycodes))


;; ---------------------------------------------------------------------------
;; Event handlers
;; ---------------------------------------------------------------------------

(defun kkp-chord--deactivate-transient-map (&optional keycode)
  "Deactivate the plain-press map, optionally only for KEYCODE."
  (when (and kkp-chord--transient-exit
             (or (null keycode)
                 (eql keycode kkp-chord--transient-keycode)))
    (let ((exit kkp-chord--transient-exit))
      (setq kkp-chord--transient-exit nil
            kkp-chord--transient-keycode nil)
      (funcall exit))))

(defun kkp-chord--activate-transient-map (keycode)
  "Activate KEYCODE's chord map for ordinary single-byte key presses."
  (when-let* ((map (gethash keycode kkp-chord--mod-maps)))
    (kkp-chord--deactivate-transient-map)
    (setq kkp-chord--transient-keycode keycode
          kkp-chord--transient-exit
          (set-transient-map
           map
           (lambda () (assq keycode kkp-chord--held))))))

(defun kkp-chord--mark-plain-command ()
  "Mark held modifiers before a command read outside KKP translation."
  (when kkp-chord--held
    (kkp-chord--mark-held-intervening)))

(defun kkp-chord--on-mod-press (keycode)
  "Handle press of a chord-modifier KEYCODE.
Mark other held modifiers as used, then hold KEYCODE with no
intervening key yet."
  (kkp-chord--mark-held-intervening keycode)
  (setq kkp-chord--held (assq-delete-all keycode kkp-chord--held))
  (push (cons keycode nil) kkp-chord--held)
  (when-let* ((action (gethash keycode kkp-chord--press-actions)))
    (funcall action))
  ;; With only KKP event-type reporting enabled, an unmodified printable
  ;; press remains a normal Emacs event while its release is CSI-u.  Keep
  ;; the layer map active for those ordinary sub-key presses as well.
  (kkp-chord--activate-transient-map keycode))


(defun kkp-chord--on-release (keycode)
  "Handle release of KEYCODE.
If it was a chord modifier with no intervening keys, fires the tap
action.  Otherwise just unmarks it as held."
  (let ((entry (assq keycode kkp-chord--held)))
    (when entry
      (setq kkp-chord--held (delq entry kkp-chord--held))
      (kkp-chord--deactivate-transient-map keycode)
      (when-let* ((action (gethash keycode kkp-chord--release-actions)))
        (funcall action))
      ;; Reaching this state proves the press predicate passed: inactive
      ;; presses are never added to `kkp-chord--held'.  Do not re-check it
      ;; while decoding release; `this-command-keys-vector' can still contain
      ;; the ordinary byte used for the corresponding press.
      (unless (cdr entry)
        (when-let* ((tap-command
                     (gethash keycode kkp-chord--tap-actions)))
          (kkp-chord--dispatch-command tap-command))))))

(defun kkp-chord--dispatch-command (command)
  "Execute COMMAND as a standalone command from KKP input.
KKP dispatch happens while Emacs is reading the next command, so the
ordinary command loop does not update `this-command' or `last-command'."
  (let ((this-command command))
    (call-interactively command)
    (setq last-command this-command)))



;; ---------------------------------------------------------------------------
;; Advice on kkp--translate-terminal-input
;; ---------------------------------------------------------------------------

(defun kkp-chord--translate-advice (orig-fun terminal-input)
  "Advice adding chord support to `kkp--translate-terminal-input'."
  (let* ((parsed (kkp-chord--parse terminal-input))
         (keycode (plist-get parsed :keycode))
         (event-type (plist-get parsed :event-type))
         (modifier-num (plist-get parsed :modifier-num)))
    (cond
     ;; Release event → swallow.  Run the hook after chord release actions
     ;; so clients can restore transient UI (for example an echo-area
     ;; message) that the raw key-up event would otherwise erase.
     ((= event-type kkp-chord--event-release)
      (kkp-chord--on-release keycode)
      (run-hooks 'kkp-chord-after-release-hook)
      [])

     ;; `report-all-keys-as-escape-codes' reports physical modifier events.
     ;; KKP encodes their state on the next key event, so never dispatch
     ;; their remaining press/repeat events as standalone Emacs events.
     ((kkp-chord--modifier-key-p keycode)
      (when (= event-type kkp-chord--event-press)
        (kkp-chord--mark-held-intervening))
      [])

     ;; Repeat of a held chord modifier → swallow.
     ((and (= event-type kkp-chord--event-repeat)
           (= modifier-num 0)
           (assq keycode kkp-chord--held))
      [])

     ;; Chord-modifier press → mark held, swallow
     ((and (= event-type kkp-chord--event-press)
           (= modifier-num 0)
           (gethash keycode kkp-chord--mod-maps)
           (kkp-chord--active-p keycode))
      (kkp-chord--on-mod-press keycode)
      [])

     ;; Press/repeat while a chord modifier is held → remap or pass through
     ((and (or (= event-type kkp-chord--event-press)
               (= event-type kkp-chord--event-repeat))
           kkp-chord--held)
      (if (/= modifier-num 0)
          (progn
            (kkp-chord--mark-held-intervening)
            (funcall orig-fun terminal-input))
        (if-let* ((cmd (kkp-chord--lookup keycode)))
            (progn
              (kkp-chord--dispatch-command cmd)
              [])
          (funcall orig-fun terminal-input))))

     ;; Normal event → kkp translates
     (t (funcall orig-fun terminal-input)))))

(defun kkp-chord--install-advice ()
  "Install chord advice on `kkp--translate-terminal-input'."
  (unless kkp-chord--advice-active
    (advice-add 'kkp--translate-terminal-input :around
                #'kkp-chord--translate-advice)
    (setq kkp-chord--advice-active t)))

(defun kkp-chord--remove-advice ()
  "Remove chord advice from `kkp--translate-terminal-input'."
  (when kkp-chord--advice-active
    (advice-remove 'kkp--translate-terminal-input
                   #'kkp-chord--translate-advice)
    (setq kkp-chord--advice-active nil)
    (setq kkp-chord--held nil)))

;; ---------------------------------------------------------------------------
;; Public API
;; ---------------------------------------------------------------------------

(defun kkp-chord-press (keycode)
  "Begin registered chord layer KEYCODE from an ordinary key binding.
This is the fallback path for terminals that report release events but
leave unmodified printable press events as single bytes."
  (unless (gethash keycode kkp-chord--mod-maps)
    (user-error "No chord layer registered for %s" (single-key-description keycode)))
  (kkp-chord--on-mod-press keycode))

;;;###autoload
(cl-defun kkp-chord-define (keycode &key tap map when on-press on-release)
  "Register KEYCODE as a tap-hold chord modifier key.

KEYCODE is an integer (e.g., ?c or 99).

:TAP is a function called (no arguments) when KEYCODE is tapped
(pressed and released without any intervening key press).

:MAP is a sparse keymap active while KEYCODE is held.  Bindings use
single-character strings as keys; the values are command functions.

:WHEN is a predicate (no arguments).  The chord modifier is only
active when the predicate returns non-nil.  Use this to restrict
chords to specific modes:
  (lambda () (bound-and-true-p ri-mode))

:ON-PRESS and :ON-RELEASE are optional functions called when an active
modifier is pressed or released.  They are useful for transient UI
such as a momentary-layer legend."
  (when map   (puthash keycode map kkp-chord--mod-maps))
  (when tap   (puthash keycode tap kkp-chord--tap-actions))
  (when when  (puthash keycode when kkp-chord--predicates))
  (if on-press
      (puthash keycode on-press kkp-chord--press-actions)
    (remhash keycode kkp-chord--press-actions))
  (if on-release
      (puthash keycode on-release kkp-chord--release-actions)
    (remhash keycode kkp-chord--release-actions)))


;;;###autoload
(defun kkp-chord-undefine (keycode)
  "Remove KEYCODE from chord modifier registration."
  (remhash keycode kkp-chord--mod-maps)
  (remhash keycode kkp-chord--tap-actions)
  (remhash keycode kkp-chord--predicates)
  (remhash keycode kkp-chord--press-actions)
  (remhash keycode kkp-chord--release-actions))

;;;###autoload
(define-minor-mode kkp-chord-mode
  "Toggle kkp-chord tap-hold key support.
When active, advises `kkp--translate-terminal-input' to intercept KKP
key press/release events and implement chord modifier behavior.
Also ensures event-type reporting is enabled in all active terminals."
  :global t
  :group 'kkp-chord
  (if kkp-chord-mode
      (progn
        (kkp-chord--install-advice)
        (add-hook 'pre-command-hook #'kkp-chord--mark-plain-command)
        (add-hook 'kkp-terminal-setup-complete-hook
                  #'kkp-chord--update-all-terminals)
        ;; Update any already-active terminals to include event-type flag.
        ;; For terminals that haven't been set up yet, the flag was already
        ;; added to `kkp-active-enhancements' at load time.
        (kkp-chord--update-all-terminals))
    (remove-hook 'pre-command-hook #'kkp-chord--mark-plain-command)
    (remove-hook 'kkp-terminal-setup-complete-hook
                 #'kkp-chord--update-all-terminals)
    (kkp-chord--deactivate-transient-map)
    (kkp-chord--remove-advice)))

(provide 'kkp-chord)
;;; kkp-chord.el ends here
