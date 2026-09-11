# Tasks: Fix closingIssuesReferences Repo Predicate

**Input**: `/specs/172-fix-closing-issues-refs-predicate/` — plan.md, spec.md, research.md, quickstart.md

**Tests**: included — this is a gate-correctness bug fix; the issue's own merge bar is a
must-fail-before proof plus a green fixture run, so fixtures are load-bearing, not optional.

**Organization**: tasks grouped by user story so each story ships independently.

## Phase 1: Setup

- [ ] T001 Re-confirm current anchors before editing: `.repository.nameWithOwner` at `/workspace/skills/ops/speckit-runner/shared/pr-postcondition.sh:23`, `/workspace/skills/ops/speckit-runner/SKILL.md:53`, and the Python `jq` stub at `/workspace/skills/ops/speckit-runner/tests/pr-postcondition.test.sh:26-41` (plan.md Scale/Scope; confirmed once already during planning, re-check for drift before implementation).

---

## Phase 2: Foundational (blocks all stories)

- [ ] T002 Delete the Python `jq` reimplementation stub in `/workspace/skills/ops/speckit-runner/tests/pr-postcondition.test.sh:26-41` so the real `jq` binary on `PATH` executes the shipped predicate string (FR-004).
- [ ] T003 In `/workspace/skills/ops/speckit-runner/tests/pr-postcondition.test.sh`'s `make_fixture` (line 44-48), reshape the fixture to the real payload: `{"id","number","repository":{"id","name","owner":{"id","login"}},"url"}`, replacing the flat `"repository":{"nameWithOwner":...}` shape.
- [ ] T004 In `/workspace/skills/ops/speckit-runner/tests/pr-postcondition.test.sh`, add a wrong-repo fixture case (right issue number, different `owner.login`/`name`) and assert rejection — keep the 3 existing cases (`head-and-linkage-accepted`, `wrong-head-rejected`, `issue-linkage-remains-required`).

**Checkpoint**: test harness now executes the real predicate against a real-shaped fixture. Running it now must FAIL (old predicate + new fixture) — do not treat this as broken; it proves T002-T004 closed the blind spot. Record this red run for the must-fail-before evidence in Phase 5.

---

## Phase 3: User Story 1 — Successful runs report success (P1) — MVP

**Independent test**: run `bash /workspace/skills/ops/speckit-runner/tests/pr-postcondition.test.sh`; the `head-and-linkage-accepted` and new wrong-repo cases (T004) must be green with the corrected predicate in place, and red if reverted.

- [ ] T005 [US1] In `/workspace/skills/ops/speckit-runner/shared/pr-postcondition.sh:23`, replace `.repository.nameWithOwner == $repo` with `((.repository.owner.login + "/" + .repository.name) == $repo)` inside the existing `any(.closingIssuesReferences[]?; .number == $issue and ...)` predicate (FR-001, FR-003).

**Checkpoint**: US1 fully functional — Step 8 postcondition accepts a correctly-formed PR and rejects a same-number ref from a different repo.

---

## Phase 4: User Story 2 — Re-runs reconcile instead of duplicating (P2)

**Independent test**: hand-construct a two-PR `OPEN_PRS` JSON array (one closing issue N in-repo, one not) and confirm the Step 0 snippet in `SKILL.md` selects the correct PR via `jq -c` piped through the corrected predicate.

- [ ] T006 [US2] In `/workspace/skills/ops/speckit-runner/SKILL.md:53`, replace `.repository.nameWithOwner == $repo` with `((.repository.owner.login + "/" + .repository.name) == $repo)` in the Step 0 `EXISTING_PR` selection snippet — byte-identical predicate clause to T005 (FR-002).

**Checkpoint**: US2 fully functional — Step 0 resume/dedup gate finds the linked PR by real repo-match instead of always missing it.

---

## Phase 5: Polish & cross-cutting

- [ ] T007 Run `bash /workspace/skills/ops/speckit-runner/tests/pr-postcondition.test.sh` → all cases PASS, exit 0 (SC-001).
- [ ] T008 Must-fail-before proof: in a scratch copy, revert only `/workspace/skills/ops/speckit-runner/shared/pr-postcondition.sh:23`'s predicate to `.repository.nameWithOwner == $repo`, rerun T007's command → must FAIL. Restore the fix. Paste both outputs (red, then green) in the PR body (SC-002).
- [ ] T009 [P] `grep -rn '\.repository\.nameWithOwner' /workspace/skills/ops/speckit-runner/` → zero results (SC-003).
- [ ] T010 [P] Diff the predicate clause between `/workspace/skills/ops/speckit-runner/shared/pr-postcondition.sh` and `/workspace/skills/ops/speckit-runner/SKILL.md` to confirm T005 and T006 are byte-identical (FR-002).
- [ ] T011 `git diff --stat` → only the 3 scope-fenced files changed (plan.md Structure Decision).
- [ ] T012 Walk through `/workspace/specs/172-fix-closing-issues-refs-predicate/quickstart.md` end-to-end as the final manual check.

## Dependencies

- Setup (T001) → Foundational (T002-T004) → Stories (US1 = T005, US2 = T006, independent of each other, both depend on T002-T004 existing first) → Polish (T007-T012).
- T008 depends on T005 and T007 (needs the fix in place and the green baseline to compare against).
- T010 depends on both T005 and T006 landing.

## Notes

- `[P]` = different files/checks, no deps. T009 and T010 are independent read-only checks — parallelizable with each other, not with T007/T008 (which must run in sequence: green, then red, then restore-green).
- `[US1]`/`[US2]` map to spec.md's two user stories.
- Commit after each phase checkpoint.
- MVP = US1 alone (T001-T005 + T007): fixes the noisy Step 8 postcondition failure even before the Step 0 resume-gate fix (T006) lands, though both are one-line changes in the same predicate shape and are expected to ship together.
