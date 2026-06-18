# review-pr — Overview

3-stage SEQUENTIAL ICM procedure for read-only first-pass PR review.

## Purpose

The monolithic `review-pr` ran every step — dedup gate, context gathering, full diff read,
analysis, confidence-scoring, convention check, comment post, label, report — in one session. By
the time the critical-judgement step ran (analyze + score the diff), the context window was already
polluted with raw `gh` JSON, the entire diff, CI output, and existing PR comments. This proc
converts the judgement step into an isolated subagent that sees only the curated PR context and the
diff.

## Architecture

3 stages, run **strictly in sequence**. There is NO parallelism and NO fan-out.

- **Stage 00 (inline):** dedup gate + gather all PR context (metadata, conventions, existing
  comments/reviews, CI status) and the full diff. Read-only. If the PR already has the `reviewed`
  label, the orchestrator emits the already-complete marker and stops — stages 01/02 do not run.
- **Stage 01 (subagent, single):** the critical-judgement step. ONE subagent reviews the WHOLE
  diff in cohesion — correctness analysis, confidence-scoring (≥80 threshold), convention
  compliance, and the mandatory Closes-vs-Refs check, all together in one clean context. This is
  the only Task spawn, and it is NOT split per-file or per-dimension.
- **Stage 02 (inline):** post the structured review comment, apply the `reviewed` label, write the
  local report file, and emit the outcome marker from the orchestrator.

## Why cohesion, not fan-out

A PR is a single cohesive change. Splitting the review per-file (one subagent per file) fragments
cross-file reasoning — a finding in `a.ts` is often only a bug because of what `b.ts` does. It also
multiplies cost and loses the holistic verdict. The whole diff is reviewed together, once.

## Key invariants

- Stage 00: inline, read-only. Runs the dedup gate before any work; establishes the only context
  the subagent will see.
- Stage 01: pure analysis, no side effects. Sees the whole diff. Confidence threshold 80. Verdict
  is always "proceed to double-check" — never blocks.
- Stage 02: inline, the only side-effecting stage (comment + label + report file). MUST emit
- Read-only throughout: no checkout, no fixes, no pushes. Diff comes from `gh pr diff`.
- NO QUEST anywhere: reporting is the local report file only.

## Folder map

```
SKILL.md             — invocation reference and execution logic
CONTEXT.md           — this file
stages/00-context/   — CONTEXT.md (inline: dedup gate + context + full diff)
stages/01-cohesive-review/ — CONTEXT.md (subagent: whole-diff review)
stages/02-post/      — CONTEXT.md (inline: comment + label + report + outcome)
```

## Runtime handoff path

```
.procedure-output/review-pr/{stage}/handoff.md
```

Written at runtime in the repo working directory (not inside the skill directory).

## Emit on completion

