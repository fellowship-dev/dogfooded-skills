---
name: double-check
description: Use when performing a standalone PR double-check in a clean context — review, fix, and post.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Task
---

# double-check

## Purpose

Standalone second-pass PR review, stage-partitioned into an ICM procedure. Fetch the PR + the
first review + the diff and check it out (setup), then run ONE cohesive critical-judgement
review in a clean context (verify the first review's claims, find missed edge cases, and check
tests/docs together → a single consolidated verdict), then apply fixes and re-run tests if
needed (fix), then post the curated comment, apply the `double-checked` label, and write the
report (post). Behaviorally equivalent to the original `double-check` skill, just isolated so the
judgement step is not polluted by the orchestrator's history.

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `pr` | yes | — | PR number, e.g. `742` |
| `repo` | yes | — | `org/repo`, e.g. `fellowship-dev/booster-pack` |

Parse from `$ARGUMENTS`: first token is `pr`, second is `repo`.
`GH_TOKEN` must be set in the environment before running (the team's `token_var` for Pylot crews).

## What it does

4-stage SEQUENTIAL ICM procedure (no parallel stages):

| Stage | Mode | Description |
|-------|------|-------------|
| 01-setup | subagent | Fetch PR metadata, CI status, existing review comments, full diff; checkout PR branch + merge base |
| 02-review | subagent | ONE cohesive critical review in clean context: verify first review's claims, find missed edge cases, check tests/docs → consolidated verdict + curated findings |
| 03-fix | subagent | Apply MUST-FIX (and worthwhile NICE-TO-HAVE) fixes, re-run tests, push — only if fixes are needed |
| 04-post | inline | Detect re-check context (needs-work in labels), post curated review comment, apply labels to close the pipeline loop (re-check) or signal completion (first-check), write local report file, emit outcome marker |

## Handoff locations

All handoffs live in the repo working directory:
```
.procedure-output/double-check/{stage}/handoff.md
```

The setup stage records the local checkout dir (`REPO_DIR`) in its handoff so the fix stage
operates on the same working tree. Each subagent stage receives only the handoffs it needs —
never the full orchestrator context.

## Execution

### Stages 01 → 03 (sequential subagents)

Run one Task per stage, one after another. Do NOT launch any stages in parallel. Do not start the
next stage until the current one completes.

Each Task prompt must be self-contained:
- Include only the stage's input handoff paths
- Include the path to the stage's CONTEXT.md
- Pass `pr` and `repo` values
- Do NOT pass orchestrator history or prior reasoning

Task prompt template:
```
You are running stage {NN}-{name} of the double-check procedure.

PR: {pr}    REPO: {repo}

Read your stage instructions:
  skills/double-check/stages/{NN}-{name}/CONTEXT.md

Your inputs:
  {list only the input handoff paths from that stage's CONTEXT.md}

Write your output to:
  .procedure-output/double-check/{NN}-{name}/handoff.md

Execute all steps in CONTEXT.md. Write handoff.md before exiting.
```

Stage gating:
- Stage 02 is the isolated critical-judgement step. Its prompt MUST carry only the setup handoff
  (PR + first review + diff) — nothing else. This is the clean-context window the whole proc exists for.
- After stage 02, read its handoff. If `fixes_needed: false`, SKIP stage 03 (no fixes to apply)
  and go straight to stage 04. Otherwise run stage 03.

### Stage 04 (inline)

Run stage 04 yourself in the orchestrator context — do NOT spawn a Task. Read CONTEXT.md:
```
skills/double-check/stages/04-post/CONTEXT.md
```
Post the comment, apply the label, write the report file, and emit the `[pylot] outcome=...`
marker from the orchestrator (never from a subagent).

## Stage handoff chain

```
01-setup ─► 02-review ─► 03-fix ─► 04-post (inline, reads 01+02+03)
                  │                    ▲
                  └── fixes_needed:false ┘  (skip 03)
```

## Exit paths

- **Re-check PASS** (PR had `needs-work`, verdict=ready): stage 04 removes `needs-work`, re-toggles
  `double-checked` (remove + re-add), and emits:
  `[pylot] outcome="double-checked re-check PASS {repo}#{pr} — loop closed, cto-review re-fired" status=success`
- **Re-check FAIL** (PR had `needs-work`, verdict=needs-work): stage 04 leaves `needs-work` in place,
  does NOT re-toggle `double-checked`, posts a structured verdict comment with a
  `<!-- pylot:recheck-fail -->` marker (idempotent — skipped if marker already present), and emits:
  `[pylot] outcome="double-checked re-check FAIL {repo}#{pr} — needs-work retained" status=success`
- **First-check success**: stage 04 applies `double-checked` label and emits:
  `[pylot] outcome="double-checked {repo}#{pr} — verdict {ready|needs-work}, {N} findings curated, {N} fixes pushed" status=success`
- **Failure**: failing stage emits `[pylot] outcome="double-check failed at stage NN: {reason}" status=failed`
- **Blocked**: setup cannot fetch/checkout the PR (e.g. merge conflict, missing PR) →
  `[pylot] outcome="double-check blocked: {reason}" status=blocked`

## Hard Rules

1. **SEQUENTIAL ONLY** — one Task per stage, run one after another. NO parallel Task launches, ever.
2. **The review is ONE cohesive stage** — do NOT split stage 02 into per-file or per-dimension
   subagents. Correctness, edge cases, tests, docs, deps, and security are judged together in a
   single verdict.
3. **Stage 02 gets a clean context** — only the setup handoff (PR + first review + diff). Never
   pass orchestrator history into it.
4. **Stage 04 runs inline** — the `[pylot] outcome=...` marker MUST come from the orchestrator.
5. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
6. **Each stage writes handoff.md before the next stage reads it.**
7. **Do not skip stages** except stage 03 when `fixes_needed: false` (an explicit, allowed skip).
8. **NO Quest.** Reporting is the local report file only — no Quest POST, no `127.0.0.1:4242`,
   no `quest.fellowship.dev`, no `QUEST_TOKEN`.
9. **Apply labels only after the comment posts successfully** (stage 04). On re-check PASS,
   remove `needs-work` BEFORE re-adding `double-checked` — this is the structural loop-break.
   On re-check FAIL, do NOT touch labels or re-toggle `double-checked`.

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
- `shared/review-comment-template.md` — curated PR comment template (stage 04)
- `shared/report-template.md` — local report file template (stage 04)
