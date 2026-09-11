# Implementation Plan: Mandatory "smallest version" and "what this deletes" sections; second mechanism is REWORK

**Branch**: `169-mandatory-prd-sections` | **Date**: 2026-09-11 | **Spec**: `specs/169-mandatory-prd-sections/spec.md`

## Summary

No compiled code — two skills' markdown instruction files gain mandatory structure.
`issue-to-prd` gets a triage stage verdicting DELETE/RETIRE, CLOSE, RE-SCOPE, or PRD before
drafting, plus two new PRD sections and a citation rule. `cto-review` gets a checklist dimension
verdicting REWORK for a second mechanism or speculative generality. Each skill's edit is
self-contained — no shared paragraph (owner ruling).

**Runtime**: markdown parsed by agents at mission time, not compiled code. **Testing**:
`issue-to-prd/evals/*.json` fixtures; `cto-review` has none for stage 02 today.

## Design

| Component | File(s) : line | Change |
|---|---|---|
| Triage stage | `issue-to-prd/stages/01b-triage-challenge/CONTEXT.md` (new) | Reads stage-01 handoff, searches repo for an existing mechanism serving the same need. Verdict `delete-retire\|close\|re-scope\|prd` in that order. Non-`prd` names the mechanism and stops (stages 02-07 skipped) — same hard-gate shape as stage 00. Inserted after `01-read-issue/`, mirrors the skill's `05b`/`05c` letter-suffix pattern. |
| Stage list + exit path | `issue-to-prd/SKILL.md:24-38,56-60` | Document the new gate and its stop condition. |
| PRD sections | `issue-to-prd/shared/prd-template.md:12,34` | Insert `## Smallest version that works` before line 12 (after Success Metrics); `## What this lets us delete` before line 34 (after Scope). |
| Fill + citation rule | `issue-to-prd/stages/06-ask-or-structure/CONTEXT.md:95-96,156-158` | New fill-steps between step 6 and "Write draft": larger-than-minimal scope cites a failing case; "nothing to delete" needs a one-line reason; every claim cites file:line/measured number else becomes an Open Question. Success criteria gets a non-templated-sections bullet. |
| Reviewer dimension | `cto-review/stages/02-review/CONTEXT.md:136-138` | New dimension `4b. Second Mechanism & Smallest Version` between dimension 4 and 5 (letter-suffix, no renumbering): **Second mechanism?** — second config/gate/pin/route for an already-served need → REWORK naming what to retire. **Smallest version?** — unused config or one-caller abstraction → REWORK. |

Verdict table (`cto-review/stages/02-review/CONTEXT.md:150-158`) and
`shared/review-comment-format.md` are unchanged — REWORK already exists; only its trigger set grows.

## Constitution Check

This repo's `.specify/memory/constitution.md` is unfilled template defaults; the operative
constitution is fellowship-dev/pylot `docs/principles.md` XI-XIII, which this feature implements.
Gate: each skill's diff stays inside its own directory (principle IX) — no shared file between
`issue-to-prd` and `cto-review`. No violations to justify.

## Non-Goals

- No gateway/automation enforcement (pylot sibling territory) — skill-instruction text only.
- No change to `shared/review-comment-format.md` or the REWORK verdict table.

## Verification Plan

1. One real `issue-to-prd` run on a live issue shows both new sections, non-templated (SC-001).
2. One real `cto-review` run on a live PR shows both new checklist rows with a verdict (SC-002).
3. `grep -rn "second mechanism" skills/` shows no instruction recommending anything but
   REWORK/retire (SC-003).
4. `pylot skills sync --org fellowship-dev` completes clean after merge (SC-004) — requires an
   admin-scoped token this worker's token lacks; deferred to post-merge, tracked as T017.
