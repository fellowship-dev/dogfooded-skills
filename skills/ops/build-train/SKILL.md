---
name: build-train
description: Use when batching multiple GitHub issues into one build branch with concurrent subagent builds.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Task
---

# build-train

Batch-execute multiple issues into a single build branch. Stage 01 plans the dependency order;
stage 02 launches parallel build subagents in waves — concurrent where builds are independent,
sequential where one build depends on another's output. Stage 03 merges all PRs into the build
branch, stage 04 opens one final PR to the default branch (which runs the review pipeline once).

## Purpose

Convert the monolithic `build-train` skill into an ICM procedure. The monolith dispatched workers
in a single long-lived session; by the merge phase its context carried every worker prompt and
log, degrading conflict-resolution judgement. This proc isolates each phase into a focused
subagent and — critically — replaces the serial "spawn one worker, wait, spawn next" loop with a
**dependency-graph wave scheduler**: builds with no unmet dependency run as concurrent Task
subagents; dependent builds wait for their prerequisite's handoff.

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `repo` | yes | — | `org/repo`, first positional arg |
| `--issues` | yes | — | Comma-separated issue numbers, e.g. `10,14,15,16` |
| `--branch` | no | `build/YYYY-MM-DD` | Build branch name; `-2` suffix appended if it exists |

Parse from `$ARGUMENTS`.

## What it does

6-stage ICM procedure:

| Stage | Mode | Description |
|-------|------|-------------|
| 00-setup | inline | Default branch, create build branch + label, read all issues |
| 01-plan-order | subagent | Read issue bodies, derive dependency graph, emit build waves |
| 02-build-fanout | subagent (PARALLEL) | Fan out builds wave-by-wave: parallel within a wave, sequential across edges. Each build = one Task worker producing a PR; verify + fix base/label |
| 03-merge-chain | subagent | Merge each build-train PR into the build branch, resolve conflicts |
| 04-final-pr | subagent | Open one final PR build branch → default branch (no build-train label) |
| 05-report | inline | Write report, emit outcome marker |

## Handoff locations

```
.procedure-output/build-train/{stage}/handoff.md
```

Stage 02 additionally writes one sub-handoff per build:
```
.procedure-output/build-train/02-build-fanout/builds/{issue}.md
```

Stage 00 writes the root context (repo, default branch, build branch, issue manifest). All
subagent stages receive only the handoffs they need — never the full orchestrator context.

## Execution

### Stage 00 (inline)

Run yourself. Read CONTEXT.md:
```
.claude/skills/build-train/stages/00-setup/CONTEXT.md
```
Write handoff to `.procedure-output/build-train/00-setup/handoff.md`.

### Stage 01 (subagent)

Spawn one Task. Pass the 00-setup handoff path + stage CONTEXT.md path only.

### Stage 02 (subagent — internally PARALLEL, wave scheduler)

Spawn ONE Task for the fan-out stage. That stage's CONTEXT.md drives the wave loop: it reads the
build order from stage 01, then for each wave launches all of that wave's builds as concurrent
Task workers in a SINGLE response and does NOT wait between them within the wave; it waits for the
whole wave before starting the next. Builds joined by a sequential edge land in later waves.

Task prompt template (used for every subagent stage):
```
You are running stage {NN}-{name} of the build-train procedure.

Read your stage instructions:
  .claude/skills/build-train/stages/{NN}-{name}/CONTEXT.md

Your inputs:
  {only the input handoff paths this stage's CONTEXT.md lists}

Write your output to:
  .procedure-output/build-train/{NN}-{name}/handoff.md

Execute all steps in CONTEXT.md. Write handoff.md before exiting.
```

### Stages 03 → 04 (sequential subagents)

For each, spawn one Task. Pass only the handoffs that stage's CONTEXT.md lists as inputs. Do not
start the next stage until the current completes. On stage failure, emit the failure marker and
stop only if the failure is unrecoverable (see Exit paths).

### Stage 05 (inline)

(never from a subagent).

## Stage handoff chain

```
00 ─► 01 ─► 02 ─► 03 ─► 04 ─► 05 (inline, reads all)

02 internal wave fan-out:
   wave 1: [build A] [build B] [build C]   ← concurrent Task subagents
              │         │         │
              └────── all join ───┘
   wave 2: [build D depends on A] [build E depends on B,C]   ← concurrent
              │                        │
              └──────── all join ──────┘
   wave 3: [build F depends on D] ...
```

## Exit paths

Per-build failures inside stage 02 do NOT fail the train — the failed issue is skipped and the
train proceeds (skip-rather-than-break). The train only fails if zero builds succeed.

## Hard Rules

1. **Stage 02 builds within a wave MUST launch in parallel** — all of a wave's Task calls in one response, no waiting between them.
2. **Respect sequential edges** — a build whose dependency is unmet is held to a later wave; never launch it before its prerequisite's sub-handoff exists.
3. **Worker prompts MUST specify `--base $BUILD_BRANCH`** — primary instruction, repeated twice in the prompt.
4. **Verify and fix** every PR after its build worker completes — change base branch and add the `build-train` label if the worker got it wrong.
5. **Final PR has NO `build-train` label** — it enters the normal review pipeline.
6. **Never force push** the build branch.
7. **Skip rather than break** — a failed build or unmergeable PR is skipped and logged; the train continues.
8. **One build-train per repo at a time** — stage 00 checks for existing `build/*` branches before starting.
9. **SCOPE LOCK** — each worker works only its assigned issue, nothing else.
11. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
12. **Each stage writes handoff.md before the next reads it.** No stage skipped (execute even if action is "nothing to do").

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
