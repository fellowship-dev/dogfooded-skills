---
name: cto-review
description: Use when performing a CTO-level PR review — includes staging evidence gate for infra/backend PRs and visual evidence gate for UI PRs.
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
| 01-setup | subagent | Fetch repo context, PR metadata, full diff, merge state. Short-circuit if CLOSED-not-merged, if an infra/backend PR lacks staging evidence, or if a UI-surface PR lacks visual evidence. Both gates search the PR body first, then comments (newest-first), and both accept `N/A` within 3 lines of their heading as the waiver. `*.d.mts` (type-declaration) files are excluded from the infra/backend necessity trigger; `*.d.ts`/`*.test.*`/`*.spec.*`/`*.stories.*`/`*.example.*`/`*.config.*` are excluded from the UI-surface trigger. Docs/test/type-only PRs are waived with a recorded rationale. |
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
     [pylot] outcome="cto-review blocked: missing staging evidence on PR #{PR}" status=blocked
     ```
  Then stop — no further stages.
- If `short_circuit: missing-visual-evidence` → **DO NOT run stage 02 or 03**. Run these inline:
  1. Apply `needs-work` label:
     ```bash
     gh pr edit {PR} --repo {org/repo} --add-label "needs-work"
     ```
  2. Post the rejection comment. It MUST name the self-serve path — this blocker is fixable by
     the factory, and a message that only says "add screenshots" is what produced 29 consecutive
     human-action comments on one PR.

     **The message must NOT contain a literal `Visual Evidence` markdown heading at column 0.**
     The gate's comment scan selects comments matching `^#{1,4}\s.*[Vv]isual\s+[Ee]vidence`, so a
     rejection comment carrying that heading would be picked up on the next run and parsed as if
     it were evidence — the gate would grade its own homework. Describe the heading in prose and
     show the waiver value indented, as below.

     ```bash
     cat > /tmp/cto-visual-block.md <<'BODY'
     Missing visual evidence. This PR changes a user-facing surface, so its Visual Evidence
     section must carry at least one embedded image — or the waiver.

     **Self-serve — do not wait for a human:**

     1. Run `/evidence-upload` to capture, upload, and embed. Capture must run on a worker
        devbox; the operator image has no browser.
     2. Or do nothing — the rework/unstick loop detects this verdict and dispatches a capture
        mission for this PR head automatically (one per head; a duplicate dispatch is a no-op).
     3. If this verdict is wrong and there is genuinely no user-facing surface, add a level-2
        heading reading `Visual Evidence` to the PR body, followed by a line reading:

            N/A — no user-facing surface

     The waiver is the literal token `N/A` within 3 lines of that heading. Embed screenshots as
     `[![alt](URL)](URL)` using assets-hosted URLs — never a branch `raw.githubusercontent.com`
     link and never a static S3 key; both rot.
     BODY
     gh pr comment {PR} --repo {org/repo} --body-file /tmp/cto-visual-block.md
     ```
     (Strip the leading 5-space indentation when writing the file — it is indentation for this
     document only, and leading whitespace would render the whole comment as a code block.)
  3. Emit outcome:
     ```
     [pylot] outcome="cto-review blocked: missing visual evidence on PR #{PR}" status=blocked
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
`[pylot] outcome=...` marker from the orchestrator (not from a subagent).

## Stage handoff chain

```
01-setup ──► 02-review ──► 03-synthesize-act (inline, reads 01 + 02)
   │               ▲
   ├── short_circuit: closed-no-merge ──────────────────────► 03 (no-op)
   ├── short_circuit: missing-staging-evidence ──► inline rejection (no stages 02/03)
   └── short_circuit: missing-visual-evidence ───► inline rejection (no stages 02/03)
```

## Exit paths

- **Success**: stage 03 emits `[pylot] outcome="cto-review PR #{N} complete — verdict={verdict}, action={merged|labeled}" status=success`
- **Failure**: failing stage emits `[pylot] outcome="cto-review failed at stage NN: {reason}" status=failed`
- **Blocked (closed)**: `[pylot] outcome="cto-review skipped: PR #{N} closed without merge" status=blocked`
- **Blocked (staging evidence)**: `[pylot] outcome="cto-review blocked: missing staging evidence on PR #{N}" status=blocked` (fires only when staging IS required AND no valid fresh evidence was found in body or comments)
- **Blocked (visual evidence)**: `[pylot] outcome="cto-review blocked: missing visual evidence on PR #{N}" status=blocked` (fires only when the diff hits a UI surface AND no embedded image and no `N/A` waiver was found in body or comments)

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
11. **Evidence gates fire first** — staging (step 5.5), then visual (step 5.6), one blocker at a
    time. On either short-circuit, skip everything else and post that gate's rejection inline.
    Neither gate can be bypassed. The visual gate's rejection MUST name the self-serve path;
    a bare "add screenshots" message is the defect it exists to fix.
12. **Scope by the verification manifest, don't assume** (#2210) — setup extracts the LAST
    `review-state v1` block; the review trusts what the manifest covers, spot-checks what it
    doesn't, treats still-open ledger findings as verdict inputs, and stage 03 re-posts the
    finalized block as valid JSON. No block found → pre-#2210 fallback (assume earlier phases
    covered code quality).

## Reference files

- `CONTEXT.md` — architecture overview
- `shared/review-comment-format.md` — exact GH review-comment template (verbatim from the original skill)
- `shared/report-format.md` — local report-file template
- `stages/NN-name/CONTEXT.md` — per-stage inputs, task, output contract
