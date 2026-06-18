---
name: cto-review
description: Use when performing a CTO-level PR review — includes staging evidence gate for infra/backend PRs.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Task
---

## Purpose

Strategic CTO-level review of a single PR, partitioned into isolated stages so the critical
judgement (the whole-diff review) runs in a clean context window. Stage 01 gathers PR metadata,
the full diff, repo context, and merge state. Stage 02 reviews the WHOLE diff cohesively across
all dimensions (docs gaps, external deps, downstream/template impact, correctness, security, merge
strategy, action items) in isolated context. Stage 03 runs inline: posts the GH review comment,
applies the verdict label, merges-or-labels honoring merge state, writes the report file, and
emits the outcome marker.

This proc is **PR review ONLY**. There is no heartbeat mode.

## Arguments

| Param | Required | Default | Notes |
|-------|----------|---------|-------|
| `PR_NUMBER` | yes | — | PR number to review |
| `org/repo` | yes | — | Target repository, e.g. `fellowship-dev/booster-pack` |

Parse positionally from `$ARGUMENTS`: first token = PR number, second token = `org/repo`.
Example: `/cto-review 742 fellowship-dev/booster-pack`.

## What it does

3-stage ICM procedure (sequential):

| Stage | Mode | Description |
|-------|------|-------------|
| 01-setup | subagent | Fetch repo context, PR metadata, full diff, merge state. Short-circuit if CLOSED-not-merged or if infra/backend PR lacks staging evidence. |
| 02-review | subagent | ONE cohesive review of the whole diff across all dimensions → verdict + checklist + action items. |
| 03-synthesize-act | inline | Post GH comment, apply label, merge-or-label honoring merge state, write report file, emit outcome marker. |

Stage 02 is the isolated critical-judgement step — it receives only the setup handoff and its own
CONTEXT.md, never orchestrator history.

## Handoff locations

All handoffs live in the repo working directory:
```
.procedure-output/cto-review/{stage}/handoff.md
```

Stage 01 writes setup. Stage 02 reads only the setup handoff. Stage 03 reads both.

## Execution

### Stage 01 (subagent)

Spawn one Task. Pass only the arguments (PR number, org/repo) and the stage CONTEXT.md path.

Task prompt template:
```
You are running stage 01-setup of the cto-review procedure.

Arguments:
  PR_NUMBER = {PR}
  REPO = {org/repo}

Read your stage instructions:
  skills/cto-review/stages/01-setup/CONTEXT.md

Write your output to:
  .procedure-output/cto-review/01-setup/handoff.md

Execute all steps in CONTEXT.md. Write handoff.md before exiting.
```

After stage 01 completes, read `.procedure-output/cto-review/01-setup/handoff.md` and check
`short_circuit`:

- If `short_circuit: closed-no-merge` → skip stage 02, go straight to stage 03 (which posts
  nothing and emits the blocked/closed outcome).
- If `short_circuit: missing-staging-evidence` → **DO NOT run stage 02 or 03**. Instead, run
  these steps inline:
  1. Apply `needs-work` label:
     ```bash
     gh pr edit {PR} --repo {org/repo} --add-label "needs-work"
     ```
  2. Post rejection comment:
     ```bash
     gh pr comment {PR} --repo {org/repo} \
       --body "Missing staging evidence. Deploy to staging with \`/test-in-staging\` and include the output before requesting re-review."
     ```
  3. Emit outcome:
     ```
     ```
  Then stop — no further stages.
- Otherwise → continue to stage 02.

### Stage 02 (subagent)

Spawn one Task. Pass only the stage 01 handoff path and the stage CONTEXT.md path. Do NOT pass
orchestrator history or any prior reasoning — the review must run in clean isolated context.

Task prompt template:
```
You are running stage 02-review of the cto-review procedure.

Read your stage instructions:
  skills/cto-review/stages/02-review/CONTEXT.md

Your inputs:
  .procedure-output/cto-review/01-setup/handoff.md

Write your output to:
  .procedure-output/cto-review/02-review/handoff.md

Review the WHOLE diff cohesively across all dimensions. Write handoff.md before exiting.
```

Await stage 02 before proceeding to stage 03.

### Stage 03 (inline)

Run stage 03 yourself (orchestrator context). Read CONTEXT.md:
```
skills/cto-review/stages/03-synthesize-act/CONTEXT.md
```
Post the comment, apply the label, merge-or-label, write the report file, and emit the

## Stage handoff chain

```
01-setup ──► 02-review ──► 03-synthesize-act (inline, reads 01 + 02)
   │               ▲
   ├── short_circuit: closed-no-merge ──────────────────────► 03 (no-op)
   └── short_circuit: missing-staging-evidence ──► inline rejection (no stages 02/03)
```

## Exit paths

## Hard Rules

1. **Sequential only** — one subagent at a time, never parallel Task launches.
2. **Stage 02 is the isolated judgement step** — it receives ONLY the setup handoff + its CONTEXT.md.
3. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
4. **The whole diff is reviewed in ONE cohesive stage** — never split per-file or per-dimension.
6. **Each stage writes handoff.md before the next stage reads it.**
7. **Do not skip stages** — every stage executes, except stage 02 is skipped only on the CLOSED-no-merge short-circuit.
8. **Honor merge state** — never merge a CLOSED PR; for an already-merged PR, post the review as a post-merge note and never attempt merge.
9. **Never merge if CI is red** — even on an LGTM verdict.
10. **No Quest** — reporting is the local report file only.
11. **Staging evidence gate fires first** — if `short_circuit: missing-staging-evidence`, skip everything else and post the rejection inline. This gate cannot be bypassed.

## Reference files

- `CONTEXT.md` — architecture overview
- `shared/review-comment-format.md` — exact GH review-comment template (verbatim from the original skill)
- `shared/report-format.md` — local report-file template
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
