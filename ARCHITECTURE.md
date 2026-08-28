# Repository instructions

## Extend selection invariants

- While Extend is active (`ri--selection-active-p`), switching the selection submode MUST preserve the exact existing selection bounds. Reinterpreting or snapping to the new unit MUST NOT shrink or expand the selection.
- After every Extend navigation command, point MUST remain on the active selection edge: on the last selected character for the `end` edge and on the first selected character for the `start` edge. Only an explicit cursor swap may change which edge is active.

## Startup performance

- Startup timing/profile requests and changes to `ri.el` top-level dependencies, lazy-loading boundaries, or `ri-enable` MUST follow `.agents/skills/ri-startup-performance/SKILL.md`. Keep the command, comparison workflow, and regression policy there rather than duplicating them in this file.
