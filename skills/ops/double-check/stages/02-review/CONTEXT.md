# Stage 02: Cohesive Review (subagent — CLEAN CONTEXT, isolated critical judgement)

This is the ICM win. You run with a clean context containing ONLY the setup handoff
(PR + first review + full diff). Form ONE holistic second-pass verdict. Fresh eyes are the point —
you have NO implementation history, which prevents confirmation bias.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — PR metadata, first review (verbatim),
  changed files, full diff, local checkout dir

Do NOT request or expect any other context. This handoff is everything.

## Task
Review the PR **in cohesion** — the whole diff together, all dimensions in ONE pass — and produce
a single consolidated verdict. This is NOT split per-file or per-dimension. In this one review you:

1. **Verify the first review's claims.** For each finding in the setup handoff's "First Review",
   judge whether it is accurate against the actual diff.
2. **Find missed edge cases.** Surface correctness/security/spec issues the first review did NOT
   catch — read the diff carefully and build a mental model of what changed and why.
3. **Check tests and docs.** Does the change include/adjust tests where it should? Are docs,
   types, and deps consistent with the change?

All three are judged together as cross-cutting concerns, yielding ONE verdict.

## Steps

1. Read the setup handoff. Note the `## Review State` section (risk tier + findings ledger +
   verification manifest from review-pr, #2210). Build a mental model of what the diff changes and
   why — the ledger's summary spares you re-deriving intent, but the DIFF remains the ground truth.

2. **Curate the findings — by ledger ID when Review State is present.** Classify EACH finding as:
   - **MUST FIX** — accurate, important for correctness/security/spec compliance
   - **NICE TO HAVE** — accurate but low priority, non-blocking
   - **DISCARD** — inaccurate, irrelevant, overly pedantic, or far-fetched

   Document the classification and reason for each, keyed by the ledger ID (`R1`, `R2`, …) when one
   exists. A human CTO reads this to understand what the AI reviewers actually caught vs. noise.
   - Review State `none` + no first-review findings: note "No CI review comments found — reviewed
     diff directly".

3. **Identify new issues not caught by the first review** — correctness, edge cases, security,
   missing tests, doc/type/dep gaps. List each with the file/line and what's wrong. Give each an
   ID continuing the ledger: `D1`, `D2`, … **Depth scales with the risk tier** (#2210):
   - **LOW** — verify acceptance criteria and tests posture, spot-check the 2-3 riskiest hunks;
     no exhaustive fresh hunt on a template-following diff.
   - **MEDIUM** — full fresh hunt as before.
   - **HIGH** — full fresh hunt AND confirm the runtime-shape checklist verdicts recorded in the
     ledger's `verified` manifest actually hold against the diff (post-response async work,
     boundary return shapes, cursor math, local-vs-prod substrate drift, RMW races). If the
     manifest lacks the checklist (older review), run it yourself.
   You may ESCALATE the tier (never lower it) — record the new tier + reason in your handoff.

4. **Decide tests posture.** Note whether tests should be run after fixes (and the likely stack),
   or whether tests are not applicable (e.g. deps-only / lockfile-only PR — note this explicitly).

5. **Form the consolidated verdict.** One of:
   - `ready` — ready for CTO review (no MUST-FIX items, no blocking new issues)
   - `needs-work` — list the specific remaining items

6. Set `fixes_needed`:
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
fixes_needed: {true | false}

## Intent
{1-2 sentences: does the PR deliver what it's supposed to?}

## Implementation
{2-4 bullets: key approach, files changed grouped by area}

## Risk Tier
- tier: {from Review State, or the ESCALATED tier + reason, or "unknown (no review-state)"}

## Curated First-Review Findings
| ID | Finding | Verdict | Action |
|----|---------|---------|--------|
| R1 | {description} | MUST FIX | {what fix is needed} |
| R2 | {description} | NICE TO HAVE | {worth doing? why} |
| R3 | {description} | DISCARD | {why it's irrelevant} |
{ledger IDs when Review State present, else 1..N — or "No CI review comments found — reviewed diff directly"}

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
{stack + whether to run after fixes, OR "not applicable — deps-only/lockfile-only"}

## Fix List (for stage 03)
{ordered list of concrete fixes to apply, each tied to a finding above — or "none"}

## Verdict
{ready for CTO review — OR — needs more work: list remaining items}
```

## Success criteria
- `verdict` and `fixes_needed` set explicitly
- Every first-review finding classified (or "none found" noted)
- New issues surfaced (or explicitly "none")
- Tests posture decided
- ONE cohesive verdict — not split per-file or per-dimension

## Failure
- Setup handoff missing or `setup_ok: false` → write handoff with `verdict: blocked` and stop;
  orchestrator handles the blocked exit
