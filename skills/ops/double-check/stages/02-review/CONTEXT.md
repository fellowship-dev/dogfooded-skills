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

1. Read the setup handoff. Build a mental model of what the diff changes and why.

2. **Curate the first review's findings.** Classify EACH finding as:
   - **MUST FIX** — accurate, important for correctness/security/spec compliance
   - **NICE TO HAVE** — accurate but low priority, non-blocking
   - **DISCARD** — inaccurate, irrelevant, overly pedantic, or far-fetched

   Document the classification and reason for each. A human CTO reads this to understand what the
   AI reviewers actually caught vs. what was noise.
   - If no first-review findings exist: note "No CI review comments found — reviewed diff directly".

3. **Identify new issues not caught by the first review** — correctness, edge cases, security,
   missing tests, doc/type/dep gaps. List each with the file/line and what's wrong.

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

## Curated First-Review Findings
| # | Finding | Verdict | Action |
|---|---------|---------|--------|
| 1 | {description} | MUST FIX | {what fix is needed} |
| 2 | {description} | NICE TO HAVE | {worth doing? why} |
| 3 | {description} | DISCARD | {why it's irrelevant} |
{or "No CI review comments found — reviewed diff directly"}

## New Issues (not caught by first review)
| # | Issue | File:line | Severity | Fix needed |
|---|-------|-----------|----------|------------|
| 1 | {description} | {path:line} | {must-fix/nice} | {what to do} |
{or "none"}

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
