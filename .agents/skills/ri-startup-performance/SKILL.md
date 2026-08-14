---
name: ri-startup-performance
description: >
  Measure or protect Emacs + Ri startup performance. Use when the user asks
  for startup timing, startup profiling, startup regression checks, or when a
  change touches ri.el top-level dependencies, lazy-loading boundaries, or
  ri-enable.
argument-hint: "[measure|before|after]"
---

# Ri Startup Performance

Use the repository-owned `ri-startup-benchmark.el`. It is the source of truth
for scenarios, isolation, sampling, garbage collection, and metric output.
Never reimplement its timing loop in shell, ERT, Hyperfine, or another script.

## Default: `measure`

Run one benchmark from the repository root:

```sh
: "${KKP_DIR:?Set KKP_DIR to the directory containing kkp.el}"
emacs -Q --batch -L "$KKP_DIR" -L . \
  -l ri-startup-benchmark.el \
  --eval '(ri-startup-benchmark-run)'
```

If `KKP_DIR` is unset, locate the installed `kkp.el` first and use its
containing directory. Do not ask the user for a path that can be found from
the repository, Emacs package directories, or the current environment.

Report these emitted values without rounding them again:

- `control_median_ms` and `control_mad_ms`;
- `load_increment_ms`;
- `enable_increment_ms`;
- `load_over_control_pct`;
- `enable_over_load_pct`;
- Emacs version, system configuration, and repetition count.

A single measurement describes the current checkout. Do not call it a
regression or improvement without a comparable baseline.

## Startup-sensitive code changes

For changes to `ri.el` top-level dependencies, lazy-loading boundaries, or
`ri-enable`:

1. Run `before` immediately before editing.
2. Keep the same Emacs binary, `KKP_DIR`, checkout, and repetition count.
3. Make only the intended startup-sensitive change.
4. Run the focused behavioral tests for the changed boundary.
5. Run `after` with the same command.
6. Compare median `load_increment_ms` and `enable_increment_ms` values.

Treat a slowdown as actionable only when it exceeds both 5 ms and 10% for one
increment. Rerun `after` once to reject transient system noise. A repeated
regression must be fixed or explicitly justified by a measured correctness
tradeoff.

Do not compare individual child samples, user init time, real marked-tab
restoration, different Emacs builds, or different machines.

## Profiling

Profile only after the benchmark identifies a repeatable material cost.
Separate:

- package loading (`require 'ri`);
- synchronous activation (`ri-enable`).

Rank existing top-level requires or `ri-enable` operations, change the largest
non-essential cost first, then benchmark again. Preserve immediate terminal,
modal, tab, pair, mouse, semantic-region, and Extend behavior. Do not move work
to an idle timer or startup hook merely to hide it outside the measured phase.

Stop when the next candidate does not improve either increment repeatably by
more than the noise rule. Revert speculative lazy-loading or abstractions that
do not pay for themselves.

## Output

For `measure`, report the current metrics and environment.

For `after`, report a compact table with before, after, absolute delta, and
percentage delta for both increments, followed by one verdict:

- improvement;
- no material change;
- repeated regression requiring correction or explicit justification.
