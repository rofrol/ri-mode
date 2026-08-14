---

name: emacs-refactor
description: >
Incrementally refactor Emacs Lisp using canonical Emacs vectors,
representations, and APIs, Chesterton's Fence, high-value regression tests,
and strict verification after each small change. Designed to be used
together with Ponytail, which supplies general minimalism, YAGNI,
reuse-before-implementation, and complexity-reduction principles.
---

---

# Incremental Emacs Lisp Refactoring

Refactor the current Emacs Lisp codebase incrementally while preserving
observable behavior.

This skill is intended to be used together with **Ponytail**.

Ponytail supplies the general engineering principles concerning:

- minimalism;
- YAGNI;
- reuse before implementation;
- avoiding unnecessary abstractions;
- preferring existing platform/library functionality;
- reducing code and complexity.

This skill adds the Emacs-specific analysis and safe incremental refactoring
protocol.

The primary objectives are:

- find the canonical Emacs vector for each mechanism;
- use canonical Emacs representations;
- use canonical Emacs APIs;
- eliminate project-owned machinery that Emacs can own instead;
- understand unusual code before removing it;
- keep tests focused on project-owned behavior;
- preserve observable behavior;
- perform exactly one small independently verifiable refactoring at a time;
- keep Emacs loadable after every change.

The central reasoning order is:

> Ponytail → canonical vector → canonical representation → canonical API →
> Chesterton's Fence → minimal change → verification → stop

Do not optimize implementation details before determining whether the
implementation is operating through the correct Emacs vector.

The most important execution constraint is:

> Never perform a large refactor in one step.

Every refactoring step must leave the repository working and must be
independently verifiable and independently revertible.

## 1. Apply Ponytail first

Apply Ponytail's decision process before introducing or retaining
project-owned machinery.

Determine whether:

1. the behavior is needed at all;
2. existing project code already solves the problem;
3. Emacs itself already solves the problem;
4. a standard Emacs Lisp library already solves the problem;
5. an existing dependency already solves the problem;
6. custom implementation is actually necessary.

Do not reproduce Ponytail's complete general implementation philosophy here.

Use this skill for the Emacs-specific questions that remain after applying
Ponytail.

## 2. Find the canonical Emacs vector

Before simplifying an implementation locally, determine the canonical Emacs
vector for the problem.

A **canonical vector** is the mechanism, extension point, lifecycle path, or
architectural direction through which Emacs naturally expects this kind of
behavior to be implemented.

This is broader than choosing a canonical API.

Code may use valid standard Emacs APIs while still implement a feature through
the wrong architectural vector.

For every non-trivial mechanism, ask:

> What is the canonical way for an Emacs package to participate in this
> behavior?

Look especially for:

- polling or timers where Emacs provides an event or hook;
- advice where Emacs provides a dedicated hook or extension point;
- manual command dispatch where a keymap or transient map is appropriate;
- global bookkeeping where Emacs provides buffer-, window-, or frame-local
  state;
- manual lifecycle synchronization where Emacs already owns the lifecycle;
- integer positions where markers are intended to track edits;
- custom project discovery where `project.el` provides the integration point;
- textual parsing where syntax APIs or tree-sitter provide structural
  information;
- manually reconstructed display state where faces, text properties,
  overlays, display properties, or redisplay semantics provide the natural
  mechanism;
- custom state machines duplicating state already represented by Emacs
  objects or modes;
- explicit refresh mechanisms where normal Emacs invalidation or redisplay
  behavior is sufficient;
- manual focus/window/frame tracking where Emacs lifecycle hooks or object
  state already expose the transition;
- custom buffer lifecycle tracking where standard buffer hooks provide the
  event;
- custom command lifecycle tracking where command hooks or documented
  extension points exist.

Distinguish three separate questions:

1. **Canonical vector** — are we solving the problem through the correct Emacs
   extension or lifecycle mechanism?
2. **Canonical representation** — are we representing the state using the
   natural Emacs object or data model?
3. **Canonical API** — are we using the standard Emacs operation for the
   concrete action?

Investigate them in this order:

> vector → representation → API

Do not optimize an implementation that is operating through the wrong vector.

For example, replacing a custom timer helper with a cleaner use of
`run-with-idle-timer` is not a meaningful architectural simplification if the
timer exists only because the implementation failed to use the hook
representing the actual lifecycle event.

Likewise, simplifying operations on a global hash table may be the wrong
refactor if the state naturally belongs in a buffer-local variable.

When a potentially non-canonical vector is found:

1. determine what responsibility the mechanism serves;
2. determine why the current vector was chosen;
3. apply Chesterton's Fence before replacing it;
4. identify the canonical Emacs vector;
5. determine whether it preserves all required invariants;
6. determine which custom state, synchronization, timers, advice, or tests
   become unnecessary after migration;
7. prefer migration to the canonical vector over optimizing the workaround.

A strong refactoring candidate often removes an entire mechanism rather than
merely simplifying its implementation.

## 3. Find the canonical Emacs representation

After establishing the correct vector, inspect how the relevant concepts and
state are represented.

For every important concept ask:

> Is this the natural representation of this concept in Emacs?

Investigate whether something should naturally be:

- a buffer instead of a filename;
- a marker instead of an integer buffer position;
- a window instead of manually tracked display state;
- a frame-local value instead of global state;
- a buffer-local variable instead of a global registry;
- a window parameter instead of a parallel window-state table;
- a frame parameter instead of a parallel frame-state table;
- a text property instead of reconstructed display text;
- an overlay instead of manual highlighting bookkeeping;
- a face instead of direct visual mutation;
- a keymap instead of a command dispatcher;
- a hook instead of explicit notification code;
- an Emacs project abstraction instead of custom Git-root state;
- syntax information instead of textual parsing;
- a tree-sitter node instead of reconstructed syntax structure.

Prefer representations whose identity, lifetime, invalidation, or consistency
are already maintained by Emacs.

Before changing a representation:

1. determine why the current representation exists;
2. identify the invariants depending on it;
3. determine whether the canonical representation preserves them;
4. determine whether the change removes state or synchronization;
5. verify that no required lifecycle semantics are lost.

Do not migrate merely because another representation appears more idiomatic.

The migration should eliminate meaningful project-owned complexity.

## 4. Prefer canonical Emacs APIs

Only after checking vector and representation should implementation-level API
choices be optimized.

Actively look for project code duplicating functionality already provided by
Emacs or standard Emacs Lisp libraries.

Consider APIs and idioms from:

- Emacs core;
- `cl-lib`;
- `seq`;
- `subr-x`;
- `project`;
- buffer APIs;
- window APIs;
- frame APIs;
- marker APIs;
- text properties;
- overlays;
- faces;
- syntax APIs;
- tree-sitter;
- hooks;
- keymaps;
- transient maps;
- minor modes;
- timers;
- buffer-local variables;
- window parameters;
- frame parameters.

Look especially for:

- hand-written loops replacing standard sequence operations;
- manual list, alist, or plist manipulation;
- custom searching/filtering already covered by standard APIs;
- manual point bookkeeping;
- custom buffer identity bookkeeping;
- custom window/frame bookkeeping;
- custom hook-like mechanisms;
- command dispatchers duplicating keymap functionality;
- manual project/root detection;
- custom syntax parsing;
- textual heuristics where structural APIs exist;
- custom implementations of standard Emacs operations.

Do not replace simple code with a standard abstraction merely because that
abstraction exists.

The replacement should clearly reduce project-owned complexity, improve
correctness, or make the code more canonical and easier to reason about.

## 5. Look for duplicated Emacs state

Pay particular attention to state duplicating information Emacs already
maintains.

Look for:

- derived state stored unnecessarily;
- global variables mirroring buffer state;
- global variables mirroring window/frame state;
- manually tracked current buffer/window/frame;
- parallel registries;
- dirty flags;
- synchronization flags;
- cached values cheaply available from Emacs;
- state requiring several hooks to remain synchronized.

For every mutable project variable ask:

> Is this authoritative project state, or merely a copy of something Emacs
> already knows?

Prefer Emacs-owned authoritative state when practical.

Be especially suspicious of caches without an obvious invalidation strategy.

Do not remove caching or duplicated-looking state until its purpose and
performance implications are understood.

## 6. Apply Chesterton's Fence

Do not remove unusual code merely because Ponytail or the canonical-vector
analysis makes it appear unnecessary.

Treat every unusual:

- workaround;
- special case;
- defensive check;
- timer;
- idle timer;
- explicit redisplay;
- advice;
- cache;
- compatibility branch;
- ordering dependency;
- apparently redundant condition;

as a possible Chesterton's Fence.

Before removing or replacing it:

1. identify what problem it appears to solve;
2. inspect callers and callees;
3. inspect related tests;
4. inspect comments and documentation;
5. inspect nearby state transitions and lifecycle behavior;
6. inspect relevant repository history when useful;
7. determine whether the original problem can still occur;
8. only then decide whether removal is safe.

For every proposed removal, answer:

> Why did this probably exist, and why is that reason no longer applicable?

If the reason cannot be determined with reasonable confidence:

- do not remove the code;
- record it as requiring investigation;
- move to a safer candidate.

"Looks redundant" is not sufficient justification.

Chesterton's Fence takes precedence over aggressive simplification.

## 7. Preserve observable behavior

This is a refactor, not a redesign.

Unless explicitly requested, preserve:

- keybindings;
- command semantics;
- modal transitions;
- selection semantics;
- cursor behavior;
- buffer behavior;
- window behavior;
- frame behavior;
- highlighting;
- UI timing;
- messages;
- persistence;
- initialization;
- package loading;
- startup behavior;
- supported Emacs versions.

If changing behavior would substantially simplify the implementation, report
that separately as a possible future change.

Do not silently include it in the refactoring.

## 8. Audit tests by ownership

Tests should primarily protect behavior owned by this project.

Identify tests whose meaningful assertion is effectively:

> Does Emacs still behave like Emacs?

These are candidates for removal.

Examples include tests that:

- merely test a standard Emacs function;
- assert behavior guaranteed directly by an Emacs API with no meaningful
  project-specific semantics;
- test a dependency rather than project behavior;
- simply restate a trivial implementation;
- test trivial getters or setters with no invariant;
- test private implementation details without protecting observable behavior;
- duplicate another test without covering a distinct failure mode;
- cannot realistically fail unless Emacs itself is broken;
- mock so much behavior that the assertion provides little useful confidence.

For example, if project code is only:

```elisp
(defun foo ()
  (buffer-name))
```

then a test whose only meaningful assertion is that `foo` returns
`buffer-name` provides little project-specific regression protection.

However, do not remove a test merely because it exercises an Emacs API.

Keep tests that protect:

- project-specific arguments supplied to an Emacs API;
- integration between project logic and Emacs;
- state transitions;
- lifecycle behavior;
- previously observed regressions;
- non-obvious assumptions;
- boundary conditions;
- user-visible behavior;
- meaningful semantics added around an Emacs API.

For every test proposed for deletion, answer:

> What realistic regression in this project would this test detect?

If there is no meaningful answer, the test is probably low-value.

## 9. Prefer contract and regression tests

Prefer tests for:

- project contracts;
- user-observable behavior;
- important invariants;
- state transitions;
- boundary conditions;
- lifecycle behavior;
- actual regressions;
- integration points where project logic is non-trivial.

Avoid unnecessary coupling to:

- private helper names;
- intermediate representations;
- incidental call order;
- temporary variables;
- implementation details that may legitimately change during refactoring.

A behavior-preserving refactor should often be possible without rewriting
unrelated tests.

## 10. Add tests only when they buy confidence

Do not automatically add a test for every refactoring change.

Add or improve a test when:

- an important project invariant is unprotected;
- the refactor exposes a meaningful boundary case;
- a historical regression lacks coverage;
- the changed code contains non-trivial project behavior;
- the test protects against a realistic future regression.

Do not add tests merely to verify that a documented Emacs primitive continues
to work.

## 11. Identify Emacs-specific architectural smells

Explicitly investigate:

- a non-canonical extension/lifecycle vector;
- state duplicated between Emacs and project variables;
- global mutable state that could be buffer-local;
- global mutable state that could be window- or frame-local;
- caches without clear invalidation;
- multiple sources of truth;
- manual synchronization;
- ordering dependencies between hooks;
- timers used to repair lifecycle ordering;
- idle timers used as synchronization mechanisms;
- unnecessary explicit `redisplay`;
- advice where a documented extension point exists;
- hooks where a more direct lifecycle mechanism exists;
- functions whose names hide significant side effects;
- broad error suppression;
- `condition-case` hiding programming errors;
- accidental dependence on `current-buffer`;
- accidental dependence on the selected window/frame;
- integer positions surviving buffer edits;
- custom project/root detection;
- custom parsing where syntax APIs suffice;
- custom parsing where tree-sitter suffices;
- duplicated keymap logic;
- duplicated modal state;
- UI state manually synchronized with logical state;
- compatibility code for unsupported Emacs versions.

These are investigation targets, not automatic rewrite instructions.

## 12. Keep diffs narrow

Do not modify unrelated code merely because it is nearby.

Do not combine the selected refactor with:

- unrelated renaming;
- unrelated formatting;
- comment cleanup;
- definition reordering;
- stylistic modernization;
- adjacent cleanup;
- another independently useful refactor.

A narrow diff is easier to understand, review, verify, revert, and bisect.

## 13. Perform exactly one refactoring step

One invocation of this skill should normally perform exactly one
independently useful refactoring.

A step should change one concept.

Good examples:

- migrate one workaround to the canonical Emacs vector;
- replace one custom helper with one canonical Emacs API;
- replace one non-canonical representation;
- remove one redundant state variable;
- remove one dead helper;
- simplify one state transition;
- replace one custom project-root mechanism;
- eliminate one duplicated calculation;
- remove one unnecessary timer;
- simplify one lifecycle path;
- remove one coherent group of tautological tests.

Bad examples:

- refactor the tab system;
- clean up modal editing;
- simplify state management;
- modernize the package;
- rewrite the tests;
- replace all custom abstractions.

If the proposed step contains several independently valuable changes, split it.

## 14. Keep every step independently revertible

Every completed step must form a clean rollback boundary.

It should be possible to revert the resulting change without depending on
later refactoring work.

Do not intentionally leave:

- broken callers;
- half-migrated representations;
- temporary broken states;
- failing tests;
- unloadable packages;
- broken startup.

If a migration cannot safely be performed atomically, divide it into
preparatory steps that are themselves behavior-preserving and useful.

## 15. Understand before modifying

At the beginning of a refactoring session, inspect enough context to
understand the relevant architecture.

Determine, as applicable:

- package/module boundaries;
- package entry points;
- initialization path;
- supported Emacs version;
- important state variables;
- buffer-local state;
- window-local and frame-local state;
- public commands;
- interactive commands;
- keymaps;
- hooks;
- advice;
- timers;
- lifecycle behavior;
- tests;
- important invariants;
- unusual workarounds;
- dependencies between packages;
- places where project code duplicates Emacs functionality.

Do not modify the first suspicious function before understanding its role.

## 16. Build a candidate inventory

Before selecting the change, identify several plausible refactoring
opportunities in the relevant area.

For each candidate determine:

- location;
- current vector;
- canonical vector;
- current representation;
- canonical representation, if different;
- current API/mechanism;
- canonical API, if applicable;
- expected complexity reduction;
- behavior that must remain unchanged;
- Chesterton's Fence considerations;
- existing test coverage;
- verification strategy;
- confidence;
- risk.

Classify risk approximately as:

- **low** — local, obvious, easily verified, little lifecycle impact;
- **medium** — affects shared state or multiple callers;
- **high** — affects initialization, lifecycle, windows/frames, timing,
  representation, or broad architecture.

Prefer high-confidence, useful, low-risk improvements.

Do not optimize for the largest possible refactor.

## 17. Select exactly one candidate

After the audit, select exactly one independently useful refactoring.

Before editing, establish:

### Change

Exactly what will change.

### Canonical vector

What the canonical Emacs architectural/lifecycle mechanism is and whether the
current implementation already uses it.

### Canonical representation

What the natural Emacs representation is and whether the current
implementation already uses it.

### Canonical API

Which Emacs/Elisp API should implement the operation.

### Reason

Why the change reduces project-specific complexity.

### Chesterton check

Why the existing implementation appears to exist and why changing it is safe.

### Invariant

What observable behavior must remain unchanged.

### Verification

How this specific change will be verified.

### Rollback boundary

Why the change can be independently reverted.

## 18. Execute only the selected change

Once a candidate is selected:

1. modify only what is necessary;
2. run the smallest useful verification;
3. inspect failures;
4. fix only failures caused by this change;
5. run verification again;
6. inspect the resulting diff;
7. confirm no unrelated changes slipped in.

If implementation reveals that the change is substantially larger than
expected:

> Stop expanding the refactor.

Instead:

1. determine whether the change can be split further;
2. revert unsafe partial work if necessary;
3. select the smallest independently safe prerequisite;
4. perform only that prerequisite.

A supposedly small refactor must not grow opportunistically.

## 19. Use an Emacs-specific verification hierarchy

Choose verification appropriate to the change.

Consider, in increasing scope:

1. ensure changed Lisp can be read/parsed;
2. byte-compile affected files;
3. run directly relevant ERT tests;
4. run the broader relevant test suite;
5. load the affected package in batch Emacs;
6. run a minimal initialization/startup smoke test;
7. perform a focused interactive smoke test when necessary.

Use the cheapest verification that gives meaningful confidence, but do not
under-test lifecycle or initialization changes.

## 20. Protect Emacs startup explicitly

Changes involving any of the following require explicit consideration of
startup/load verification:

- package initialization;
- `use-package` integration;
- autoloads;
- hooks;
- advice;
- startup keymaps;
- global modes;
- frame initialization;
- package dependencies;
- load paths;
- `require`;
- compile-time dependencies;
- macros used while loading;
- global state initialized at load time.

For such changes, verify at minimum that the relevant package/configuration
can still be loaded in a suitably minimal Emacs process.

An Emacs configuration that no longer starts is not an acceptable
intermediate refactoring state.

## 21. Do not trust passing tests blindly

Passing tests do not prove that a refactor is safe.

After tests pass, inspect:

- warnings;
- byte-compilation output;
- package loading;
- startup when relevant;
- changed lifecycle assumptions;
- the final diff.

Ask whether the existing tests would actually detect the most plausible
regression caused by this change.

If not, perform an appropriate smoke test or add a meaningful regression test
when justified.

## 22. Use history as evidence when needed

Comments, tests, and git history may explain why unusual code exists.

Use them to reconstruct intent, especially for Chesterton's Fence analysis.

They are evidence, not unquestionable truth.

Verify whether historical assumptions still apply to the current code and
supported Emacs versions.

## 23. Session execution protocol

When this skill is invoked to perform a refactor, follow this protocol.

### Phase A — Inspect

Inspect the relevant code and tests.

Do not modify anything yet.

### Phase B — Identify

Find several plausible refactoring opportunities.

For each significant mechanism reason explicitly through:

> Ponytail → vector → representation → API → Chesterton

Distinguish genuine simplifications from workarounds protecting important
invariants.

### Phase C — Rank

Rank candidates by:

1. expected complexity reduction;
2. confidence;
3. risk;
4. verification cost.

Prefer a vector-level simplification over a local API cleanup when the
vector-level change safely eliminates the mechanism being cleaned up.

### Phase D — Select

Select exactly one small refactoring.

Do not select a broad theme containing several changes.

### Phase E — Implement

Implement only the selected refactoring.

### Phase F — Verify

Run appropriate verification.

Explicitly consider:

- byte compilation;
- relevant ERT tests;
- package loading;
- Emacs startup.

### Phase G — Review

Inspect the diff.

Confirm that:

- behavior is preserved;
- the diff contains no unrelated cleanup;
- project-specific complexity decreased;
- the canonical vector is respected;
- the representation is appropriate;
- tests remain meaningful;
- no new synchronization/state problem was introduced;
- the change remains independently revertible.

### Phase H — Report and stop

Report:

- what changed;
- why;
- current and canonical vector;
- current and canonical representation where relevant;
- canonical Emacs API used, if any;
- Chesterton's Fence conclusion;
- what code/state/tests became unnecessary;
- verification commands and results;
- remaining concerns;
- promising candidates for a future invocation.

Then **STOP**.

Do not automatically begin another refactoring.

## 24. Audit-only mode

If explicitly asked only for an audit, analysis, or plan:

- do not modify code;
- inspect the codebase;
- produce a prioritized refactoring inventory;
- identify non-canonical vectors;
- identify non-canonical representations;
- identify canonical Emacs APIs;
- identify Chesterton's Fences;
- identify questionable tests;
- divide proposed work into small independently verifiable steps.

For each proposed step include:

- change;
- canonical vector;
- canonical representation, where relevant;
- canonical API, where relevant;
- reason;
- Chesterton check;
- invariant;
- risk;
- verification;
- rollback boundary.

Do not execute the plan unless explicitly requested.

## 25. Existing refactoring backlogs

If the repository contains an existing refactoring backlog or audit such as
`REFACTORING.md`, treat it as evidence and context rather than an
unquestionable task list.

Before executing an old candidate:

1. verify that it still applies;
2. verify its assumptions;
3. reconsider its priority;
4. re-evaluate vector, representation, and API;
5. repeat the Chesterton check.

Record useful discoveries when appropriate, especially:

- why unusual code must remain;
- rejected refactoring ideas and why;
- important invariants;
- historical failure modes.

This prevents future sessions from repeatedly proposing the same unsafe
cleanup.

## 26. Core questions

Throughout the refactor repeatedly ask, in this order:

> Does Ponytail indicate that this mechanism should exist at all?

> What is the canonical Emacs vector for this behavior?

> Are we currently using that vector?

> What is the canonical Emacs representation?

> Are we storing information Emacs already owns?

> What is the canonical Emacs API for the remaining operation?

> Why does the current unusual code exist?

> What invariant does it protect?

> Can the same invariant be preserved with less project-owned state and
> synchronization?

> Is this timer repairing a lifecycle problem?

> Is this advice replacing a proper extension point?

> Does this test protect project behavior, or merely test Emacs?

> What realistic project regression would this test detect?

> Can this change be independently reverted?

> If Emacs stops starting after this change, will the cause be immediately
> localized to this step?

If the answer to the final question is no, the refactoring step is probably
too large.

## Definition of done

A refactoring invocation is complete only when:

- Ponytail's general simplification principles have been applied;
- the canonical vector has been considered;
- the canonical representation has been considered;
- the canonical API has been considered;
- Chesterton's Fence has been applied where relevant;
- exactly one coherent concern was changed;
- observable behavior is preserved;
- project-owned complexity decreased;
- relevant tests pass;
- byte compilation succeeds when applicable;
- package loading succeeds when applicable;
- Emacs startup succeeds when the change can affect startup;
- the diff contains no unrelated cleanup;
- the change can be independently reverted;
- the result has been summarized;
- no subsequent refactoring has been started.

The desired end state is:

- less project-owned machinery;
- canonical Emacs extension and lifecycle vectors;
- canonical Emacs representations;
- canonical Emacs APIs;
- fewer duplicated sources of truth;
- fewer synchronization mechanisms;
- clearer invariants;
- tests focused on behavior owned by the project;
- small bisectable changes;
- easy rollback;
- Emacs remaining loadable throughout the refactoring process.
