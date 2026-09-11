---

description: "Task list template for feature implementation"
---

# Tasks: [FEATURE NAME]

**Input**: `/specs/[###-feature-name]/` — plan.md (required), spec.md (required), research.md, data-model.md, contracts/, quickstart.md (optional)

**Tests**: OPTIONAL. Only generate test tasks if explicitly requested.

**Organization**: tasks grouped by user story so each story ships independently.

## Format

`- [ ] [TaskID] [P?] [Story?] Description with exact file path`

- `[P]` — parallelizable (different files, no blocking deps)
- `[US1]|[US2]|…` — required for user-story phase tasks; omit for setup/foundational/polish
- Sequential IDs: T001, T002, …

## Paths

- Single project: `src/`, `tests/` at repo root
- Web: `backend/src/`, `frontend/src/`
- Mobile: `api/src/`, `ios/src/` or `android/src/`

Adjust based on `plan.md`'s Structure Decision.

<!-- Replace the sample tasks below with real ones derived from plan.md + spec.md (__SPECKIT_COMMAND_TASKS__). -->

## Phase 1: Setup

- [ ] T001 Create project structure per plan
- [ ] T002 Initialize [language] project with [framework]
- [ ] T003 [P] Configure linting / formatting

---

## Phase 2: Foundational (blocks all stories)

- [ ] T004 Setup database schema + migrations framework
- [ ] T005 [P] Auth/authorization framework
- [ ] T006 [P] API routing + middleware
- [ ] T007 Base models all stories depend on

---

## Phase 3: User Story 1 — [Title] (P1) — MVP

**Independent test**: [how to verify this story alone]

- [ ] T010 [P] [US1] Tests for US1 *(if requested)* in `tests/.../`
- [ ] T012 [P] [US1] Create `[Entity]` model in `src/models/[entity].py`
- [ ] T014 [US1] Implement `[Service]` in `src/services/[service].py` (depends on T012)
- [ ] T015 [US1] Implement endpoint / feature in `src/[location]/[file].py`
- [ ] T016 [US1] Validation + error handling

**Checkpoint**: US1 fully functional and testable.

---

## Phase 4+: Additional user stories (P2, P3, …)

Repeat the Phase 3 pattern: one phase per story, each with `[USx]` label, each a self-contained slice.

## Phase N: Polish

- [ ] TXXX [P] Documentation in `docs/`
- [ ] TXXX Performance + security pass
- [ ] TXXX Run `quickstart.md` smoke test

## Dependencies

- Setup → Foundational → Stories (any order or parallel) → Polish.
- Tests (if included) must FAIL before implementation.
- Models → services → endpoints within a story.

## Notes

- `[P]` = different files, no deps. Same-file tasks are serial.
- `[US#]` maps to spec.md story IDs for traceability.
- Commit after each task or logical group.
- Stop at any checkpoint to validate a story independently.
