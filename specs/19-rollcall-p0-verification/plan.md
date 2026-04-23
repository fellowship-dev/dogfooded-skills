# Plan: Rollcall P0/P1 Verification

## Approach

Single-file change: extend `skills/ops/daily-report/SKILL.md` to add a P0/P1
verification protocol subsection under Section 0 (Production Health).

No new files, no new skills — this is a behavior clarification and verification
procedure added to the existing rollcall format skill.

## Changes

### `skills/ops/daily-report/SKILL.md`

1. Rename "Section 0: Production Health" to include "(P0/P1 verification required)"
2. Add a "P0/P1 Verification Protocol" subsection immediately after the existing
   Section 0 format examples
3. Include the decision tree, curl command, output formats, and ask-filer template
4. Update Quality Rules to reference the verification requirement

## Non-Goals

- Does NOT modify fry.lead/CLAUDE.md (local pylot, out of scope for dogfooded-skills)
- Does NOT add a separate skill — stays in daily-report
- Does NOT change Section 1-4 format
