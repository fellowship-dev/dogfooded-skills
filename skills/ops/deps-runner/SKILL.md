---
name: deps-runner
description: Use when running the full dependency update pipeline for a repo — scan, risk-eval, build-test, and merge-decision.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Task
---

## Purpose

Dependency-PR verification and merge pipeline, partitioned into 6 sequential ICM stages:
scan/context → preflight baseline → risk-eval (single cohesive stage, ALL groups) →
build-test → merge-decision → report. Each stage runs in isolated context; the critical
judgement (risk evaluation) gets a clean-context stage of its own. Behaviorally equivalent
to the monolithic `deps-runner` skill, just stage-partitioned.

**This skill runs in the OPERATOR session** and owns its worker lifecycle. Stage 01
preflights the target repo's devbox image and spawns the worker that stages 02-05 drive
via the gateway worker API (see the `pylot-cli` skill, § Workers); stage 06 stops it.
Stages that only need `gh` CLI (scan-context, merge-decision's label/merge step, report)
run inline in the operator session without touching the worker.

**This procedure is SEQUENTIAL. There is NO fan-out and NO parallel Task launches.** Risk
evaluation runs as ONE stage over every dependency group — never one subagent per group. The
ICM win here is clean-context isolation of the judgement step plus resume-from-stage, not
parallelism.

## Worker Lifecycle

A worker is a Fargate devbox running the target repo (see `pylot-cli` § Workers). Stage 01
preflights the repo and spawns the worker; stages 02-05 drive it; stage 06 stops it. The
worker's identity (`worker_id`) is established in stage 01's handoff and then **forwarded
unchanged in every downstream stage's own handoff** — that is how a clean-context subagent
in, say, stage 04 knows which worker stage 02 already warmed up, without ever seeing the
orchestrator's shell state (Task subagents do not inherit the orchestrator's bash variables).

### Required environment and worker-turn rule

The worker procedure requires all three environment variables: `PYLOT_API` (gateway base URL),
`PYLOT_JOB_ID` (the mission passed to every worker command), and `PYLOT_OPERATOR_TOKEN`
(operator authentication for the gateway). Verify they are available before any worker action.
`pylot workers output` returns **only the latest turn result**; read and record every
load-bearing result before sending the next `pylot workers prompt`, because a later prompt
replaces the output available to read.

```bash
# Stage 01 — preflight (no task_def => no built image => cannot spawn)
pylot devboxes project "$REPO"

# Stage 01 — spawn (only if devboxes project reported a task_def)
SPAWN=$(pylot workers spawn --mission "$PYLOT_JOB_ID" repo="$REPO" \
  name="deps-runner-$(echo "$REPO" | tr '/' '-')")
printf '%s' "$SPAWN" > .procedure-output/deps-runner/01-scan-context/.spawn-raw.json  # recovery record before parsing
WID=$(printf '%s' "$SPAWN" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("worker_id",""))
except Exception:
    print("")')

# Stages 02-05 — drive (each stage reads worker_id from the prior stage's handoff)
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 600 "<instruction>"
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"

# Stage 06 — stop, FIRST action, before writing the report, then confirm terminal state
pylot workers stop "$WID" --mission "$PYLOT_JOB_ID" --force
# poll `pylot workers list --mission "$PYLOT_JOB_ID"` for this worker's confirmed-stop shape —
# ecs_status == STOPPED, or (ecs_status null/absent and status == stopped with a non-empty
# stopped_at) — on a bounded budget before recording stopped: yes — see stage 06's CONTEXT.md
```

If `pylot devboxes project "$REPO"` reports no `task_def`, the repo has no built worker
image. Building one (`pylot deploy build-worker <org/repo> --wait`) needs an admin
credential — an operator gets `403` — so this procedure cannot self-heal that. Record
`devbox_ready: false` in stage 01's handoff and skip straight to stage 06: there is nothing
to build or test without a devbox, and stage 06 still writes a blocked report.

If a resumed run's recorded `worker_id` is no longer live
(`pylot workers view "$WID" --mission "$PYLOT_JOB_ID"` shows `stopped`/`reaped`), spawn a
replacement worker for the same repo, record the new `worker_id` in that stage's handoff,
and continue — the fresh devbox starts from a clean checkout, so the rest of the pipeline
is unaffected.

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `repo` | yes | — | Target `org/repo` (positional `$0`) |
| `resume_from` | no | (start fresh) | Stage to resume at, e.g. `04-build-test`. Reuses on-disk handoffs from completed stages and skips them. |

Parse from `$ARGUMENTS`. Forms accepted:
- `org/repo` → fresh run
- `org/repo resume_from=04-build-test` → resume run

## What it does

6-stage SEQUENTIAL ICM procedure:

| Stage | Mode | Description |
|-------|------|--------------|
| 01-scan-context | inline | Fetch candidate dep PRs, read repo + team CLAUDE.md, preflight the repo devbox and spawn the worker, group PRs |
| 02-preflight-baseline | subagent | Verify main compiles + tests pass on the worker; record baseline; booster remote sync |
| 03-risk-eval | subagent | SINGLE stage: classify every dependency group (diff, dep type, direct usage, risk) |
| 04-build-test | subagent | Per PR: checkout+merge main, install+build, restart if runtime, run tests vs baseline |
| 05-merge-decision | subagent | Apply merge matrix per PR: auto-merge/label, write targeted tests, or flag for Max |
| 06-report | inline | Stop the worker; write local report file(s); emit outcome marker |

No stage fans out. Stage 03 evaluates ALL dependency groups in one cohesive pass — do not
spawn one subagent per group.

## Handoff locations

All handoffs live in the repo working directory:
```
.procedure-output/deps-runner/{stage}/handoff.md
```

Stage 01 writes the root context. Each subagent stage receives only the handoffs its
CONTEXT.md lists as inputs — never the full orchestrator context.

## Execution

### Stage 01 (inline)

Run stage 01 yourself (orchestrator context). Read CONTEXT.md:
```
.claude/skills/deps-runner/stages/01-scan-context/CONTEXT.md
```
Write handoff to `.procedure-output/deps-runner/01-scan-context/handoff.md`.

If stage 01 records `devbox_ready: false`, skip stages 02-05 entirely and go straight to
stage 06 — there is no worker to drive.

### Stages 02 → 05 (sequential subagents — ONE AT A TIME)

For each stage in order, spawn exactly ONE Task. Wait for it to finish before spawning the
next. Never launch two stages in the same response. Never split a stage across multiple
concurrent subagents.

Each Task prompt must be self-contained:
- Include only the stage's input handoff paths (listed in that stage's CONTEXT.md)
- Include the path to the stage's CONTEXT.md
- Do NOT pass orchestrator history or prior reasoning

Task prompt template:
```
You are running stage {NN}-{name} of the deps-runner procedure.

Read your stage instructions:
  .claude/skills/deps-runner/stages/{NN}-{name}/CONTEXT.md

Your inputs:
  {input handoff path(s) from that stage's CONTEXT.md}

Write your output to:
  .procedure-output/deps-runner/{NN}-{name}/handoff.md

Execute all steps in CONTEXT.md. Write handoff.md before exiting.
```

If a stage's handoff reports a hard blocker (preflight failure, merge conflict on a stale PR,
build/test failure on every PR), continue per that stage's Failure rules — typically the
blocker is recorded and flagged, but the run proceeds to 06-report so the report is always
produced.

If the Task call itself fails — the subagent errors, times out, or otherwise exits without ever
writing `handoff.md` — that is NOT a graceful stage failure and none of the above applies (there
is no handoff to read Failure rules from). Treat it as a hard blocker directly: do not retry the
stage, do not attempt to continue to the next stage, and do not leave the run open. Go straight to
stage 06, reading `worker_id` from the most recent handoff that has one (the crashed stage's own
handoff does not exist, so use the prior stage's). Stage 06 still stops that worker as its first
action and writes a blocked report — a crashed subagent must never leave the worker running.

### Stage 06 (inline)

Run stage 06 yourself (orchestrator context). Read CONTEXT.md:
```
.claude/skills/deps-runner/stages/06-report/CONTEXT.md
```
Stop the worker (first action), then write the local report file(s). Emit the
`[pylot] outcome=...` marker from the orchestrator (not from a subagent). **There is NO Quest
POST — write the local report file only.**

## Resume-from-stage

When `resume_from={NN-name}` is set:

1. Verify the handoffs for all stages BEFORE `resume_from` already exist on disk:
   ```bash
   ls .procedure-output/deps-runner/*/handoff.md
   ```
2. Do NOT re-run completed stages — their handoffs are reused as-is as inputs to later stages.
3. Begin execution at the named stage and continue sequentially to 06-report.
4. If a required upstream handoff is missing, STOP and report which one — the resume point is
   invalid; the run must start from an earlier stage.
5. If resuming at a stage that drives the worker (02-05), verify the recorded `worker_id` is
   still live (`pylot workers view "$WID" --mission "$PYLOT_JOB_ID"`) before proceeding —
   respawn if it shows `stopped`/`reaped` and record the new id in that stage's handoff.

Stage names for `resume_from`: `02-preflight-baseline`, `03-risk-eval`, `04-build-test`,
`05-merge-decision`, `06-report`. (`01-scan-context` = a fresh run, no resume needed.)

## Stage handoff chain

```
01-scan-context (inline, preflights + spawns worker)
      │
      ▼
02-preflight-baseline ──► 03-risk-eval ──► 04-build-test ──► 05-merge-decision ──► 06-report (inline)
   (subagent, drives        (subagent,         (subagent,        (subagent,            stops worker,
    worker)                ALL groups,          drives            drives                reads all
                          single pass)          worker)           worker)               handoffs,
                                                                                         writes report)
```

`worker_id` is forwarded unchanged in every stage's own handoff from 01 through 06.

## Exit paths

- **Success**: stage 06 emits `[pylot] outcome="deps-runner complete: {merged}/{total} merged, {flagged} flagged" status=success`
- **Failure**: failing stage's blocker → orchestrator emits `[pylot] outcome="deps-runner failed at stage NN: {reason}" status=failed`
- **Blocked**: preflight failure (main does not compile) or the target repo has no devbox
  image → `[pylot] outcome="deps-runner blocked: {reason}" status=blocked`

In all cases stage 06 still writes the local report file before the marker is emitted.

## Hard Rules

1. **SEQUENTIAL ONLY** — one Task per response, each stage finishes before the next starts.
   NO parallel Task launches anywhere.
2. **NO fan-out** — stage 03 evaluates ALL dependency groups in a single cohesive pass; do
   NOT spawn one subagent per group/PR/dimension. A PR is reasoned about as a whole.
3. **Stage 01 runs inline** — context (PR list, CLAUDE.md, devbox preflight + worker spawn)
   is established here.
4. **Stage 06 runs inline** — the `[pylot] outcome=...` marker MUST come from the orchestrator.
5. **NO QUEST** — no Quest DB POST, no `127.0.0.1:4242`, no `quest.fellowship.dev`, no
   `QUEST_TOKEN`. Reporting is the local report file only.
6. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
7. **Each stage writes handoff.md before the next stage reads it**, and forwards `worker_id`
   unchanged so it stays durable through the chain.
8. **Do not skip stages** — every stage executes even if its action is "nothing to do"
   (e.g. zero candidate PRs still runs preflight and produces a report), UNLESS stage 01
   recorded `devbox_ready: false`, in which case 02-05 are skipped entirely (nothing to
   build or test without a worker) and the run goes straight to 06.
9. **resume_from reuses on-disk handoffs** — completed stages are not re-run; missing upstream
   handoff = invalid resume point, stop and report. Verify the carried-forward `worker_id` is
   still live before driving it again.
10. **Never auto-merge high risk.** Always flag for Max. **[skip ci] on all merges.**
11. **Preflight the repo devbox before spawning** (`pylot devboxes project`). A repo with no
    built image cannot be spawned — record `devbox_ready: false` and route straight to
    stage 06 without spawning.
12. **Always stop the worker in stage 06, as its first action, before writing the report.**
    A leaked worker keeps burning Fargate compute until manually stopped or reaped.
13. **A stage-level exception is a hard blocker, not a retry.** If a Task subagent for stages
    02-05 errors, times out, or exits without writing `handoff.md`, do not retry it and do not
    advance to the next stage — route straight to stage 06 using `worker_id` from the most
    recent handoff that has one, so the worker is stopped even when a stage crashes outright
    rather than failing gracefully.

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
- `shared/report-template.md` — the local report file template (stage 06)
- `shared/risk-matrix.md` — risk classification matrix + merge-decision matrix (stages 03/05)
