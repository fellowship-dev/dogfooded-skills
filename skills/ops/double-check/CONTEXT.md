# double-check — Overview

4-stage SEQUENTIAL ICM procedure for a standalone second-pass PR review.

## Purpose

The monolithic `double-check` ran as a single session: by the time it formed a verdict, its
context carried the full history of fetching, diffing, curating, and fixing. That history biases
the judgement (confirmation toward what it already decided). This procedure isolates the
critical-judgement step — the cohesive second-pass review — into its own clean-context stage that
sees ONLY the PR, the first review, and the diff. Fresh eyes are the entire point.

## Why sequential, not parallel

A second-pass review must be **holistic**. A PR is reviewed in cohesion: the whole diff, all
dimensions (correctness, edge cases, tests, docs, deps, security) considered together in ONE
verdict. Splitting the review into parallel per-file or per-dimension subagents loses cross-cutting
cohesion and multiplies cost. The ICM win here is clean-context isolation of the judgement step —
NOT parallelism. There is no fan-out anywhere in this proc.

## Architecture

4 stages, all sequential:

- **01-setup** (subagent): side-effect-light gather + checkout. Fetches PR metadata, CI status,
  the existing (first) review comments, and the full diff; checks out the PR branch and merges the
  base branch to surface conflicts. Records `REPO_DIR` for the fix stage.
- **02-review** (subagent, CLEAN CONTEXT): the isolated critical-judgement step. In a context
  containing only the setup handoff (PR + first review + diff), it produces ONE cohesive review —
  verifying the first review's claims, finding missed edge cases, and checking tests/docs together —
  and emits a single consolidated verdict + curated findings table. No side effects.
- **03-fix** (subagent): the only stage with code side effects. Applies MUST-FIX (and worthwhile
  NICE-TO-HAVE) fixes in `REPO_DIR`, re-runs the test suite, and pushes. Skipped entirely if
  stage 02 reported `fixes_needed: false`.
- **04-post** (inline): posts the curated review comment, applies the `double-checked` label,
  comes from the orchestrator.

## Key invariants

- Stage 02 is the isolated critical-judgement step. It receives only PR + first review + diff.
- Stage 02 is ONE cohesive review — never split per-file or per-dimension.
- Stage 03 is the only stage that mutates code; it is conditional on `fixes_needed: true`.
- The `double-checked` label is applied only after the comment posts (stage 04).
- NO Quest anywhere. Reporting = local report file only.

## Folder map

```
SKILL.md             — invocation reference and execution logic
CONTEXT.md           — this file
stages/01-04/        — CONTEXT.md per stage
shared/              — review-comment-template.md, report-template.md
```

## Runtime handoff path

```
.procedure-output/double-check/{stage}/handoff.md
```

Written at runtime in the repo working directory (not inside the skill directory).

## Emit on completion

