# Move History Momentary Layer Plan

## Goal

Add Ki's `≡ Move Hist` layer to Ri without introducing a second navigation UI or a dependency. In NORM, hold `q` and use the same four positions as Ki:

| Held chord | Legend label | Behavior |
| --- | --- | --- |
| `q` + `j` | `<< Move Hist` | Coarse back through visited file locations |
| `q` + `l` | `Move Hist >>` | Coarse forward through visited file locations |
| `q` + `u` | `< Move Hist` | Fine back through selection/cursor locations in the current buffer |
| `q` + `o` | `Move Hist >` | Fine forward through selection/cursor locations in the current buffer |

A tap of `q` has no action. Releasing `q` only closes the legend; it does not change the semantic submode, point, or Extend state.

## Ki reference contract

Reference Ki revision: [`9059eff5a497fccddfd617ae0f392ddc95e79f3a`](https://github.com/ki-editor/ki-editor/commit/9059eff5a497fccddfd617ae0f392ddc95e79f3a).

- The official [Move History documentation](https://ki-editor.org/docs/momentary-layers/movement-history-mol/) describes historical cursor and file-position navigation.
- [`movement_history_keymap`](https://github.com/ki-editor/ki-editor/blob/9059eff5a497fccddfd617ae0f392ddc95e79f3a/src/keymap.rs#L1868-L1892) binds `j`/`l` to coarse back/forward and `u`/`o` to fine back/forward. NORM opens the layer on `q` with no tap action.
- Ki's [`History`](https://github.com/ki-editor/ki-editor/blob/9059eff5a497fccddfd617ae0f392ddc95e79f3a/src/history.rs) uses back and forward stacks, suppresses consecutive duplicates, and clears forward history after a new ordinary location is recorded.
- Fine history is buffer-local and restores historical selection sets. Coarse history stores file locations and skips paths that no longer exist.

Ri should match those observable semantics, adapted to Emacs buffers, windows, markers, semantic submodes, and Extend invariants.

## Current Ri constraints

- `ri--layer-specs` in `ri.el` is the single source of truth for held keys, labels, maps, tap actions, and release behavior. `q` is currently free in the NORM map.
- All momentary layers are currently NORM-only. Do not add Ki's Insert-mode `M-q` variant in this change.
- Ri has no general cursor/file movement history. `ri--selection-state-undo-stack` is only the one-way contraction history for the current Extend selection and must not be repurposed.
- `window-prev-buffers` is not sufficient for coarse history: it is an MRU list, may fall through to buffers that were never visited in this history branch, and collapses non-consecutive visits to the same file. A sequence such as `A@10 -> B@20 -> A@30` must retain both visits to A.
- Historical submode restoration must not call `ri--persist-selection-submode`; replaying history is navigation, not a new persistent mode choice.
- While Extend is active, every restored snapshot must preserve its exact bounds and leave point on the restored active edge.
- History is transient session state. Do not add it to desktop, save-place, or multisession persistence.

## Design

### 1. Represent one complete Ri location

In `ri-extend.el`, add one internal location structure containing only state needed for exact replay:

- the buffer and its visited file name, when any;
- point as a marker plus its integer position as a fallback if the buffer is later killed and the file reopened;
- the effective semantic submode;
- whether Extend was active;
- exact Extend bounds and active edge when Extend was active.

Use markers for live buffers so edits move historical positions with their text. Keep integer fallbacks only for reopening a killed file buffer. Clamp fallback positions and bounds to the reopened buffer's accessible range.

When a held `a`, `s`, or `w` navigation layer is active, snapshot `ri--momentary-origin-submode`, not the temporary LINE, WORD+, or CHAR submode. The location visible after layer release is the historical state users must revisit.

A restored Extend snapshot should be rebuilt as a canonical `ri--selection-state`:

- set the anchor to the inactive bound;
- set point to the first selected character for a `start` edge or the last selected character for an `end` edge;
- set the preserved boundary to the exact active bound;
- leave `initial-end` nil and start a fresh Extend undo stack.

This preserves the exact historical selection while preventing the old Extend contraction stack from being mixed with Move History's back/forward branch.

### 2. Keep fine and coarse histories separate

Use the same location representation with two independent stack pairs:

- **Fine history:** buffer-local back and forward lists. It records completed Ri selection/cursor states only while that buffer is in NORM.
- **Coarse history:** back and forward lists stored as selected-window parameters. It records chronological file visits for each ordinary editing window, including repeated visits to the same file at different positions.

Per-window coarse state avoids one split or frame consuming another window's navigation branch. Fine state remains with its buffer regardless of which window displays it.

Provide small shared stack operations with these rules:

1. Ignore a state equal to the current state.
2. On an ordinary new state, push the previous current state to `back` and clear `forward`.
3. Back pops a valid target from `back`, pushes current to `forward`, and restores the target.
4. Forward is symmetric.
5. Exhaustion is a no-op, not an error.
6. When clearing or discarding entries, detach their markers so dead history does not remain on Emacs marker chains.

Do not add a configurable history limit in this change. The first implementation should match Ki's unbounded chronological stacks; add a cap only if real session profiling shows marker retention is material.

### 3. Record command-boundary states, not individual helper calls

Install minimal pre/post-command integration when Ri is enabled:

- Before a command, capture the selected ordinary editing window's current Ri location.
- After a command, compare the resulting location with the captured/current state.
- In the same file buffer, record a changed state in that buffer's fine history.
- When the selected window changes from one file-visiting buffer to another, record the outgoing file location in that window's coarse history and make the destination its current coarse state.
- Ignore minibuffers, side windows, special-mode buffers, and non-file buffers for coarse history.

This boundary records every user-visible Ri location change—semantic navigation, submode switches that move point, cursor swaps, mouse retargeting, and Extend transitions—without adding history calls to every movement command. A no-op movement creates no entry.

Move History replay commands must mark their command boundary as replay. The post-command recorder then updates the current snapshot without treating the replayed location as a new branch. Any later ordinary movement or file switch clears only the corresponding forward stack.

Repeated `ri-enable` calls must not duplicate hooks. Keep the hook bodies unloaded from unrelated buffers by returning immediately unless the selected buffer has Ri's semantic-region integration and NORM is active.

### 4. Restore a fine location

Fine back/forward stays in the current buffer. Restoration must:

1. pop a valid location from the requested stack;
2. dispose the current Extend state before changing submode, so the raw setter cannot preserve bounds from the state being left;
3. restore the historical submode through the existing non-persistent raw submode path;
4. restore either normal point or the complete canonical historical Extend state;
5. refresh semantic highlighting and the mode line;
6. push the state being left onto the opposite stack;
7. mark the command as replay so post-command recording does not clear the forward branch.

If a marker is detached or the location no longer belongs to the current live buffer, discard it and continue to the next entry. Fine replay must never switch buffers.

### 5. Restore a coarse location

Coarse back/forward acts on the selected ordinary editing window. Restoration must:

1. skip entries whose file no longer exists;
2. reuse a live file-visiting buffer when available, otherwise reopen the stored path with Emacs's normal file-visiting API;
3. show the target in the selected editing window without changing other windows or the frame layout;
4. restore the saved point/submode/Extend snapshot and refresh Ri highlighting and mode-line state;
5. push the location being left onto the opposite coarse stack;
6. update the selected window's current coarse snapshot and suppress ordinary branch recording for that command.

Do not restore scroll offset; Ki's own coarse history explicitly leaves that as future work. Do not route coarse history through the Buffer layer's marked-buffer ordering: marked files and chronological visits are different contracts.

### 6. Register the `q` layer

In `ri.el`:

- add `ri--move-history-layer-map` with the four exact Ki key positions and legend labels;
- add a `?q` entry to `ri--layer-specs` with label `"≡ Move Hist"`, `:tap nil`, the new map, and `:release nil`;
- do not set `:submode`, `:activate-on-press`, or `:restore-on-release` because this layer replays locations rather than borrowing a semantic navigation unit.

Reuse `ri-chord-setup` unchanged. The existing layer-spec loop should register the KKP chord and the plain-press fallback in `mini-modal-map`. A quick tap therefore remains a deliberate no-op.

## File-by-file implementation

### `ri-extend.el`

- Add the internal location snapshot and marker cleanup helpers near the existing selection-state structures.
- Add buffer-local fine back/forward/current state.
- Add per-window coarse state accessors and command-boundary recording helpers.
- Add four interactive commands: fine back, fine forward, coarse back, and coarse forward.
- Restore submodes through `ri--restore-submode`; never persist a replayed submode.
- Reconstruct Extend through existing selection-state fields and `ri--point-at-unit-edge`, then call `ri--update-highlight` and `force-mode-line-update`.

### `ri.el`

- Add the four-key Move History map beside the other momentary maps.
- Add the `q` layer specification.
- Register the command-boundary hooks from `ri-enable` idempotently. Do not add a new top-level dependency or a second layer-registration path.

### `ri-extend-test.el`

Add focused behavior tests for:

1. fine back/forward across at least three cursor locations;
2. no-op movements and consecutive duplicate states not growing history;
3. an ordinary movement after fine back clearing fine forward only;
4. historical positions following buffer edits through markers;
5. historical submode restoration without changing the persisted last submode;
6. held LINE/WORD+/CHAR navigation recording the origin submode rather than the temporary one;
7. exact Extend bounds, active edge, and point placement after fine back and forward;
8. restored Extend state starting a fresh contraction stack;
9. coarse `A@old -> B -> A@new` back/back and forward/forward chronology;
10. coarse history being independent between two ordinary windows;
11. reopening an existing file whose original buffer was killed;
12. skipping a deleted file and exhausting history without error;
13. ordinary file navigation after coarse back clearing coarse forward only;
14. replay not recording itself as a new branch.

Test through the public interactive history commands and observable buffer, point, submode, bounds, edge, and window state. Avoid assertions against list layout except where needed to prove duplicate suppression or branch clearing.

### `ri-chord-test.el`

Extend the existing layer registration coverage to assert:

- `q` resolves to label `"≡ Move Hist"`, nil tap/release, and the new map;
- `j`, `l`, `u`, and `o` resolve to the four interactive commands and exact labels;
- press/hold/release shows and hides the legend without changing submode or selection;
- a quick `q` tap is a no-op;
- each held sub-key invokes the expected history direction once.

### `README.md`

- Add `q` to the main key table and momentary-layer list.
- Document `j`/`l` as file-location history and `u`/`o` as current-buffer selection/cursor history.
- State that a new ordinary movement after going back discards that history's forward branch.
- State that Move History is transient and NORM-only.

## Startup-sensitive workflow

The implementation changes `ri-enable`. Run the repository-owned `before` and `after` procedure from `.agents/skills/ri-startup-performance/SKILL.md` at the points prescribed there. That skill remains the sole source of truth for the benchmark command, comparison workflow, and regression policy.

The hooks must perform no history allocation during `ri-enable` beyond their registration. Initial location state should be created lazily on the first eligible command boundary.

## Verification

Run the complete affected suites with the external `kkp.el` directory available:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs --batch -Q \
  -L "$KKP_DIR" -L . -L semantic-regions -L mini-modal \
  -L modal-cursor -L keymap-legend -L status-frame -L kkp-chord \
  -L ri-tabs -L ri-pick -L ri-pairs -L ri-surround -L ri-mouse \
  -l ri-extend-test.el -l ri-chord-test.el \
  -f ert-run-tests-batch-and-exit
```

Byte-compile the changed Lisp files with warnings treated as errors using the same load path.

Then smoke-test the real TTY path in `emacs -Q -nw` with KKP enabled:

1. Open file A, move to one location, open file B, then revisit A at a different location.
2. Hold `q`; verify the legend labels and use `j` twice, then `l` twice, checking the exact file and point each time.
3. Make several semantic movements in one buffer; use `q+u` and `q+o`, checking point, highlight, and submode.
4. Repeat fine back/forward while Extend is active; verify exact bounds and that point remains on the active edge.
5. Go back, make a new ordinary movement, and verify forward is exhausted.
6. Tap `q`; verify no movement or state change.

Finally run the prescribed `after` startup benchmark and report the before/after increments.

## Acceptance criteria

- Holding `q` exposes the exact Ki `j`/`l`/`u`/`o` Move History layout; tapping `q` does nothing.
- Fine history is chronological, buffer-local, edit-resilient, bidirectional, duplicate-free, and branch-correct.
- Coarse history is chronological, per editing window, bidirectional, preserves repeated visits to one file, restores file positions, reopens existing killed files, and skips missing files.
- History replay restores the historical semantic submode without changing Ri's persisted last submode.
- Historical Extend snapshots restore exact bounds; point is on the first selected character for the `start` edge and the last selected character for the `end` edge.
- Replay does not add itself to history. Exhausted history is a no-op.
- Other momentary layers, Buffer-layer ordering, Xref history, undo/redo, window layout, and session persistence are unchanged.
- Focused ERT suites, byte compilation, real TTY smoke behavior, and the startup regression check pass.

## Explicit non-goals

- No Insert-mode `M-q` layer.
- No history picker, preview, counter, persistence, or user-configurable limit.
- No reuse or mutation of Xref, mark-ring, undo, Buffer-layer, or Extend contraction histories.
- No scroll-offset restoration.
- No new package or source file.
