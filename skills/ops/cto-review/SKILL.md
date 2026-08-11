---
name: cto-review
description: Use when performing a CTO-level PR review — includes a staging evidence gate for infra/backend PRs and a non-blocking visual evidence notice for UI PRs.
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
| 01-setup | subagent | Fetch repo context, PR metadata, full diff, merge state, **all PR comments + label snapshot** (#2918), **resolve the pipeline lane** (#2996, step 5.3). Short-circuit if CLOSED-not-merged or if an infra/backend PR lacks staging evidence. The staging gate is **waived on `lane:fast`** (#2996) — the lane classifier already proved the diff touches no deployable surface and test-in-staging deliberately never ran. Visual evidence (5.6) is evaluated the same way but is a **notice, not a short-circuit**. Both checks search the PR body first, then comments (newest-first), and both accept `N/A` within 3 lines of their heading as the waiver. |
| 02-review | subagent | **Judgement layer first** (#2918): read all labels + all comments, identify and classify every blocker (resolved/unresolved). Then ONE cohesive review of the whole diff across all dimensions → verdict + checklist + action items + **receipts block**. Review depth is identical in both lanes. |
| 03-synthesize-act | inline | Post GH comment (always includes `## Checked / Found` receipts), apply label. **Step 3.0: owner gate** (#2918) — read labels fresh from GitHub; if `security` or `waiting-on-owner` present: post park comment, apply `waiting-on-owner`, emit `status=blocked`, STOP. **Step 3.1: lane merge bar** (#2996) — from the same fresh read: `lane:fast` requires `reviewed` only; everything else requires `reviewed` + `double-checked`. Otherwise: merge-or-label honoring merge state, write report file, emit outcome marker. |

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
     [pylot] outcome="cto-review blocked: missing staging evidence on PR #{PR}" status=blocked
     ```
  Then stop — no further stages.
- Otherwise → continue to stage 02.

Missing visual evidence is **not** a short_circuit and never appears here. It is carried in the
handoff as `## Visual Evidence → notice: yes` and surfaced by stage 03 as an advisory line
appended to the review comment. It does not gate the merge bar, does not apply `needs-work`, and
does not suppress any stage. See stage 01 CONTEXT.md, "Why this is a notice, not a gate".

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
`[pylot] outcome=...` marker from the orchestrator (not from a subagent).

## Stage handoff chain

```
01-setup ──► 02-review ──► 03-synthesize-act (inline, reads 01 + 02)
   │   (labels+comments│    (judgement layer: labels/comments/blockers → receipts)
   │   +lane captured) │         │
   │                   ▼         ▼
   │                        Step 3.0: Owner Gate (fresh label read) — LANE-INDEPENDENT
   │                              │
   │                              ├── security OR waiting-on-owner ──► park + status=blocked
   │                              └── clear ──► Step 3.1: lane merge bar
   │                                              ├── lane:fast ──► require `reviewed`
   │                                              └── else      ──► require `reviewed` + `double-checked`
   │
   ├── short_circuit: closed-no-merge ──────────────────────► 03 (no-op)
   └── short_circuit: missing-staging-evidence ──► inline rejection (no stages 02/03)

   (visual evidence: notice only — flows through 02/03 as an advisory line, never blocks)
```

## Exit paths

- **Success**: stage 03 emits `[pylot] outcome="cto-review PR #{N} complete — verdict={verdict}, action={merged|labeled}" status=success`
- **Failure**: failing stage emits `[pylot] outcome="cto-review failed at stage NN: {reason}" status=failed`
- **Blocked (closed)**: `[pylot] outcome="cto-review skipped: PR #{N} closed without merge" status=blocked`
- **Blocked (owner gate)**: `[pylot] outcome="cto-review parked: PR #{N} carries {label} — owner review required" status=blocked` (#2918 — fires when `security` OR `waiting-on-owner` is present at merge time; park comment + `waiting-on-owner` label applied)
- **Blocked (staging evidence)**: `[pylot] outcome="cto-review blocked: missing staging evidence on PR #{N}" status=blocked` (fires only when staging IS required AND no valid fresh evidence was found in body or comments)

## Hard Rules

1. **Sequential only** — one subagent at a time, never parallel Task launches.
2. **Stage 02 is the isolated judgement step** — it receives ONLY the setup handoff + its CONTEXT.md.
3. **Never pass full orchestrator context** into subagent Task prompts — inputs only.
4. **The whole diff is reviewed in ONE cohesive stage** — never split per-file or per-dimension.
5. **Stage 03 runs inline** — GH side effects and the `[pylot] outcome=...` marker MUST come from the orchestrator.
6. **Each stage writes handoff.md before the next stage reads it.**
7. **Do not skip stages** — every stage executes, except stage 02 is skipped only on the CLOSED-no-merge short-circuit.
8. **Honor merge state** — never merge a CLOSED PR; for an already-merged PR, post the review as a post-merge note and never attempt merge.
9. **Never merge if CI is red** — even on an LGTM verdict.
10. **No Quest** — reporting is the local report file only.
11. **The staging gate fires first and is the only evidence short-circuit** (step 5.5). On that
    short-circuit, skip everything else and post its rejection inline. It cannot be bypassed by
    prose or by verdict, and has exactly ONE mechanical waiver beyond its own path check:
    `lane:fast` (#2996), applied by the label, not by argument.
    **Visual evidence (step 5.6) is a notice, never a blocker** — it is evaluated after staging,
    recorded in the handoff, and appended by stage 03 as an advisory line. It never short-circuits,
    never applies a label, and never gates the merge bar. Its notice MUST still name the self-serve
    path; a bare "add screenshots" message is the defect it exists to fix.
12. **Scope by the verification manifest, don't assume** (#2210) — setup extracts the LAST
    `review-state v1` block; the review trusts what the manifest covers, spot-checks what it
    doesn't, treats still-open ledger findings as verdict inputs, and stage 03 re-posts the
    finalized block as valid JSON. No block found → pre-#2210 fallback (assume earlier phases
    covered code quality).
13. **Owner gate is unconditional (#2918)** — stage 03 step 3.0 reads labels fresh from GitHub
    at merge time. If `security` OR `waiting-on-owner` is present, the gate fires regardless of
    verdict, CI status, or any prose in the PR. LGTM verdict cannot override the gate. The labels
    come off only by human action. Two consecutive live bypasses (#2912, #2935) are why this rule
    exists; the model talked itself into merging both times, so the check is code, not prompt.
14. **Every verdict comment includes receipts (#2918)** — the `## Checked / Found` section (labels
    seen, comment count + last author, blockers → status) is mandatory in every comment stage 03
    posts. No silent LGTM without an enumeration of what was checked. On a fast-lane PR the
    receipts must also name the lane and the compensating controls (Step 3.1 list) — the whole
    point of the trade is that it is stated, not assumed.
15. **The lane changes the merge BAR, never the review BAR (#2996)** — `lane:fast` removes exactly
    two things: the `double-checked` label requirement, and the staging-evidence requirement. It
    removes nothing from stage 02's depth, nothing from CI, and nothing from the #2918 owner gate,
    which is lane-independent and fires identically in both lanes. A missing `double-checked` on a
    `lane:fast` PR is the expected state — never `needs-work` it, never ask for a double-check,
    never dispatch one. The lane is read from a FRESH GitHub label read at merge time; a PR with no
    lane label is treated as `lane:staging`. Fast is opt-in, never inferred.
16. **The fast lane does not touch prod's gate (#2996)** — it skips the PRE-MERGE staging deploy,
    not the release train. `scripts/ci-release-gate.sh` still runs the unscoped full corpus before
    anything reaches production. A fast-lane merge is a merge to develop; prod is still gated.

## Reference files

- `CONTEXT.md` — architecture overview
- `shared/review-comment-format.md` — exact GH review-comment template (verbatim from the original skill)
- `shared/report-format.md` — local report-file template
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
