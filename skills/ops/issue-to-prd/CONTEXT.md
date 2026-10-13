# issue-to-prd — Overview

ICM procedure that turns an issue into `specs/{issue}-{slug}/spec.md`: a PRD plus the open
decisions for the owner, each with options and a recommended answer.

## Purpose
Issues arrive underspecified. This procedure catches context gaps, clarity gaps and failure
modes before an implementer starts, and it surfaces the product decisions an agent would
otherwise make silently.

## Place in the devbox workflow
1. **Spec:** this skill, then the owner decision round on its questions.
2. **Features:** `/ce-plan` (writes `specs/{issue}-{slug}/plan.md` next to the spec) →
   `/ce-work` → `/code-review` at the level the rule gives.
3. **Bugs:** usually skip this skill; a plain implementation prompt is enough.

## Architecture
Seven sequential stages. Each is atomic: defined inputs, defined outputs, no GitHub writes.
Stages 01-05 are analysis and write only `$WORK/` handoffs outside the repository. Stage 06
writes the one deliverable, the spec.

## Key invariants
- Read-only toward GitHub. The only file written in the repository is the spec.
- Stage 01b stops on a citation, never on a hunch. Doubt falls through to `prd`. A non-`prd`
  verdict becomes an owner question, never a closed or labelled issue.
- Every spec ends with `## Questions for the owner`. Recommendations are not decisions.
- Unattended runs never prompt. Attended runs ask once, record answers, and stop.
- Owner answers already recorded in a prior spec outrank anything the stages infer.

## Folder map
```
SKILL.md           — invocation and output contract
CONTEXT.md         — this file
shared/            — prd-template.md, failure-modes.md
stages/01,01b,02-06/   — CONTEXT.md per stage
stages/03/references/  — gap-checklist.md
scripts/check_spec.py  — structural check of a written spec
evals/             — contract test, fixtures, triage scenario
```
