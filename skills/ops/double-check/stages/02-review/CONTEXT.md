# Stage 02: Cohesive Review (subagent — CLEAN CONTEXT, isolated critical judgement)

This is the ICM win. You run with a clean context containing ONLY the setup handoff
(PR + first review + full diff). Form ONE holistic second-pass verdict. Fresh eyes are the point —
you have NO implementation history, which prevents confirmation bias.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — PR metadata, receipt, local checkout
  dir, and the paths of the four verbatim setup artifacts below
- The setup artifacts it lists under `## Artifacts`: `pr-body.md` (author intent), `first-review.md`
  (verbatim), `changed-files.txt` (authoritative manifest) and `diff.patch` (the full diff). They
  are setup output, not orchestration history: reading them keeps the clean context. Read
  `diff.patch` in full (page through it with offsets when it is long); never judge code you
  did not read.

Do NOT request or expect orchestration history. This handoff is everything at the start of review;
before writing your verdict you must independently refresh the PR comments as described below.

## Delta mode (`review_scope: delta` in the setup handoff)

Everything outside the delta was already judged by the last verdict at the same hunks, so do not
review it again. In delta mode:

- Review `delta.patch` (the PR's current hunks for the files in `delta-files.txt`) in full, with
  `delta-range.patch` showing what changed in them since the last verdict. Read `diff.patch` only
  for context a delta hunk depends on.
- Re-check the findings the change is meant to fix: the open MUST-FIX and needs-work items in the
  latest double-check or CTO comment in `first-review.md`, and in `prior-review.md` when present.
  Each one is fixed, still open, or moot; an open MUST-FIX code item keeps the verdict at
  `needs-work`, wherever its file sits. Asks about the PR body or staging evidence are moot.
- Step 6 (live refresh) runs as usual.
- With zero delta files (a re-run after a body-only edit), only the findings re-check applies.
  A body edit alone never changes the verdict.
- Record `review_scope: delta` and the delta file count in your handoff.

`review_scope: full` (or absent) is the full review below. `carry` never reaches this stage.

## Task
Review the PR **in cohesion** — the whole diff together, all dimensions in ONE pass — and produce
a single consolidated verdict. This is NOT split per-file or per-dimension. In this one review you:

1. **Verify the first review's claims.** For each finding in the setup's `first-review.md`,
   judge whether it is accurate against the actual diff.
2. **Find missed edge cases.** Surface correctness/security/spec issues the first review did NOT
   catch — read the diff carefully and build a mental model of what changed and why.
3. **Check tests and docs.** Does the change include/adjust tests where it should? Are docs,
   types, and deps consistent with the change?

All three are judged together as cross-cutting concerns, yielding ONE verdict.

**Code decides the verdict; the PR body never does.** Use the title and body only to understand
intent. There is no claims-reconciliation step: a body that is stale, incomplete, or describes a
different revision is at most a one-line `body_note` in the handoff, never a finding, never
MUST-FIX, and never a reason for `needs-work`. On a 30-day sweep most `needs-work` verdicts came
from stale bodies on otherwise clean diffs and cost a rework each.

## Steps

1. Read the setup handoff. Note the `## First-Review Receipt` section and the first review
   captured verbatim. Build a mental model of what the diff changes and why — the first review
   spares you re-deriving intent, but the DIFF remains the ground truth.

   If `Receipt status: stale`, retain the first review's findings and history, but do not trust
   them as coverage of current HEAD. Re-check every still-relevant finding against the current
   full diff and perform the normal cohesive review. Staleness never forces a pipeline
   restart and never suppresses this stage.

2. **Check the driving issue's acceptance criteria.** For a `Closes`/`Implements`/`Fixes`
   driving issue, assess each criterion against the diff or a linked follow-up conforming to
   [the follow-up issue contract](../../references/follow-up-issue-template.md). Read the
   follow-up: it must carry the deferred criteria verbatim. A conforming transfer backs the
   closing reference; generate no finding merely because that remainder is absent from this
   diff. Operational or post-merge acceptance remains owed by the follow-up, not claimed done.
   If a criterion is neither implemented nor transferred, require completion or a conforming
   linked follow-up while retaining the closing reference (a MUST-FIX code finding).
   Never recommend downgrading the driving issue to `Refs`, including when curating a
   first-review finding that recommends it.

   If the body is stale against the diff (names files, tests, or evidence the diff does not
   carry), write one line in `body_note` and move on. It does not affect the verdict.

3. **Curate the findings — keyed by the first review's IDs when it numbered them.** Classify EACH finding as:
   - **MUST FIX** — accurate, important for correctness/security/spec compliance
   - **NICE TO HAVE** — accurate but low priority, non-blocking
   - **DISCARD** — inaccurate, irrelevant, overly pedantic, or far-fetched

   Document the classification and reason for each, keyed by the first review's IDs (`R1`, `R2`, …)
   when it numbered them. A human CTO reads this to understand what the AI reviewers actually
   caught vs. noise.
   - No first-review findings: note "No CI review comments found — reviewed diff directly".

4. **Identify new issues not caught by the first review** — correctness, edge cases, security,
   missing tests, doc/type/dep gaps. List each with the file/line and what's wrong. Give each an
   ID continuing the numbering: `D1`, `D2`, … **Depth scales with the risk tier** (#2210):
   - **LOW** — verify acceptance criteria and tests posture, spot-check the 2-3 riskiest hunks;
     no exhaustive fresh hunt on a template-following diff.
   - **MEDIUM** — full fresh hunt as before.
   - **HIGH** — full fresh hunt AND run the runtime-shape checklist against the diff
     (post-response async work, boundary return shapes, cursor math, local-vs-prod substrate
     drift, RMW races).
   You may ESCALATE the tier (never lower it) — record the new tier + reason in your handoff.

5. **Decide verification posture.** Read the owning scope contract, assess affected behavior
   and dependencies, name required checks/broad boundaries and matching reusable receipts.
   Dependencies/lockfiles are not automatically exempt. Use not-applicable only for a
   contract-backed non-runtime classification with required policy/static checks recorded.

6. **Refresh live review input before the verdict.** Long corpus/test work makes the setup comment
   snapshot stale. Fetch `gh pr view $PR --repo $REPO --json comments,headRefOid`; require its
   `headRefOid` to be the 40-character `Setup head SHA`, and include every newly created comment
   in the curation. If the read fails or head changed, write `verdict: blocked` with the reason;
   do not produce an approving verdict.

7. **Form the consolidated verdict from MUST-FIX code items only.** Count the open MUST-FIX
   items (curated first-review findings, new issues, and on a re-check the prior findings still
   open) and record the count as `must_fix_open`.
   - `must_fix_open: 0` ⇒ `verdict: ready`. **Zero MUST-FIX code items is a pass**, on a first
     check and on a re-check alike. NICE-TO-HAVE items, body staleness, missing staging evidence,
     and "no outstanding code-level items, but…" never hold the verdict at `needs-work`.
   - `must_fix_open` ≥ 1 ⇒ `verdict: needs-work`, listing exactly those items.

8. Set `fixes_needed`:
   - `true` if there is at least one MUST-FIX finding OR a NICE-TO-HAVE you judge worth doing
     OR a new blocking issue to fix.
   - `false` if nothing actionable needs a code change (verdict can still be `ready` or `needs-work`,
     but with no fixes for stage 03 to apply).

This stage has NO side effects — no code edits, no pushes, no comments. It only judges and records.

## Output: handoff.md

Path: `.procedure-output/double-check/02-review/handoff.md`

```markdown
# Stage 02: Cohesive Review

verdict: {ready | needs-work}
must_fix_open: {N — verdict is ready iff N is 0}
fixes_needed: {true | false}
body_note: {one line if the PR body is stale against the diff — or "none"; never affects the verdict}
reviewed_head_sha: {40-character Setup head SHA}
review_scope: {full | delta}

## Intent
{1-2 sentences: does the PR deliver what it's supposed to? This text is what a human reads first.}

## Implementation
{2-4 bullets: key approach, files changed grouped by area}

## Risk Tier
- tier: {your rubric assessment, or the ESCALATED tier + reason, or "unknown"}
- incoming_receipt: {current | stale | absent}; reviewed_head={sha|none}; current_head={sha}

## Curated First-Review Findings
| ID | Finding | Verdict | Action |
|----|---------|---------|--------|
| R1 | {description} | MUST FIX | {what fix is needed} |
| R2 | {description} | NICE TO HAVE | {worth doing? why} |
| R3 | {description} | DISCARD | {why it's irrelevant} |
{first-review IDs when it numbered them, else 1..N — or "No CI review comments found — reviewed diff directly"}

## New Issues (not caught by first review)
| ID | Issue | File:line | Severity | Fix needed |
|----|-------|-----------|----------|------------|
| D1 | {description} | {path:line} | {must-fix/nice} | {what to do} |
{or "none"}

## Verified (delta this stage adds to the manifest)
| What | How |
|------|-----|
| {e.g. "first-review findings re-judged against diff"} | read |
| {e.g. "runtime-shape checklist re-confirmed"} | read |
{stage 03, if it runs, appends its test run as {"what":"test suite after fixes","how":"executed"}}

## Tests Posture
{owning scope contract, required checks/broad boundaries and valid receipts; OR explicit contract-backed non-runtime reason with required static/policy checks}

## Fix List (for stage 03)
{ordered list of concrete fixes to apply, each tied to a finding above — or "none"}

## Verdict
{ready for CTO review — OR — needs more work: list remaining items}
```

## Success criteria
- `verdict`, `must_fix_open`, and `fixes_needed` set explicitly
- `verdict: ready` exactly when `must_fix_open: 0`; body staleness never changes it
- Every first-review finding classified (or "none found" noted)
- New issues surfaced (or explicitly "none")
- Tests posture decided
- ONE cohesive verdict — not split per-file or per-dimension
- `reviewed_head_sha` is a full immutable remote SHA, refreshed against the live PR before the verdict

## Failure
- Setup handoff missing or `setup_ok: false` → write handoff with `verdict: blocked` and stop;
  orchestrator handles the blocked exit
