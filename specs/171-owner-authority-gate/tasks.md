---

description: "Task list template for feature implementation"
---

# Tasks: Owner-Authority Gate Narrows `security` Parking

**Input**: `/specs/171-owner-authority-gate/` — plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: contract tests are explicitly required by the issue (AC-driven, not TDD-by-default) — included.

**Organization**: tasks grouped by user story (spec.md) so each story ships independently.

## Format

`- [ ] [TaskID] [P?] [Story?] Description with exact file path`

## Phase 1: Setup

- [ ] T001 Create `/workspace/skills/ops/cto-review/tests/` directory and empty `/workspace/skills/ops/cto-review/tests/owner-gate-fixtures.json` (`{"fixtures": []}` scaffold)

---

## Phase 2: Foundational (blocks all stories)

- [ ] T002 Add the five-class owner-authority classifier step to `/workspace/skills/ops/cto-review/stages/02-review/CONTEXT.md`, writing four new `handoff.md` fields: `owner_authority_class`, `owner_authority_evidence`, `owner_decision_line`, `owner_answerer` (per data-model.md)
- [ ] T003 Update blocker-table wording and the "NOT jumpy" paragraph in `/workspace/skills/ops/cto-review/stages/02-review/CONTEXT.md` (currently ~lines 64, 83) so `security` is no longer described as an unresolved hold there (depends on T002, same file)

---

## Phase 3: User Story 1 — CTO review parks only on real owner decisions (P1) — MVP

**Independent test**: replay pylot#3372 and #3408 fixtures through the new gate logic; confirm neither applies `waiting-on-owner`, and a `security`-only/class-`none` fixture reaches the merge bar.

- [ ] T004 [US1] Rewrite Step 2 gate logic in `/workspace/skills/ops/cto-review/stages/03-synthesize-act/CONTEXT.md` to OR exactly two triggers — human-applied `waiting-on-owner` label (fresh read) OR `owner_authority_class != none` from the 02-review handoff — deleting the `security` branch entirely
- [ ] T005 [US1] Update the `owner_gate_fired` field description in the `handoff.md` output template of `/workspace/skills/ops/cto-review/stages/03-synthesize-act/CONTEXT.md` to reflect the two-trigger design with no `security` option (depends on T004, same file)
- [ ] T006 [US1] Update `/workspace/skills/ops/cto-review/SKILL.md` prose (currently ~lines 38, 146, 163, 193 — procedure table cell, flowchart branch, exit-path text, Hard Rule 13) to describe the new two-trigger gate; leave the Step 3.0/3.1 vs Step 2/3 numbering drift untouched
- [ ] T007 [P] [US1] Update wording in `/workspace/skills/ops/review-pr/stages/02-post/CONTEXT.md` (currently ~lines 77, 94, 105) so `security` is described purely as classification metadata; leave the `AUTH_SURFACE`/`HAS_SEC` detector condition (~lines 86-92) byte-identical
- [ ] T008 [P] [US1] Update wording in `/workspace/skills/ops/review-pr/stages/00-context/CONTEXT.md` (currently ~lines 91, 107) so `security` is described purely as classification metadata; leave the detector logic (~lines 93-99) untouched
- [ ] T009 [P] [US1] Update wording in `/workspace/skills/ops/review-pr/SKILL.md` (currently ~lines 155-156) so `security` is described purely as classification metadata
- [ ] T010 [US1] Add the pylot#3372 (schema migration, normal review path) and pylot#3408 (credential-named file, no secret exposure) fixtures to `/workspace/skills/ops/cto-review/tests/owner-gate-fixtures.json`, both expecting `owner_authority_class: none`; add a third fixture with `security` label present, class `none`, expecting no park (depends on T001)
- [ ] T011 [US1] Write `/workspace/skills/ops/cto-review/tests/test_owner_gate_contract.py` asserting SC-001 (the #3372/#3408 fixtures never apply `waiting-on-owner`) and SC-002 (the `security`-labelled/class-`none` fixture reaches the merge bar, not a park) (depends on T010)

**Checkpoint**: US1 fully functional and testable — `security` alone no longer parks; real owner-authority matches still do.

---

## Phase 4: User Story 2 — Owner gets one closed question per park (P2)

**Independent test**: trigger a park via a taxonomy-class match; confirm the comment carries exactly one decision line and one named answerer, never the old generic sentence.

- [ ] T012 [US2] Rewrite the park-comment template in `/workspace/skills/ops/cto-review/stages/03-synthesize-act/CONTEXT.md` to always render one `**Decision needed:**` line and one `**Who can answer:**` line sourced from `owner_decision_line`/`owner_answerer`, removing the generic "carries label(s) X" sentence (depends on T005, same file)
- [ ] T013 [US2] Add one fixture per taxonomy class (`destructive-prod-data`, `spend-above-budget`, `secrets-handling`, `external-send`, `org-policy`) to `/workspace/skills/ops/cto-review/tests/owner-gate-fixtures.json`, each with a populated `owner_decision_line` and `owner_answerer` (depends on T001)
- [ ] T014 [US2] Extend `/workspace/skills/ops/cto-review/tests/test_owner_gate_contract.py` with assertions for SC-003 — every taxonomy-class fixture's rendered park comment has exactly one decision line and one named answerer, and the old generic sentence text is absent from the edited files (depends on T012, T013)

**Checkpoint**: US2 fully functional and testable — every automated park is unambiguous about what's being asked and of whom.

---

## Phase 5: User Story 3 — Human override still hard-blocks (P2)

**Independent test**: apply `waiting-on-owner` by hand with the classifier returning `none`; confirm the gate still parks and names the human as answerer.

- [ ] T015 [US3] Add a human-applied-`waiting-on-owner`/class-`none` fixture to `/workspace/skills/ops/cto-review/tests/owner-gate-fixtures.json` (depends on T001)
- [ ] T016 [US3] Extend `/workspace/skills/ops/cto-review/tests/test_owner_gate_contract.py` with an assertion for SC-004 — the human-label fixture still parks with the human named as answerer, independent of the classifier result (depends on T004, T015)

**Checkpoint**: US3 fully functional and testable — the classifier can never suppress a human-applied hold.

---

## Phase 6: Polish

- [ ] T017 [P] Register `skills/ops/cto-review/tests/test_owner_gate_contract.py` in the `tests=` heredoc list in `/workspace/.github/workflows/tests.yml` so the CI guard step passes
- [ ] T018 Add grep-based text assertions to `/workspace/skills/ops/cto-review/tests/test_owner_gate_contract.py` confirming AC1 (no site in `skills/ops/cto-review/` or `skills/ops/review-pr/` describes `security` as a hold/block) and AC3 (the five-class taxonomy text is verbatim and closed) (depends on T006, T007, T008, T009, T011)
- [ ] T019 Run `python3 skills/ops/cto-review/tests/test_owner_gate_contract.py`, the full `.github/workflows/tests.yml` test list, and `markdownlint` per `quickstart.md`; confirm all exit 0 (depends on T014, T016, T017, T018)

## Dependencies

- Setup (T001) → Foundational (T002-T003) → Stories (T004-T016, any order across stories but sequential within US1/US2's shared file) → Polish (T017-T019).
- T004/T005/T012 all edit the same file (`03-synthesize-act/CONTEXT.md`) — strictly sequential.
- T010/T013/T015 all edit the same fixtures file — sequential with each other, but each only depends on T001.
- T011/T014/T016 all edit the same test file — sequential with each other.

## Parallel execution examples

- After T002-T003: T007, T008, T009 (three different `review-pr` files) can run in parallel with T006 and with each other.
- T017 (CI registry) is independent of every other Polish task and can run any time after T011 exists.

## Notes

- 9-file scope fence (plan.md's Project Structure): no task touches a file outside that list.
- `[P]` used only for T007-T009 (three distinct, non-overlapping files) and T017 (an unrelated file); every other task shares a file with a prior task in its group and is therefore sequential.
- MVP = Phase 3 (US1, T001-T011): removes the `security` mis-trigger, the single real safety regression the issue calls out.
