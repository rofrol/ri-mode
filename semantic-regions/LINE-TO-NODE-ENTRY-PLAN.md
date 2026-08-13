# LINE → NODE Entry Plan

## Problem

When RI is in `LINE` mode on an Emacs Lisp line such as:

```elisp
(setq mouse-wheel-tilt-scroll t)
```

switching directly from `LINE` to `NODE` currently selects `mouse-wheel-tilt-scroll` instead of the first syntactic item, `setq`.

This happens because NODE entry is currently derived from the current point position. The LINE selection itself is not used to determine the initial NODE target. In Emacs Lisp, `setq` is an anonymous tree-sitter token, while `mouse-wheel-tilt-scroll` is a named symbol node, so logic that effectively starts from the point or prefers a named child can skip the form head.

## Desired behavior

For a direct `LINE` → `NODE` transition, NODE should enter the selected line from its beginning and choose the first horizontally traversable syntax node contained in that line.

For:

```elisp
(setq mouse-wheel-tilt-scroll t)
```

expected behavior is:

1. `LINE` selects the whole trimmed line.
2. Switching to `NODE` selects `setq`.
3. NODE Right selects `mouse-wheel-tilt-scroll`.
4. NODE Right again selects `t`.
5. NODE Left from `mouse-wheel-tilt-scroll` returns to `setq`.

Anonymous punctuation such as `(` must not become the initial NODE target. Anonymous word-like grammar tokens such as `setq` must remain valid targets, consistently with the existing NODE horizontal-navigation rules.

## Scope

Implement this as transition-specific behavior for entering NODE from `LINE` (and, unless tests reveal an incompatible semantic distinction, `LINE*`). Do not globally change ordinary NODE entry from CHAR, WORD, SUBWORD, mouse targeting, or an already active NODE selection.

Do not regress the existing Ki-style `sr--node-top-at` behavior used by normal NODE parsing/navigation.

## Implementation plan

### 1. Preserve the source submode during NODE entry

Update the NODE-mode setter path so it can determine whether NODE is being entered from `line` or `line-star` before `sr-submode` is changed.

The transition must capture the current LINE semantic region before clearing NODE state or changing the active submode.

### 2. Add a dedicated LINE → NODE resolver

Add a small internal helper in `semantic-regions.el`, for example conceptually:

```text
sr--node-first-target-in-region
```

The helper should:

- accept the current LINE region bounds;
- inspect tree-sitter syntax within those bounds;
- find the first NODE target in textual order that is actually traversable by NODE horizontal navigation;
- reuse the same eligibility rule as `sr--node-horizontal-target-p` so named nodes and anonymous word-like tokens are treated consistently;
- skip punctuation-only anonymous nodes such as `(`;
- never select a node that starts outside the LINE region;
- return a real tree-sitter node suitable for storing in `sr--node-current`.

Avoid introducing a second, subtly different definition of a valid NODE target. Factor/reuse existing NODE traversal predicates where possible.

### 3. Seed NODE state explicitly on the transition

When entering NODE from LINE/LINE* and a valid first target is found:

- set `sr--node-current` to that target;
- clear `sr--node-virtual-bounds` / `sr--node-virtual-parent`;
- ensure `sr--node-direct-target-p` is in the correct state for keyboard navigation;
- move point to the selectable edge/start of the target if required by the existing NODE cache rules;
- then switch `sr-submode` to `node` and refresh the highlight.

The first highlight after the mode switch must therefore be `setq`, not a target recomputed from the old point position.

### 4. Keep generic NODE entry unchanged

If NODE is entered from any mode other than LINE/LINE*, retain the current `sr--node-top-at`-based behavior.

Likewise, do not alter `sr--node-lowest-at`, because that helper is intentionally used for direct spatial/mouse targeting and has different semantics.

### 5. Add regression tests

Add ERT coverage in `semantic-regions/semantic-regions-test.el` for at least these cases:

#### Primary Elisp regression

Buffer:

```elisp
(setq mouse-wheel-tilt-scroll t)
```

Start in `LINE`, with point placed somewhere inside the line, including specifically on `mouse-wheel-tilt-scroll`. Switch to NODE and assert that the selected region is:

```text
setq
```

This is important: the result must be independent of where point happened to be inside the selected LINE.

#### Navigation after entry

After the LINE → NODE transition:

- Right => `mouse-wheel-tilt-scroll`
- Right => `t`
- Left => `mouse-wheel-tilt-scroll`
- Left => `setq`

This proves that the seeded initial node participates in the existing sibling-navigation model rather than being a one-off synthetic selection.

#### LINE start punctuation

Verify that the opening `(` is skipped and never becomes the initial target.

#### Indented form

Test an indented line such as:

```elisp
    (setq mouse-wheel-tilt-scroll t)
```

The initial NODE must still be `setq`.

#### LINE* parity

If LINE* is intended to share this behavior, add the same regression for `LINE*` and document that parity in the test name.

#### Non-regression

Keep the existing tests proving that:

- ordinary NODE entry can still select the Ki-style top node;
- NODE Down/Up behavior is unchanged;
- anonymous Elisp heads remain reachable;
- mouse/direct NODE targeting still chooses the lowest spatial node;
- string virtual-node behavior remains unchanged.

### 6. Add an integration-level RI test if needed

If `ri-extend-set-node-mode` or the RI wrapper changes point/submode state around `sr-set-node-mode`, add a focused test in `ri-extend-test.el` that performs the real RI transition rather than testing only `semantic-regions.el` in isolation.

The integration assertion should reproduce the user-visible sequence exactly:

```text
LINE on `(setq mouse-wheel-tilt-scroll t)`
→ NODE
→ `setq` selected
```

Prefer fixing ownership in `semantic-regions` and keeping RI wrappers thin unless the bug is demonstrably introduced by the wrapper.

## Acceptance criteria

The change is complete when all of the following are true:

- On `(setq mouse-wheel-tilt-scroll t)`, switching from LINE to NODE selects `setq`.
- The result does not depend on the current point being over `setq`, `mouse-wheel-tilt-scroll`, or `t` while LINE is active.
- Punctuation such as `(` is skipped.
- Anonymous word-like syntax tokens remain selectable.
- Existing NODE keyboard navigation behaves exactly as before after the initial transition.
- Mouse NODE targeting remains unchanged.
- Existing NODE string handling remains unchanged.
- The full ERT suite passes.

## Design principle

A semantic-mode transition should be derived from the semantic unit being transitioned from, not from an incidental cursor position inside that unit. Therefore LINE → NODE should enter the syntax tree at the first valid NODE target within the selected LINE.

## Implementation status

Implemented on 2026-08-13.

- Added a transition-specific first-target resolver for LINE/LINE* → NODE.
- NODE entry now seeds `sr--node-current` from the selected line and moves point to that target before highlighting.
- Reused `sr--node-horizontal-target-p`, so punctuation is skipped while anonymous word-like heads such as `setq` remain selectable.
- Kept ordinary NODE entry and mouse/direct `sr--node-lowest-at` behavior unchanged.
- Added Elisp regression coverage for point independence, indentation, LINE* parity, punctuation skipping, and subsequent Left/Right navigation.
