# Ri Tabs: Fast `e l` / `e j` Tab Switching Plan

## Goal

Make switching between marked tabs with `e l` and `e j` feel immediate again after the custom frame-wide Ri tab bar implementation.

The optimization must preserve the current behavior of:

- repository/owner-scoped marked sets;
- wrapped multi-row tabs;
- content-sized tab widths;
- active/inactive tab faces;
- modified/marked markers;
- duplicate-name disambiguation;
- mouse interaction;
- persistent marks;
- multiple frames.

The key requirement is that ordinary buffer navigation must not perform work proportional to rebuilding the entire tab surface when only the selected buffer changed.

## Current hot path

`e l` is bound to:

```elisp
ri-tabs-switch-to-right-marked-buffer
```

which calls:

```elisp
ri-tabs--switch-to-marked-buffer
  -> switch-to-buffer
```

`switch-to-buffer` then triggers `window-buffer-change-functions`, where `ri-tabs--refresh` is installed globally.

The current refresh path is:

```text
switch-to-buffer
  -> window-buffer-change-functions
  -> ri-tabs--refresh
  -> ri-tabs--surface-update for every eligible frame
  -> ri-tabs--visible-items
  -> rebuild every tab label
  -> measure every tab width
  -> repack every row
  -> erase and rewrite the complete surface buffer
  -> resize/check the surface window
```

This is excessive for `e l` / `e j`: in the common case, the marked-buffer set, labels, tab widths, row layout, and surface height are unchanged. Only the active tab changes.

There are also avoidable expensive operations inside a full rebuild:

1. `ri-tabs--visible-items` computes `ri-tabs--tab-name` once for `:label` and then `ri-tabs--tab-label` computes `ri-tabs--tab-name` again for the same buffer.
2. Duplicate-name handling can call `ri-tabs--buffer-in-owner-p`, which calls `ri-tabs--buffer-owner-context`, which can execute `git rev-parse --show-toplevel`. That means rendering can spawn Git subprocesses.
3. Graphical layout calls `string-pixel-width` for every visible tab on every refresh.
4. `ri-tabs--refresh` rebuilds every eligible frame, even when a buffer switch only affects one frame.

## Implementation plan

### 1. Add a dedicated selected-buffer update path

Separate these two concepts:

- **model/layout refresh**: marked set, label text, width, ordering, wrapping, or frame geometry changed;
- **selection refresh**: only the selected editing buffer changed.

Introduce a narrow function, conceptually:

```elisp
(ri-tabs--selection-changed frame)
```

Use it from `window-buffer-change-functions` and, where appropriate, `window-selection-change-functions` instead of routing every selection change through the global `ri-tabs--refresh` function.

The function should update only the affected frame.

### 2. Keep a rendered layout cache per frame

Store enough information on each Ri surface window or in a frame-keyed cache to identify the currently rendered model, for example:

```text
owner
ordered visible buffer identities
label strings
marker state
modified state
measured widths
packed rows
selected buffer
layout width
```

Do not use the selected buffer as part of the structural-layout cache key when selection only changes faces.

The cache must make it possible to answer:

> Has anything structural changed, or did only the active buffer change?

### 3. Fast-path selection-only changes

When the visible buffer sequence, labels, markers, modified flags, available width, and packed rows are unchanged:

- do not call `ri-tabs--visible-items` for a complete reconstruction;
- do not call `string-pixel-width` again;
- do not repack rows;
- do not erase and reinsert the surface buffer;
- do not resize the side window.

Instead, update the active/inactive styling of only:

- the previously selected tab;
- the newly selected tab.

Render each tab with stable text properties that identify its buffer and make the tab's text range discoverable. The selection fast path can then change the `face` property on those two ranges in place.

If the newly selected buffer is an unmarked temporary tab and therefore changes the visible tab set, fall back to the structural refresh path.

Likewise, if leaving an unmarked temporary tab removes it from the visible set, use the structural path.

### 4. Make refreshes frame-local by default

Split the current global refresh API into explicit scopes, conceptually:

```elisp
(ri-tabs--refresh-frame frame)
(ri-tabs--refresh-all-frames)
```

Use frame-local refresh for events originating from one frame, especially:

- selected buffer changes;
- selected window changes;
- mouse tab selection;
- frame geometry changes.

Reserve all-frame refresh for state changes that can actually affect every frame, such as a persistent marked-set mutation shared by multiple frames.

Do not iterate over `(frame-list)` on every `e l` / `e j` navigation command.

### 5. Remove duplicate tab-name computation

Refactor rendering so each tab name is computed exactly once per structural refresh.

Currently the name is computed once for `ri-tabs--item-label` and again inside `ri-tabs--tab-label`.

Change the label builder to accept the already computed name, conceptually:

```elisp
(ri-tabs--tab-label buffer tab-name selected owner state)
```

or have one function construct the complete item from a single naming pass.

This is important independently of the selection fast path because duplicate-name resolution is not cheap.

### 6. Never execute Git during presentation rendering

`ri-tabs--tab-name` must not reach a Git subprocess through:

```text
ri-tabs--tab-name
  -> ri-tabs--buffer-in-owner-p
  -> ri-tabs--buffer-owner-context
  -> ri-tabs--git-work-tree-root
  -> process-file "git"
```

Cache each live file buffer's owner context when its file identity/context is established, for example with a buffer-local value such as:

```elisp
ri-tabs--owner-context-cache
```

Refresh that cache only when something that can change the answer occurs, such as:

- visiting a file;
- `default-directory` / visited-file identity migration where Ri already synchronizes buffer identity;
- explicit owner-context synchronization when necessary.

Presentation code must consume cached model data only. A repaint must never spawn external processes.

### 7. Cache structural display measurements

For a given frame/layout width, keep the measured display width of each unchanged tab string.

Invalidate a tab's measurement only when its display text can change, for example:

- basename/disambiguated name changed;
- marked state changed;
- modified marker changed;
- relevant face/font metrics changed if Ri explicitly supports such runtime changes.

Invalidate row packing when:

- visible tab order/set changes;
- any measured tab width changes;
- available surface width changes.

A selection-only face change should not invalidate widths unless active/inactive faces actually have different metrics. Prefer defining the faces so selection changes color/weight without changing geometry; if bold changes pixel width on the active face, either remove that metric difference or base layout measurement on a stable geometry face so selecting a tab cannot cause relayout.

### 8. Avoid redundant explicit refreshes after switching

Audit switching functions and hooks so one buffer change produces one Ri update.

In particular, mouse navigation currently calls a buffer-switch helper and then explicitly calls `ri-tabs--refresh`, while buffer/window hooks can already request an update.

After introducing the selection-specific path:

- navigation commands should switch buffers;
- the buffer/window change hook should perform the single required selection update;
- explicit refreshes should remain only where the command changes Ri state outside what the hooks can observe.

Do not solve this with timers or delayed redraws. The goal is to remove unnecessary work, not hide it asynchronously.

### 9. Preserve full-refresh correctness with precise invalidation

Structural refresh must still happen when any visible property can genuinely change, including:

- mark/unmark;
- current unmarked buffer entering/leaving the visible set;
- file opened/killed;
- file renamed or visited-file identity changed;
- modified/unmodified marker transition;
- persistent-state activation/restoration;
- owner context changed;
- frame width changed;
- duplicate-name set changed.

Keep the current correctness first, but make invalidation explicit rather than using `ri-tabs--refresh` as a universal reaction to every event.

## Tests

Extend `ri-tabs/ri-tabs-test.el` with behavior and performance-structure tests.

### Selection fast path

Verify that switching between two already visible marked buffers:

1. changes the current buffer;
2. changes the active face from the old tab to the new tab;
3. does not rebuild the surface buffer text;
4. does not call row packing;
5. does not call width measurement;
6. does not resize the surface window;
7. updates only the affected frame.

Use function instrumentation/advice or `cl-letf` counters around the expensive helpers rather than timing-based assertions.

### Structural fallback

Verify that switching from a marked buffer to an unmarked buffer correctly performs a structural refresh when that buffer must be appended as the temporary current tab.

Verify the reverse transition removes the temporary tab correctly.

### No Git during redraw

Instrument `process-file` or `ri-tabs--git-work-tree-root` and assert that:

- initial owner discovery may call Git;
- repeated surface refresh/render operations do not call Git;
- repeated `e l` / `e j` switching between already known marked buffers does not call Git.

### No duplicate name work

Instrument `ri-tabs--tab-name` and verify one structural render computes each visible tab name no more than once.

### Multi-frame behavior

With two frames, switch buffers in one frame and verify that the other frame's surface is not rebuilt unless shared structural state actually changed.

### Existing regression suite

All existing `ri-tabs` tests must continue to pass, especially tests covering:

- owner-scoped marks;
- persistent restoration;
- duplicate basenames;
- dynamic tab widths;
- multi-row wrapping;
- mouse selection;
- modified markers;
- frame-wide surfaces.

## Profiling/acceptance check

Before and after the change, profile repeated marked-tab navigation such as:

```text
(e l) x 50
(e j) x 50
```

with several marked tabs and enough tabs to wrap onto multiple rows.

Use Emacs' profiler or temporary counters around these functions:

```text
ri-tabs--refresh
ri-tabs--surface-update
ri-tabs--visible-items
ri-tabs--tab-name
ri-tabs--buffer-owner-context
ri-tabs--git-work-tree-root
ri-tabs--display-width
ri-tabs--pack-items-into-rows
ri-tabs--render-rows
ri-tabs--set-surface-height
```

For steady-state switching between already visible marked tabs, acceptance means:

- zero Git subprocesses;
- zero full-surface rebuilds;
- zero width measurements;
- zero row repacks;
- zero surface resizes;
- only the current frame is touched;
- only the old/new tab selection presentation changes;
- `e l` / `e j` feels effectively instantaneous even with a wrapped tab bar.

## Recommended implementation order

1. Add counters/tests proving the current `e l` path triggers a complete surface rebuild.
2. Cache buffer owner context so rendering cannot execute Git.
3. Remove the duplicate `ri-tabs--tab-name` computation.
4. Split frame-local structural refresh from all-frame refresh.
5. Add the per-frame rendered-layout cache.
6. Implement the selection-only face update path.
7. Change buffer/window hooks to choose selection update vs structural refresh.
8. Remove redundant explicit refreshes from navigation paths.
9. Add structural fallback and multi-frame tests.
10. Run the full ERT suite and profile repeated `e l` / `e j` navigation.

## Design constraint

Do not replace the performance problem with debounce timers, idle timers, or delayed tab rendering. Switching tabs is synchronous editor navigation and should remain synchronous. The correct fix is to make the common selection-change path O(1) with respect to tab layout work, while retaining the existing full rebuild only for genuine model/layout changes.
