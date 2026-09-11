# Tasks: Fix Release-Train Detection in cto-review

**Input**: `/specs/164-fix-release-train-detection/` — plan.md, spec.md, research.md, quickstart.md

**Tests**: included — this is a gate-correctness bug fix; the PRD's own merge bar is a green
fixture run plus a red-on-mutant proof, so fixtures are load-bearing, not optional.

**Organization**: tasks grouped by user story so each story ships independently.

## Phase 1: Setup

- [x] T001 Read current step 5.5 block in `/workspace/skills/ops/cto-review/stages/01-setup/CONTEXT.md:142-167` and the existing `_BuildRecordStub`/fake-`pylot`-binary patterns in `/workspace/skills/ops/cto-review/stages/01-setup/test_evidence_gate.py` and `/workspace/skills/ops/cto-review/test_resolve_merge_strategy.sh` to confirm exact anchors before editing (plan.md Constraints).

## Phase 2: Foundational (blocks all stories)

- [x] T002 In `/workspace/skills/ops/cto-review/stages/01-setup/CONTEXT.md` step 5.5 (lines ~158-167), delete `DEFAULT_BRANCH=$(gh repo view ...)` and rewrite the predicate to resolve the promote branch via `pylot teams list` → `.teams[] | select(repos matches $REPO) | .deploy.production_branch`, comparing `BASE_BRANCH` against it. No team match or no declared field → `NEEDS_EVIDENCE=false` and print `release_train_base: unconfigured (<reason>)`. Keep the block as a single delimited bash section with stable anchors (FR-001, FR-002, FR-003, FR-004).
- [x] T003 In the same block, add `release_train_base: <branch|unconfigured (<reason>)>` to the `.procedure-output/cto-review/01-setup/handoff.md` heredoc (FR-004).
- [x] T004 Delete `NECESSITY_FIXTURES` (n1-n5) and `needs_evidence()` from `/workspace/skills/ops/cto-review/stages/01-setup/test_evidence_gate.py` (dead code modeling the retired bash path filter, per PRD scope).
- [x] T005 Add a stub `pylot` binary helper to `/workspace/skills/ops/cto-review/stages/01-setup/test_evidence_gate.py` (same file as T004 — sequential), following `/workspace/skills/ops/cto-review/test_resolve_merge_strategy.sh`'s fake-binary shape (env-var-controlled JSON payload via `PYLOT_TEST_TEAMS`, `PYLOT_TEST_FAIL=1` for unreachable).

**Checkpoint**: predicate rewritten and dead code removed; fixture scaffolding ready for story tests.

---

## Phase 3: User Story 1 — Ordinary PRs are never blocked (P1) — MVP

**Independent test**: run `test_evidence_gate.py`; the `develop`-base and no-team-match fixtures below must be green while T002's predicate is in place, and red if step 5.5 is reverted to `base == default_branch`.

- [x] T006 [US1] Add fixture in `/workspace/skills/ops/cto-review/stages/01-setup/test_evidence_gate.py`: base `develop`, team declares `deploy.production_branch: main` → NOT REQUIRED (SC-001).
- [x] T007 [US1] Add fixture: no team entry matches the repo (dogfooded-skills shape) → NOT REQUIRED, rationale asserted (SC-003).
- [x] T008 [US1] Add fixture: team entry present but `deploy.production_branch` absent/null → NOT REQUIRED, `unconfigured` rationale asserted (SC-003).
- [x] T009 [US1] Add fixture: `pylot teams list` fails/unreachable (`PYLOT_TEST_FAIL=1`) → NOT REQUIRED, no traceback, exit 0 (Edge Case).

**Checkpoint**: US1 fully functional — every false-positive/no-promote-flow path proven green.

---

## Phase 4: User Story 2 — The real release train is never exempt (P2)

**Independent test**: run `test_evidence_gate.py`; the `main`-base-with-matching-team fixture must be green, and RED when step 5.5 is reverted to `base == default_branch` (which exempts this exact case on pylot since `main` isn't pylot's default branch).

- [x] T010 [US2] Add fixture: base `main`, team declares `deploy.production_branch: main`, default branch `develop` → REQUIRED (SC-002).
- [x] T011 [US2] Add fixture: base `feature-x`, team declares `deploy.production_branch: main`, default branch `main` (conventional repo, no regression case) → NOT REQUIRED.
- [x] T012 [US2] Red-on-mutant proof: temporarily restore `BASE_BRANCH == DEFAULT_BRANCH` in a scratch copy, rerun fixtures T006/T007/T010, confirm all three fail, then confirm the real file (post-T002) passes all three. Paste both RED and GREEN output in the eventual PR body — do not commit the mutant.

**Checkpoint**: US2 fully functional — false negative fixed and pinned by a red-on-mutant proof.

---

## Phase 5: Polish & cross-cutting

- [x] T013 [P] Update `/workspace/skills/ops/cto-review/SKILL.md` lines 3, 81, 95, 153, 164, 181, 207 (Hard Rule 16) — replace "base = default branch" language with the team-declared promote branch, no `main`/`master`/`develop` literals outside examples (FR-005).
- [x] T014 [P] Update `/workspace/skills/ops/cto-review/stages/02-review/CONTEXT.md:67` — same replacement, same constraint.
- [x] T015 Run `python3 /workspace/skills/ops/cto-review/stages/01-setup/test_evidence_gate.py` → exit 0, all green.
- [x] T016 Run neighboring harnesses unchanged: `test_ci_gate.py`, `test_collect_ci_evidence.py`, `test_visual_gate.py`, `test_resolve_merge_strategy.sh` (shared directory/anchors — must stay green).
- [x] T017 `grep -rn "defaultBranchRef" /workspace/skills/ops/cto-review/` → no results.
- [x] T018 `grep -rnE '\b(main|master|develop)\b' /workspace/skills/ops/cto-review/SKILL.md /workspace/skills/ops/cto-review/stages/` → fixture/example context only, no live predicate.
- [x] T019 Walk through `/workspace/specs/164-fix-release-train-detection/quickstart.md` end-to-end as the final manual check.

## Dependencies

- Setup (T001) → Foundational (T002-T005) → Stories (US1, US2 — either order, T006-T009 independent of T010-T012 but all depend on T002/T005) → Polish (T013-T019).
- T003 depends on T002 (same file, same edit region — sequential, not `[P]`).
- T012 depends on T006, T007, T010 existing first.
- T015-T019 depend on all prior phases landing.

## Notes

- `[P]` = different files, no deps. T002/T003 touch the same file region as each other — serial.
- `[US1]`/`[US2]` map to spec.md's two user stories.
- Commit after each phase checkpoint.
- MVP = US1 alone (T001-T009): eliminates the live false-positive damage (pylot PRs #3413/#3416/#3430/#3437/#3405/#3436, dogfooded-skills#167) even before the false-negative fix lands.
