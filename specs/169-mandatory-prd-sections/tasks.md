# Tasks: Mandatory "smallest version" and "what this deletes" sections; second mechanism is REWORK

**Input**: `/specs/169-mandatory-prd-sections/` — plan.md, spec.md (research.md/data-model.md/contracts/quickstart.md: not applicable, no code/data/external interface)

**Tests**: Not applicable — this repo's `issue-to-prd` verification is JSON eval fixtures, not a TDD unit-test suite; a new fixture is generated as part of US1.

**Organization**: tasks grouped by user story so each story (one per skill) ships independently.

## Phase 1: Setup

- [X] T001 [P] Create `skills/ops/issue-to-prd/stages/01b-triage-challenge/output/.gitkeep` (mirrors existing stage output-dir convention, e.g. `skills/ops/issue-to-prd/stages/01-read-issue/output/.gitkeep`)

---

## Phase 2: Foundational

None — US1 (`issue-to-prd`) and US2 (`cto-review`) touch disjoint skill directories per the owner ruling (no shared paragraph); neither blocks the other's start.

---

## Phase 3: User Story 1 — issue-to-prd triages redundancy first, then states smallest version and deletions (P1) — MVP

**Independent test**: run `issue-to-prd` on a test issue that duplicates an existing mechanism — verdict names it and stops before stage 02 runs; run on a genuine-gap issue — the published PRD contains both new sections, non-templated, with every claim either cited or an Open Question.

- [X] T002 [P] [US1] Write triage verdict logic in `skills/ops/issue-to-prd/stages/01b-triage-challenge/CONTEXT.md` (new file): read stage-01 handoff, search repo for an existing mechanism serving the same need, verdict `delete-retire|close|re-scope|prd` in that priority order, non-`prd` names the mechanism and stops
- [X] T003 [US1] Insert stage `01b-triage-challenge` into the stage list in `skills/ops/issue-to-prd/SKILL.md` (lines 24-38), documenting its stop condition (stages 02-07 skipped on non-`prd` verdict)
- [X] T004 [US1] Update the "Execution" section of `skills/ops/issue-to-prd/SKILL.md` (lines 56-60) to document the new hard gate, same shape as stage 00 (depends on T003, same file)
- [X] T005 [US1] Insert `## Smallest version that works` section into `skills/ops/issue-to-prd/shared/prd-template.md` after `## Success Metrics` (before current line 12)
- [X] T006 [US1] Insert `## What this lets us delete` section into `skills/ops/issue-to-prd/shared/prd-template.md` after `## Scope` (before current line 34; depends on T005, same file)
- [X] T007 [US1] Add fill-steps for both new sections to the PRD-path steps of `skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md` (between step 6 and "Write draft", ~line 95-96): larger-than-minimal scope cites a failing case; "nothing to delete" needs a one-line reason (depends on T005, T006)
- [X] T008 [US1] Add the citation rule to the same PRD-path steps of `skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md`: every claim cites file:line or a measured number, else becomes an `## Open Questions` entry (depends on T007, same file)
- [X] T009 [US1] Update the success criteria list in `skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md` (lines 156-158) to require both new sections present and non-templated (depends on T008, same file)
- [X] T010 [P] [US1] Add `skills/ops/issue-to-prd/evals/redundant-mechanism-001.json` fixture covering a non-`prd` triage verdict, mirroring the shape of `skills/ops/issue-to-prd/evals/no-causal-contract-001.json` — note: like `skills/ops/pylot-cli/evals/checkpoint-durability-001.json`, this fixture is corpus documentation for agent judgment (stage 01b's triage logic is prose, not a deterministic algorithm), not exercised by `outcomes_contract_harness.py` (that harness covers only stage 05c's row-selection fixtures); the real verification for this stage is the live dry run in `docs/evidence/2026-09-11-issue-169-real-runs.md`

**Checkpoint**: `issue-to-prd` fully functional and independently testable — triage gate + mandatory sections + citation rule all in place.

---

## Phase 4: User Story 2 — cto-review flags redundant mechanisms and speculative generality (P2)

**Independent test**: run `cto-review` on a PR that adds a second config/gate/pin/route for an already-served need, or unused config / a one-caller abstraction — verdict is REWORK naming the specific problem.

- [X] T011 [US2] Insert new dimension `4b. Second Mechanism & Smallest Version` into `skills/ops/cto-review/stages/02-review/CONTEXT.md`, between dimension 4 (ends line 136) and dimension 5 (starts line 138)
- [X] T012 [US2] Write the "Second mechanism?" check in that dimension: second config/gate/pin/route for an already-served need → REWORK naming the mechanism to retire (depends on T011, same file)
- [X] T013 [US2] Write the "Smallest version?" check in that dimension: unused config for a choice nobody made, or a one-caller abstraction → REWORK (depends on T011, same file)

**Checkpoint**: `cto-review` fully functional and independently testable — new dimension verdicts REWORK on both trigger conditions.

---

## Phase 5: Polish & Verification

- [X] T014 [P] Run `grep -rn "Refs #\|second mechanism" skills/` and confirm no remaining instruction recommends anything but REWORK/retire for a second mechanism (SC-003)
- [X] T015 Run one real pass of `skills/ops/issue-to-prd/` on a live issue and capture the output showing both new sections, non-templated (SC-001)
- [X] T016 Run one real pass of `skills/ops/cto-review/` on a live PR and capture the output showing both new checklist rows with a verdict (SC-002)
- [ ] T017 Run `pylot skills sync --org fellowship-dev` and confirm it completes clean; note the synced version in the closing PR — **blocked**: this worker's token lacks the `admin` scope required by `pylot skills sync` (`error: forbidden — your token (source: PYLOT_BROKER_TOKEN) lacks the 'admin' scope`), and the issue's own acceptance criteria frames this check as post-merge; an owner/admin token must run it after this branch merges

## Dependencies

- Setup (T001) → User Story 1 (T002-T010) and User Story 2 (T011-T013) may proceed in either order or in parallel — disjoint files.
- Within US1: T002 is independent; T003→T004 sequential (same file); T005→T006 sequential (same file); T007→T008→T009 sequential (same file, and depend on T005/T006 existing); T010 independent.
- Within US2: T011→T012, T011→T013 sequential (same file); T012/T013 order relative to each other doesn't matter (same file, so not marked `[P]`).
- Polish (T014-T017) runs after both stories are complete.

## Parallel execution example

```
T001 [P], T002 [P] [US1], T010 [P] [US1]   — can start together (distinct new files)
T011 [US2]                                  — can start in parallel with any US1 task (disjoint skill)
```

## Implementation strategy

MVP = User Story 1 (`issue-to-prd`, P1) — it is the primary mechanism the owner ruling names first
and can ship and be verified independently of User Story 2. User Story 2 (`cto-review`, P2) is the
enforcement backstop and can follow in the same PR or a fast-follow, per the issue's acceptance
criteria (both are required before closing #169).
