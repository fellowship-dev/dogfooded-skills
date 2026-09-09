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

## Worker lifecycle

Stage 01 preflights the target repo's devbox image (`pylot devboxes project`) and, if an
image exists, spawns the worker (`pylot workers spawn --mission "$PYLOT_JOB_ID"`) that stages
02-05 drive via `pylot workers prompt`/`output`. Stage 06 stops it
(`pylot workers stop --force`) as its first action. See `pylot-cli` § Workers for the full
API. `worker_id` is established in stage 01's handoff and forwarded, unchanged, in every
downstream stage's own handoff — no stage rediscovers or reprovisions a worker that a prior
stage already warmed up, except on an explicit resume where the recorded worker is no longer
live.

## Key invariants

- Stage 01: inline, read-only w.r.t. the target repo (it does write handoff.md and spawn a
  worker). Fetches candidate PRs (the report MUST begin with these), reads repo + team
  CLAUDE.md, preflights and spawns the devbox worker, groups PRs. If the repo has no worker
  image, stage 01 records `devbox_ready: false` and the run skips straight to stage 06.
- Stage 02: preflight baseline on main. Build + test + booster remote sync, driven on the
  worker spawned in stage 01. If main does not compile, the run is blocked — but stage 06
  still produces a report.
- Stage 03: risk evaluation — the isolated critical-judgement stage. Pure analysis over all
  groups (read-only worker queries: diff/grep). No side effects, no merges.
- Stage 04: first stage with branch-level side effects (checkout, merge main, install, build,
  test) on the worker. Per PR, sequentially.
- Stage 05: merge decision — applies the merge matrix. Only stage that merges/labels PRs and
  may write targeted tests. Enforces the review pipeline (reviewed → double-checked).
- Stage 06: inline. Stops the worker, writes the local report file(s), and MUST emit
  `[pylot] outcome=...` from the orchestrator. **No Quest POST.**
- A stage-level exception (subagent errors, times out, or exits without writing handoff.md) is
  distinct from a graceful stage failure recorded in a handoff — there is no handoff to read
  Failure rules from. The orchestrator treats it as a hard blocker directly and routes straight
  to stage 06, using `worker_id` from the most recent handoff that has one, so the worker is
  stopped even when a stage crashes outright.

## Resume-from-stage

`resume_from={NN-name}` reuses on-disk handoffs from completed stages and begins at the named
stage. Completed stages are NOT re-run. A missing upstream handoff invalidates the resume
point. This makes a partially-completed run cheap to continue (e.g. resume at 04-build-test
after a transient worker hiccup) without redoing preflight and risk evaluation — as long as
the carried-forward `worker_id` is still live; if it was stopped or reaped, the resuming stage
spawns a replacement before proceeding.

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
- Blocked: `[pylot] outcome="deps-runner blocked: {reason}" status=blocked` (main doesn't
  compile, or the repo has no devbox image)
