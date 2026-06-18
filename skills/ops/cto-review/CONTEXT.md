# cto-review — Overview

3-stage sequential ICM procedure for strategic CTO-level PR review.

## Purpose

The monolithic `cto-review` skill ran the full review (context-gathering, the diff judgement, and
the act/merge steps) in a single context window. By the time the model formed its verdict, the
context carried all the metadata-fetching noise, degrading judgement. This procedure isolates the
critical step — the whole-diff review — into a clean-context subagent that sees only what it needs.

This proc covers **PR review ONLY**. The original skill had a second "Heartbeat Operating Loop"
mode; it was a stale duplicate of the separate `auto-pylot` skill and is intentionally NOT carried
over here.

## Architecture

3 sequential stages. No parallelism.

- **01-setup** (subagent): gather repo context, PR metadata, full diff, and merge state. Pure
  read. Detects the CLOSED-not-merged case and short-circuits.
- **02-review** (subagent): the isolated critical-judgement step. Reviews the WHOLE diff in
  cohesion across every dimension (docs, deps, downstream/template impact, correctness, security,
  process, merge strategy) and produces verdict + checklist + action items. No side effects.
- **03-synthesize-act** (inline): the only stage with side effects. Posts the formatted GH review
  comment, applies the verdict label, merges-or-labels honoring merge state and CI, writes the
  local report file, and emits the outcome marker from the orchestrator.

## Key invariants

- Stages 01 and 02 are read-only — no GH comments, no labels, no merge.
- Stage 02 is the ONLY judgement point and runs in isolated context — setup handoff in, verdict out.
  comes from the orchestrator, never a subagent.
- Merge state is authoritative: a CLOSED-not-merged PR short-circuits (skip 02); an already-merged
  PR gets a post-merge review note and is never re-merged.
- Never merge if CI is red, even on LGTM.
- Reporting is the local report file only. No Quest.

## Folder map

```
SKILL.md             — invocation reference and execution logic
CONTEXT.md           — this file
shared/              — review-comment-format.md, report-format.md
stages/01-03/        — CONTEXT.md per stage
```

## Runtime handoff path

```
.procedure-output/cto-review/{stage}/handoff.md
```

Written at runtime in the repo working directory (not inside the skill directory).

## Emit on completion

