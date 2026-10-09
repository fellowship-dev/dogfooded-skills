# Tasks: Fix pylot-cli Dispatch Prompt-Size Budget Doc

**Input**: `/specs/198-fix-dispatch-prompt-budget/` — plan.md, spec.md (required); research.md,
quickstart.md (optional); data-model.md/contracts/: not applicable, no entities or external
interface — pure prose edit to one file.

**Tests**: Not applicable — doc-only change; verification is manual diff/grep inspection plus
non-blocking `markdownlint-cli2`, per spec.md's Testing Strategy.

**Organization**: single user story (P1); no Setup or Foundational phase — no project
initialization, schema, or shared framework applies to a one-file prose edit.

## Phase 1: Setup

None — no project structure, dependencies, or scaffolding to initialize for a single-file doc fix.

---

## Phase 2: Foundational

None — nothing else depends on this change; it has no shared framework to stand up first.

---

## Phase 3: User Story 1 — Dispatcher trusts the documented budget (P1) — MVP

**Independent test**: read `skills/ops/pylot-cli/SKILL.md`'s Dispatch section; confirm it states
exactly 4 one-line dispatch-contract rules, with prompt size ~2560 bytes.

- [ ] T001 [US1] In `skills/ops/pylot-cli/SKILL.md`'s Dispatch section (lines 26-40), reformat the
  `/skill` prefix rule (currently prose at lines 35-37) and the `team.role` rule (currently prose at
  lines 38-40) into one line each, keeping the existing `pylot dispatch` example (lines 28-31) and
  cross-org guidance (lines 42+) untouched.
- [ ] T002 [US1] In `skills/ops/pylot-cli/SKILL.md` line 33, replace "Prompt limit: 4 KB — put full
  specs in issue comments." with a one-line rule stating ~2560 bytes (depends on T001, same file).
- [ ] T003 [US1] In `skills/ops/pylot-cli/SKILL.md`'s Dispatch section, add a 4th one-line no-secrets
  rule, adapted from the existing Preflight-and-dispatch wording ("the task contract is
  self-contained, contains no secrets...", line 217) — per research.md, do NOT copy the wording from
  `## GitHub Auth Through the CLI` (lines 629-640) (depends on T002, same file).

**Checkpoint**: Dispatch section states exactly 4 rule lines, one per rule; prompt-size line reads
~2560 bytes; US1 fully satisfied and independently verifiable.

---

## Phase 4: Polish & Verification

- [ ] T004 [P] Run `git diff` and confirm it touches only `skills/ops/pylot-cli/SKILL.md`, only
  within the Dispatch section (SC-001).
- [ ] T005 [P] Run `grep -n "Secrets: never in prompts or payloads" skills/ops/pylot-cli/SKILL.md`
  and confirm the `## GitHub Auth Through the CLI` sentence is byte-for-byte unchanged (SC-003).
- [ ] T006 Run `npx markdownlint-cli2 skills/ops/pylot-cli/SKILL.md` — warnings only, non-blocking.
- [ ] T007 Walk through `quickstart.md`'s manual verification steps end to end.

## Dependencies

- No Setup/Foundational tasks. User Story 1 (T001-T003) is the only story; Polish (T004-T007)
  runs after it completes.
- T001 → T002 → T003: sequential, same file (`skills/ops/pylot-cli/SKILL.md`).
- T004 and T005 are independent read-only checks and may run in parallel; T006 and T007 follow.

## Parallel execution example

```
T004 [P], T005 [P]   — independent read-only verification, can run together after T003
```

## Implementation strategy

MVP = User Story 1 (T001-T003) — the entire feature is one user story; there is no smaller or
larger slice. Ship T001-T003 together as a single commit (same file, sequential edits), then run
Polish (T004-T007) to verify before opening the PR.
