# Tasks: double-check re-check closes the rework loop via labels

**Input**: `specs/1953-double-check-recheck-label-loop/plan.md` + `spec.md`
**Target repo for all changes**: `fellowship-dev/dogfooded-skills`
**Pylot repo changes**: none

---

## Phase 1: Checkout dogfooded-skills

- [ ] T001 Clone or fetch `fellowship-dev/dogfooded-skills` into a local working directory
      (`/tmp/dogfooded-skills` or equivalent) using the GitHub App token (`GH_TOKEN`).
      Confirm read/write access to `skills/ops/double-check/`.

---

## Phase 2: Core change — stage 04-post re-check logic (P1, US1 + US2)

**Target file (dogfooded-skills)**: `skills/ops/double-check/stages/04-post/CONTEXT.md`

- [ ] T002 [US1] Insert re-check context detection block (before "Post the curated review comment"):
      Read `## PR / Labels` from the stage-01 handoff; set `IS_RECHECK=true` if `needs-work`
      appears in the labels list.

- [ ] T003 [US1] Replace the current "Apply the double-checked label" section with the
      three-branch label logic:
      - IS_RECHECK=true AND verdict=ready (PASS): remove `needs-work`, remove `double-checked`,
        re-add `double-checked` → loop closed
      - IS_RECHECK=true AND verdict=needs-work (FAIL): skip label changes; go to T004
      - IS_RECHECK=false (first-check): apply `double-checked` as before (unchanged path)

- [ ] T004 [US2] Add re-check FAIL comment block after the PASS label logic:
      - Idempotency guard: check existing PR comments for `<!-- pylot:recheck-fail -->` marker
        before posting; skip post if marker already exists
      - Post structured verdict comment with `<!-- pylot:recheck-fail pr=$PR repo=$REPO -->`
        header, specific remaining items from stage-02 handoff Fix List / Verdict, and
        "What to do" instructions
      - Explicitly do NOT re-toggle `double-checked` in this path

- [ ] T005 Update the outcome marker lines at the end of stage 04-post:
      - Re-check PASS: `[pylot] outcome="double-checked re-check PASS {repo}#{pr} — loop closed, cto-review re-fired" status=success`
      - Re-check FAIL: `[pylot] outcome="double-checked re-check FAIL {repo}#{pr} — needs-work retained" status=success`
      - First-check (existing): keep the current format, no change needed

---

## Phase 3: Docs update — SKILL.md exit paths (P, US1 + US2)

**Target file (dogfooded-skills)**: `skills/ops/double-check/SKILL.md`

- [ ] T006 [P] [US1+US2] Update the "Exit paths" section to document re-check outcomes alongside
      the existing first-check success/failure/blocked exits. Add:
      - Re-check PASS outcome format
      - Re-check FAIL outcome format

---

## Phase 4: PR to dogfooded-skills

- [ ] T007 Commit all changes to a feature branch in `fellowship-dev/dogfooded-skills`
      (branch name: `1953-double-check-recheck-label-loop`).

- [ ] T008 Open a PR in `fellowship-dev/dogfooded-skills` targeting `main` (or the default branch).
      PR title: `fix(double-check): re-check PASS/FAIL closes the rework loop via labels`
      PR body: reference this issue (`fellowship-dev/pylot#1953`), list the behavioral changes
      (PASS: remove needs-work + re-toggle; FAIL: structured comment), and cite the idempotency
      guard.

---

## Phase 5: Evidence on a real PR

- [ ] T009 Trigger a double-check re-check on a real test PR (or reference the next organic
      occurrence). Capture:
      - Mission log showing the three label operations (remove needs-work, remove double-checked,
        add double-checked) executing in sequence for PASS
      - Confirmation that cto-review dispatch fired automatically (no human label poke)
      - Link as evidence in the dogfooded-skills PR and the pylot issue #1953 comment

---

## Dependencies

- T001 → T002 → T003 → T004 → T005 (sequential, same file)
- T006 is parallel to T002–T005 (different file)
- T007 after T002–T006 complete
- T008 after T007
- T009 after T008 merges (or can be done on a test PR concurrently)

## Acceptance checklist (from spec SC-001 to SC-004)

- [ ] SC-001: full rework cycle completes with zero human label pokes on a real PR
- [ ] SC-002: re-check PASS log shows needs-work removal + double-checked re-toggle
- [ ] SC-003: re-check FAIL leaves needs-work in place + posts comment with `<!-- pylot:recheck-fail -->`
- [ ] SC-004: dogfooded-skills PR passes double-check (if it runs)
