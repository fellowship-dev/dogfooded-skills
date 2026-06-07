# deps-runner — Overview

6-stage SEQUENTIAL ICM procedure for the dependency-PR verification and merge pipeline.

## Purpose

The monolithic `deps-runner` ran as a single `claude -p` session that processed every
dependency PR end-to-end in one context. By the time it reached risk classification and merge
decisions, the window carried the full history of preflight, diffs, build logs, and test
output for every prior PR — degrading the quality of exactly the steps that matter most
(risk judgement and merge decision).

This procedure converts the pipeline into isolated sequential stages. The critical-judgement
step — **risk evaluation** — runs in its own clean-context stage (03-risk-eval) with only the
PR list and diffs it needs. That isolation, plus resume-from-stage, is the ICM win here.

## Architecture

6 stages, SEQUENTIAL. There is **no parallelism and no fan-out**:

- Stage 01 and 06 run inline in the orchestrator (no Task spawn).
- Stages 02–05 each run as a single Task subagent with isolated context, one after another.
- Stage 03 (risk-eval) evaluates **all** dependency groups in one cohesive pass — never one
  subagent per group. A PR/dependency is reasoned about as a whole.

## Why sequential, not parallel

A dependency PR is verified and judged **in cohesion**: the diff, dep type, direct usage,
build result, and test result are all considered together. Splitting risk eval per-group or
per-dimension across concurrent subagents loses cross-cutting context and multiplies cost
without improving the judgement. The original pipeline is inherently serial anyway —
"one PR at a time, reset to main between each" — so the proc preserves that ordering.

## Key invariants

- Stage 01: inline, read-only. Fetches candidate PRs (the report MUST begin with these),
  reads repo + team CLAUDE.md, resolves the container, groups PRs. No side effects.
- Stage 02: preflight baseline on main. Build + test + booster remote sync. If main does not
  compile, the run is blocked — but stage 06 still produces a report.
- Stage 03: risk evaluation — the isolated critical-judgement stage. Pure analysis over all
  groups. No side effects, no merges.
- Stage 04: first stage with branch-level side effects (checkout, merge main, install, build,
  test). Per PR, sequentially.
- Stage 05: merge decision — applies the merge matrix. Only stage that merges/labels PRs and
  may write targeted tests. Enforces the review pipeline (reviewed → double-checked).
- Stage 06: inline. Writes the local report file(s), releases the Ona environment, and MUST
  emit `[pylot] outcome=...` from the orchestrator. **No Quest POST.**

## Resume-from-stage

`resume_from={NN-name}` reuses on-disk handoffs from completed stages and begins at the named
stage. Completed stages are NOT re-run. A missing upstream handoff invalidates the resume
point. This makes a partially-completed run cheap to continue (e.g. resume at 04-build-test
after a transient Ona hiccup) without redoing preflight and risk evaluation.

## Folder map

```
SKILL.md             — invocation reference and execution logic
CONTEXT.md           — this file
stages/01-06/        — CONTEXT.md per stage
shared/              — report-template.md, risk-matrix.md
```

## Runtime handoff path

```
.procedure-output/deps-runner/{stage}/handoff.md
```

Written at runtime in the repo working directory (not inside the skill directory).

## Emit on completion

- Success: `[pylot] outcome="deps-runner complete: {merged}/{total} merged, {flagged} flagged" status=success`
- Failure: `[pylot] outcome="deps-runner failed at stage NN: {reason}" status=failed`
- Blocked: `[pylot] outcome="deps-runner blocked: preflight failed" status=blocked`
