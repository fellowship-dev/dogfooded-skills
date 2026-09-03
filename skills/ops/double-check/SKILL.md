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
GitHub auth is ambient — no token env var. The pod's `git-credential-pylot` helper and the `gh`
shim mint short-lived App installation tokens per operation, so git URLs must stay plain
(`https://github.com/<org>/<repo>.git`); inline credentials bypass the helper and expire mid-run.

## What it does

4-stage SEQUENTIAL ICM procedure (no parallel stages):

| Stage | Mode | Description |
|-------|------|-------------|
| 01-setup | subagent | Fetch PR metadata including current HEAD, classify the incoming first-review receipt (its `Head reviewed` line) as current/stale/absent, capture comments + full diff, and checkout PR branch + merge base |
| 02-review | subagent | ONE cohesive critical review in clean context: reconcile the PR's claims against the diff, verify first review's claims, find missed edge cases, check tests/docs → consolidated verdict + curated findings |
| 03-fix | subagent | Apply MUST-FIX (and worthwhile NICE-TO-HAVE) fixes, re-run tests, push — only if fixes are needed |
| 04-post | inline | Re-fetch the live head, promote only when it equals the exact 40-hex head stage 02 reviewed, or perform one clean restart; then post curated review comment and apply labels only for the matching head |

## Handoff locations

All handoffs live in the repo working directory:
```
.procedure-output/double-check/{stage}/handoff.md
```

The setup stage records the local checkout dir (`REPO_DIR`) in its handoff so the fix stage
operates on the same working tree. Each subagent stage receives only the handoffs it needs —
never the full orchestrator context.

## Execution

### Exact-head cycles (sequential subagents)

Run one Task per stage, one after another. Do NOT launch any stages in parallel. Do not start the
next stage until the current one completes. Start with `restart_count=0`. If stage 04 sees a
different full remote SHA, it stops without posting a verdict or touching labels, and the
orchestrator runs a complete conditional 01 → 02 → 03 → 04 cycle at the observed SHA with
`restart_count=1`. Stage 02 still receives only its new setup handoff: never orchestration
history. A second transition, or any unreadable live head, stops blocked.

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
Run the live claims-vs-diff and exact-head gates (`gh pr view`), then only for a matching head
post the comment and apply the label. Verify labels/comment actually landed, write the report
file, and emit the `[pylot] outcome=...` marker from the orchestrator (never from a subagent).
If stage 04 exits `3`, set `RESTART_COUNT=1` and run a new complete conditional
Stage 01 → 02 → 03 → 04 cycle at the current live head; do not pass the old
Stage 02 or Stage 03 handoff. If it exits `2`, it is terminal blocked: do not run a promotion path.

## Stage handoff chain

```
01-setup ─► 02-review ─► 03-fix ─► 04-post (inline, reads 01+02+03)
                  │                    ▲
                  └── fixes_needed:false ┘  (skip 03)
```

## Exit paths

- **First-check fail closed** (negative verdict or claims mismatch): stage 04 posts a
  `<!-- pylot:first-check-fail-closed -->` comment, removes/withholds `double-checked`, adds or
  retains `needs-work`, and creates no positive follow-on. It emits:
  `[pylot] outcome="double-check {repo}#{pr} — verdict {verdict}, double-checked withheld, needs-work retained" status=success`
- **Re-check PASS** (PR had `needs-work`, verdict=ready): stage 04 removes `needs-work`, re-toggles
  `double-checked` (remove + re-add), and emits:
  `[pylot] outcome="double-checked re-check PASS {repo}#{pr} — loop closed, cto-review re-fired" status=success`
- **Re-check FAIL** (PR had `needs-work`, verdict=needs-work): stage 04 leaves `needs-work` in place,
  does NOT re-toggle `double-checked`, posts a structured verdict comment with a
  `<!-- pylot:recheck-fail -->` marker (idempotent — skipped if marker already present), and emits:
  `[pylot] outcome="double-checked re-check FAIL {repo}#{pr} — needs-work retained" status=success`
- **First-check success**: only an explicit `ready` verdict at the exact live 40-hex head may
  apply `double-checked`; it emits:
  `[pylot] outcome="double-checked {repo}#{pr} — verdict ready, {N} findings curated, {N} fixes pushed" status=success`
- **Failure**: failing stage emits `[pylot] outcome="double-check failed at stage NN: {reason}" status=failed`
- **Blocked**: setup cannot fetch/checkout the PR (e.g. merge conflict, missing PR), the live
  head cannot be read, or a second head transition occurs →
  `[pylot] outcome="double-check blocked: {reason}" status=blocked` (a deliberate stop — `blocked`
  is its own terminal state, not a failure)

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
10. **The diff is the only evidence; the PR body is a claim.** Stage 02 reconciles every concrete
    claim in the title/body against the changed files, and stage 04 re-checks it against the live
    PR. A claim with no code behind it and no pointer to where it landed is `needs-work` —
    "intentional", "the commit message explains it", and a LOW risk tier are NOT waivers.
    `double-checked` is withheld until the body matches the diff. (pylot#2649, PR pylot#2782.)
11. **Stage 04 verifies its own side effects** — after labelling, `gh pr view` the PR and confirm
    the expected labels/comment are actually there. Reporting success on unverified side effects
    is the failure this skill exists to catch in others.
12. **Curate the first review, never re-derive it blind** — setup captures the first review's
    comments verbatim and its `Head reviewed` receipt line; stage 02 curates those findings at
    tier-scaled depth (escalate-only). No first review found → full-depth fresh review.
13. **A stale first review is historical evidence, not a blocker or current coverage** — compare
    its `head_sha` with the post-rebase PR HEAD. Continue the cohesive review against the complete
    current diff, re-check prior findings, and post a new current-head receipt. Never restart the
    whole pipeline merely because the incoming receipt is stale.
14. **Promotion binds to the final full SHA** — immediately before every verdict comment or label
    mutation, fetch `headRefOid`. The 40-character live SHA must equal the Stage 02
    `reviewed_head_sha`, fail closed. On the first mismatch restart cleanly; on a second mismatch
    or failed retrieval stop blocked. A delta inspection, file list, short SHA, or local HEAD
    never substitutes for equality. A stale or blocked run never mutates `double-checked` or
    triggers downstream automation.
15. **First-check promotion is explicitly positive only** — apply `double-checked` only when the
    reviewer verdict is exactly `ready` and bound to the exact live head. Any negative, missing,
    malformed, stale, or conflicting signal fails closed: remove/withhold `double-checked`, add or
    retain `needs-work`, and do not create CTO, FlowChad, staging, or merge follow-ons.

## Reference files

- `CONTEXT.md` — architecture overview
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
- `shared/review-comment-template.md` — curated PR comment template (stage 04)
- `shared/report-template.md` — local report file template (stage 04)
