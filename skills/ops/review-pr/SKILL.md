---
name: review-pr
description: Use when performing a first-pass, read-only PR review in a clean isolated context.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Task
---

# review-pr

Read-only first-pass PR review, partitioned into 3 sequential stages. Gather PR context and the
full diff (inline) → review the **whole diff in cohesion** as a single isolated-context subagent
(the critical-judgement step) → post the review comment, apply the `reviewed` label, write the
local report (inline). Never checks out code, never fixes issues, never pushes commits — that's
double-check's job.

## Purpose

The monolithic `review-pr` ran the dedup gate, context gathering, diff read, analysis,
confidence-scoring, convention check, comment post, label, and report write in one session. The
critical-judgement step (analyze + confidence-score the diff) shared a context window already
polluted by raw gh JSON, the full diff, CI output, and existing comments. This proc isolates that
judgement into one clean-context subagent that sees only the curated PR context and diff.

**The ICM win here is clean-context isolation of the review verdict — not parallelism.** A PR is
reviewed in COHESION: the entire diff, all dimensions (correctness, conventions, Closes-vs-Refs)
together in ONE review stage. There is NO per-file fan-out and NO parallel subagents.

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `pr` | yes | — | PR number (first positional arg, `$1`) |
| `repo` | yes | — | `org/repo` (second positional arg, `$2`) |

Parse from `$ARGUMENTS`: `PR=$1`, `REPO=$2`. Both required.

**Token:** set `GH_TOKEN` in the environment before running. For Pylot crews, the team's
`token_var` is used automatically.

## What it does

3-stage SEQUENTIAL ICM procedure:

| Stage | Mode | Description |
|-------|------|-------------|
| 00-context | inline | Dedup gate (exit if already `reviewed`) + gather PR metadata, conventions, existing comments, CI status, and the full diff |
| 01-cohesive-review | subagent | **Critical-judgement step.** ONE subagent reviews the whole diff in cohesion: analyze, confidence-score findings (≥80), convention compliance, Closes-vs-Refs. Clean isolated context. |
| 02-post | inline | Post structured review comment + apply `reviewed` label + write local report + emit outcome marker |

There is exactly one subagent stage (01). It is NOT split per-file or per-dimension.

## Handoff locations

All handoffs live in the repo working directory:
```
.procedure-output/review-pr/{stage}/handoff.md
```

Stage 00 writes the curated PR context + full diff. Stage 01 receives ONLY that handoff (never the
orchestrator history). Stage 02 reads both handoffs.

## Execution

### Stage 00 (inline)

Run stage 00 yourself (orchestrator context). Read CONTEXT.md:
```
skills/review-pr/stages/00-context/CONTEXT.md
```
Run the dedup gate first. If the PR already has the `reviewed` label, emit the already-complete
outcome marker and STOP — do not spawn stage 01. Otherwise gather all context + the full diff and
write the handoff to `.procedure-output/review-pr/00-context/handoff.md`.

### Stage 01 (single subagent — NO fan-out)

Spawn exactly ONE Task. Pass only the stage's input handoff path and the stage CONTEXT.md path.
Do NOT pass orchestrator history or the raw gh output you already saw. Do NOT split the diff across
multiple Tasks — the review must see the whole diff in cohesion.

Task prompt template:
```
You are running stage 01-cohesive-review of the review-pr procedure.

Read your stage instructions:
  skills/review-pr/stages/01-cohesive-review/CONTEXT.md

Your inputs:
  .procedure-output/review-pr/00-context/handoff.md

Write your output to:
  .procedure-output/review-pr/01-cohesive-review/handoff.md

Execute all steps in CONTEXT.md. Review the ENTIRE diff together in cohesion — do not fragment it
per-file. Write handoff.md before exiting.
```

Await the task before proceeding to stage 02. If it fails, emit the failure outcome marker and stop.

### Stage 02 (inline)

Run stage 02 yourself (orchestrator context). Read CONTEXT.md:
```
skills/review-pr/stages/02-post/CONTEXT.md
```
Post the comment, apply the `reviewed` label, write the local report file, and emit the
`[pylot] outcome=...` marker from the orchestrator (never from a subagent).

## Stage handoff chain

```
00-context (inline: dedup gate + context + full diff)
   │
   └─► 01-cohesive-review (single subagent, clean context, whole diff)
          │
          └─► 02-post (inline: comment + reviewed label + report + outcome marker)
```

## Exit paths

- **Already complete**: stage 00 dedup gate hits → `[pylot] outcome="already complete — reviewed label already applied" status=success` (orchestrator, inline)
- **Success**: stage 02 emits `[pylot] outcome="review-pr complete — reviewed label applied" status=success`
- **Failure**: failing stage emits `[pylot] outcome="review-pr failed at stage NN: {reason}" status=failed`

## Hard Rules

1. **SEQUENTIAL ONLY** — stages run one after another. NO parallel Task launches.
2. **Exactly one subagent stage (01)** — the whole-diff cohesive review. NO per-file fan-out, NO
   per-dimension split. The review must see the entire diff together for cross-file cohesion.
3. **Stage 00 runs inline** — dedup gate + context gathering happen in the orchestrator.
4. **Stage 02 runs inline** — the `[pylot] outcome=...` marker MUST come from the orchestrator.
5. **Never pass full orchestrator context** into the subagent — input handoff path only.
6. **Each stage writes handoff.md before the next stage reads it.**
7. **Read-only** — no `git clone`, no `git checkout`, no file modifications to the repo under
   review, no pushes. The diff comes from `gh pr diff`.
8. **Confidence threshold is 80** — never surface findings below 80. Don't lower it.
9. **NO QUEST** — reporting is the local report file only. No Quest POST, no `QUEST_TOKEN`, no
   `127.0.0.1:4242`. Operators surface the report via the mission report.
10. **Never apply `double-checked`** — only `reviewed`. The verdict is always "proceed to
    double-check"; this skill never blocks.
11. **Do not skip stages** — every stage executes (except stage 01/02 when the dedup gate exits at 00).

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, steps, output contract
