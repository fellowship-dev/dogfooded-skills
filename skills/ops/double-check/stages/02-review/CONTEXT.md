# Stage 02: Cohesive Review (subagent — CLEAN CONTEXT, isolated critical judgement)

This is the ICM win. You run with a clean context containing ONLY the setup handoff
(PR + first review + full diff). Form ONE holistic second-pass verdict. Fresh eyes are the point —
you have NO implementation history, which prevents confirmation bias.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — PR metadata, first review (verbatim),
  changed files, full diff, local checkout dir

Do NOT request or expect orchestration history. This handoff is everything at the start of review;
before writing your verdict you must independently refresh the PR comments as described below.

## Task
Review the PR **in cohesion** — the whole diff together, all dimensions in ONE pass — and produce
a single consolidated verdict. This is NOT split per-file or per-dimension. In this one review you:

0. **Reconcile the PR's claims against the diff.** The title and body are claims; the diff is the
   only evidence. Claims with no code behind them are the defect. BLOCKING — see step 2 below.
1. **Verify the first review's claims.** For each finding in the setup handoff's "First Review",
   judge whether it is accurate against the actual diff.
2. **Find missed edge cases.** Surface correctness/security/spec issues the first review did NOT
   catch — read the diff carefully and build a mental model of what changed and why.
3. **Check tests and docs.** Does the change include/adjust tests where it should? Are docs,
   types, and deps consistent with the change?

All four are judged together as cross-cutting concerns, yielding ONE verdict.

## Steps

1. Read the setup handoff. Note the `## First-Review Receipt` section and the first review
   captured verbatim. Build a mental model of what the diff changes and why — the first review
   spares you re-deriving intent, but the DIFF remains the ground truth.

   If `Receipt status: stale`, retain the first review's findings and history, but do not trust
   them as coverage of current HEAD. Re-check every still-relevant finding against the current
   full diff and perform the normal cohesive review. Staleness never forces a pipeline
   restart and never suppresses this stage.

2. **Reconcile claims vs diff — BLOCKING, do this before curating anything.**
   Extract every *concrete, checkable* claim from the PR title and body: named files/modules,
   endpoints or routes, functions, migrations, config keys, test files and test counts,
   `Closes`/`Implements`/`Fixes` issue refs, and any staging/deploy evidence (build ids,
   `deployed_sha`, smoke results). Check each against the setup handoff's **Changed Files**
   manifest and **Full Diff**. Classify each claim:

   - **backed** — the change is present in this diff.
   - **elsewhere** — the body explicitly scopes it out, or names the specific other PR / merged
     SHA that carries it. A bare "already shipped" / "handled previously" assertion with no
     pointer is NOT `elsewhere`.
   - **unbacked** — claimed, absent from the diff, no pointer.

   **Any `unbacked` claim ⇒ `claims_reconciled: fail` ⇒ `verdict: needs-work`.** Non-waivable:
   - "The mismatch is intentional / the commit message explains it" is **not** a waiver. A body
     that describes code this diff does not contain is itself the defect — the body must be
     corrected or the code must land. Do not record it as a non-blocking observation.
   - Risk tier does not exempt it. A LOW-tier docs-only diff under a body claiming N source files
     and M new tests is precisely the case this gate exists for — a small diff makes the
     mismatch *more* suspicious, not less.
   - `Closes`/`Implements` refs count as claims: closing an issue on a diff that does not
     implement it is unbacked.
   - Staging evidence attesting to code absent from the diff is unbacked.

   Also note the inverse — substantive changes in the diff the body never mentions
   (**undisclosed**). Record them; escalate to needs-work only when they are risky or outside the
   PR's stated scope.

   If the setup handoff flags the diff as TRUNCATED, or the Changed Files manifest is missing, you
   cannot reconcile: set `claims_reconciled: unknown` and say which claims you could not check.
   Stage 04 re-checks those against the live PR.

   Be precise, not pedantic: only claims a reader could verify against the diff. Wording, tone,
   and forward-looking intent ("this unblocks X") are not claims.

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

5. **Decide tests posture.** Note whether tests should be run after fixes (and the likely stack),
   or whether tests are not applicable (e.g. deps-only / lockfile-only PR — note this explicitly).

6. **Refresh live review input before the verdict.** Long corpus/test work makes the setup comment
   snapshot stale. Fetch `gh pr view $PR --repo $REPO --json comments,headRefOid`; require its
   `headRefOid` to be the 40-character `Setup head SHA`, and include every newly created comment
   in the curation. If the read fails or head changed, write `verdict: blocked` with the reason;
   do not produce an approving verdict.

7. **Form the consolidated verdict.** One of:
   - `ready` — ready for CTO review (no MUST-FIX items, no blocking new issues, and
     `claims_reconciled` is not `fail`)
   - `needs-work` — list the specific remaining items

   `claims_reconciled: fail` forces `needs-work`. There is no combination of clean findings that
   overrides it.

8. Set `fixes_needed`:
   - `true` if there is at least one MUST-FIX finding OR a NICE-TO-HAVE you judge worth doing
     OR a new blocking issue to fix.
   - `false` if nothing actionable needs a code change (verdict can still be `ready` or `needs-work`,
     but with no fixes for stage 03 to apply).
   - An unbacked-claim failure alone does NOT set `fixes_needed: true` — stage 03 fixes code, and
     the remedy here is the author correcting the body or landing the missing code.

This stage has NO side effects — no code edits, no pushes, no comments. It only judges and records.

## Output: handoff.md

Path: `.procedure-output/double-check/02-review/handoff.md`

```markdown
# Stage 02: Cohesive Review

verdict: {ready | needs-work}
fixes_needed: {true | false}
claims_reconciled: {pass | fail | unknown}
reviewed_head_sha: {40-character Setup head SHA}

## Claims vs Diff
| Claim (from PR title/body) | Status | Evidence |
|----|--------|----------|
| {e.g. "POST /orgs/:org/skills/home handler in skills-api.mts"} | unbacked | not in the 2 changed files |
| {e.g. "18 new unit tests"} | unbacked | no test file in the diff |
| {e.g. "T040 GitHub App permission"} | elsewhere | body scopes it out as a follow-on infra PR |
| {e.g. "T049 marked done in tasks.md"} | backed | tasks.md hunk |
{one row per concrete claim — or "no checkable claims in the body"}

Undisclosed changes: {diff changes the body never mentions — or "none"}

## Intent
{1-2 sentences: does the PR deliver what it's supposed to? If claims_reconciled is fail, say so
here in one line — this text is what a human reads first.}

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
| PR title/body claims reconciled against changed files + diff ({N} claims, {N} unbacked) | read |
| {e.g. "first-review findings re-judged against diff"} | read |
| {e.g. "runtime-shape checklist re-confirmed"} | read |
{stage 03, if it runs, appends its test run as {"what":"test suite after fixes","how":"executed"}}

## Tests Posture
{stack + whether to run after fixes, OR "not applicable — deps-only/lockfile-only"}

## Fix List (for stage 03)
{ordered list of concrete fixes to apply, each tied to a finding above — or "none"}

## Verdict
{ready for CTO review — OR — needs more work: list remaining items}
```

## Success criteria
- `verdict`, `fixes_needed`, and `claims_reconciled` set explicitly
- Every concrete PR-body claim classified backed/elsewhere/unbacked in the Claims vs Diff table
- No `unbacked` claim coexists with `verdict: ready`
- Every first-review finding classified (or "none found" noted)
- New issues surfaced (or explicitly "none")
- Tests posture decided
- ONE cohesive verdict — not split per-file or per-dimension
- `reviewed_head_sha` is a full immutable remote SHA, refreshed against the live PR before the verdict

## Failure
- Setup handoff missing or `setup_ok: false` → write handoff with `verdict: blocked` and stop;
  orchestrator handles the blocked exit
