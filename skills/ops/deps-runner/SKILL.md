---
name: deps-runner
description: 6-stage SEQUENTIAL ICM procedure for the deps-runner pipeline. Operator skill — spawns a repo worker devbox and drives it through scan → preflight → risk-eval → build-test → merge-decision → report. No parallelism. Resume-from-stage supported. No Quest.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Task
---

## Purpose

Dependency-PR verification and merge pipeline, partitioned into 6 sequential ICM stages:
scan/context → preflight baseline → risk-eval (single cohesive stage, ALL groups) →
build-test → merge-decision → report. Each stage runs in isolated context; the critical
judgement (risk evaluation) gets a clean-context stage of its own. Behaviorally equivalent
to the monolithic `deps-runner` skill, just stage-partitioned.

**This skill runs in the OPERATOR session** and owns its worker lifecycle. Stages that
require a repo environment (preflight, build-test) spawn and drive a repo devbox worker via
the gateway worker API (see `pylot-workers` skill). Stages that only need `gh` CLI
(scan-context, risk-eval, merge-decision, report) run inline in the operator session.

**This procedure is SEQUENTIAL. There is NO fan-out and NO parallel Task launches.** Risk
evaluation runs as ONE stage over every dependency group — never one subagent per group. The
ICM win here is clean-context isolation of the judgement step plus resume-from-stage, not
parallelism.

## Worker Setup

Stages 02-preflight-baseline and 04-build-test require a repo devbox. Spawn a worker at
the start of the procedure and stop it after stage 05:

```bash
REPO="${0:-$PYLOT_REPO}"
SPAWN_RESP=$(curl -s --max-time 90 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"repo\": \"$REPO\"}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers")
WID=$(echo "$SPAWN_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))' 2>/dev/null)
```

Use the `pylot-workers` drive loop pattern to send each repo-access stage as a prompt and
poll to idle before proceeding to the next stage. Stop the worker before stage 06-report:

```bash
curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
```

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `repo` | yes | — | Target `org/repo` (positional `$0`) |
| `container` | no | — | Ona/Gitpod container or environment name (positional `$1`) |
| `resume_from` | no | (start fresh) | Stage to resume at, e.g. `04-build-test`. Reuses on-disk handoffs from completed stages and skips them. |

Parse from `$ARGUMENTS`. Forms accepted:
- `org/repo` → fresh run
- `org/repo container-name` → fresh run with explicit container
- `org/repo container-name resume_from=04-build-test` → resume run

## What it does

6-stage SEQUENTIAL ICM procedure:

| Stage | Mode | Description |
|-------|------|-------------|
| 01-scan-context | inline | Fetch candidate dep PRs, read repo + team CLAUDE.md, resolve container, group PRs |
| 02-preflight-baseline | subagent | Verify main compiles + tests pass; record baseline; booster remote sync |
| 03-risk-eval | subagent | SINGLE stage: classify every dependency group (diff, dep type, direct usage, risk) |
| 04-build-test | subagent | Per PR: checkout+merge main, install+build, restart if runtime, run tests vs baseline |
| 05-merge-decision | subagent | Apply merge matrix per PR: auto-merge/label, write targeted tests, or flag for Max |
| 06-report | inline | Write local report file(s); release the environment; emit outcome marker |

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

### Stage 06 (inline)

Run stage 06 yourself (orchestrator context). Read CONTEXT.md:
```
.claude/skills/deps-runner/stages/06-report/CONTEXT.md
```
Write the local report file(s) and release the environment. Emit the `[pylot] outcome=...`
marker from the orchestrator (not from a subagent). **There is NO Quest POST — write the
local report file only.**

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

Stage names for `resume_from`: `02-preflight-baseline`, `03-risk-eval`, `04-build-test`,
`05-merge-decision`, `06-report`. (`01-scan-context` = a fresh run, no resume needed.)

## Stage handoff chain

```
01-scan-context (inline)
      │
      ▼
02-preflight-baseline ──► 03-risk-eval ──► 04-build-test ──► 05-merge-decision ──► 06-report (inline)
   (subagent)              (subagent,         (subagent)        (subagent)            reads all
                          ALL groups,                                                 handoffs,
                          single pass)                                                writes report)
```

## Exit paths

- **Success**: stage 06 emits `[pylot] outcome="deps-runner complete: {merged}/{total} merged, {flagged} flagged" status=success`
- **Failure**: failing stage's blocker → orchestrator emits `[pylot] outcome="deps-runner failed at stage NN: {reason}" status=failed`
- **Blocked**: preflight failure (main does not compile) → `[pylot] outcome="deps-runner blocked: preflight failed" status=blocked`

In all cases stage 06 still writes the local report file before the marker is emitted.

## Hard Rules

1. **SEQUENTIAL ONLY** — one Task per response, each stage finishes before the next starts.
   NO parallel Task launches anywhere.
2. **NO fan-out** — stage 03 evaluates ALL dependency groups in a single cohesive pass; do
   NOT spawn one subagent per group/PR/dimension. A PR is reasoned about as a whole.
3. **Stage 01 runs inline** — context (PR list, CLAUDE.md, container) is established here.
4. **Stage 06 runs inline** — the `[pylot] outcome=...` marker MUST come from the orchestrator.
5. **NO QUEST** — no Quest DB POST, no `127.0.0.1:4242`, no `quest.fellowship.dev`, no
   `QUEST_TOKEN`. Reporting is the local report file only.
6. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
7. **Each stage writes handoff.md before the next stage reads it.**
8. **Do not skip stages** — every stage executes even if its action is "nothing to do"
   (e.g. zero candidate PRs still runs preflight and produces a report).
9. **resume_from reuses on-disk handoffs** — completed stages are not re-run; missing upstream
   handoff = invalid resume point, stop and report.
10. **Never auto-merge high risk.** Always flag for Max. **[skip ci] on all merges.**
11. **Always release the environment in stage 06.** Leaked Ona environments burn credits.

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
- `shared/report-template.md` — the local report file template (stage 06)
- `shared/risk-matrix.md` — risk classification matrix + merge-decision matrix (stages 03/05)
