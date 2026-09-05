---
description: "Task list for issue-to-prd nonce-keyed outcome marker migration (pylot#3277)"
---

# Tasks: issue-to-prd nonce-keyed outcome markers

**Input**: `/workspace/specs/3277-issue-to-prd-nonce-marker/` — plan.md, spec.md, research.md,
quickstart.md

**Tests**: None generated — no automated test suite in this repo (see plan.md Technical Context).
Verification is the grep-based checklist in `quickstart.md`, run as Polish-phase tasks below.

**Organization**: tasks grouped by user story (spec.md). US1 and US3 share one file and are
sequential; US2 is a different file and can run in parallel with either.

## Phase 1: Setup

- [ ] T001 Confirm baseline defect: run
      `grep -rn 'pylot\] outcome=' skills/ops/issue-to-prd/` from `/workspace` and record that it
      currently returns non-zero hits (the bare form still present) before any edit.

---

## Phase 2: User Story 1 — Questions-path run records its real outcome (P1) — MVP

**Independent test**: `grep -n 'PYLOT_OUTCOME_NONCE' /workspace/skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md` shows the questions-path exit line using the variable form.

- [ ] T002 [US1] In
      `/workspace/skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md` line 20, replace
      the bare-form exit line with the nonce-keyed grammar
      (`[pylot:$PYLOT_OUTCOME_NONCE] outcome="questions posted" status=success`), preserving the
      existing outcome phrase and status word exactly.

**Checkpoint**: `grep -n 'status=success' .../06-ask-or-structure/CONTEXT.md` still matches; the
questions-path exit line now carries the nonce variable.

---

## Phase 3: User Story 2 — Guard-abort run records its real outcome (P2)

**Independent test**: `grep -n 'PYLOT_OUTCOME_NONCE' /workspace/skills/ops/issue-to-prd/stages/00-automation-guard/CONTEXT.md` shows the abort exit line using the variable form.

- [ ] T003 [P] [US2] In
      `/workspace/skills/ops/issue-to-prd/stages/00-automation-guard/CONTEXT.md` line 58, replace
      the bare-form exit line with the nonce-keyed grammar, preserving the existing outcome phrase
      and status word exactly.

**Checkpoint**: `grep -n 'status=success' .../00-automation-guard/CONTEXT.md` still matches; the
guard-abort exit line now carries the nonce variable.

---

## Phase 4: User Story 3 — A parked, unanswered issue is not re-asked (P1)

**Independent test**: the three conditions and the no-write exit are each named as explicit prose
in the new guard section, in `06-ask-or-structure/CONTEXT.md`'s existing table/imperative voice.

- [ ] T004 [US3] In
      `/workspace/skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md`, add a dedup-guard
      section before the "If questions → exit early" steps (depends on T002 — same file), stating,
      as prose mirroring `stages/07-publish/CONTEXT.md`'s precondition style and
      `stages/05b-prototype-gate/CONTEXT.md` § P's manual `gh`-read style: check (1) the
      `open-questions` label is present, AND (2) a prior bot-authored question comment exists, AND
      (3) no later comment from a non-bot author exists → then post nothing, apply no label, and
      exit success with a phrase naming the skip (using the nonce-keyed marker from T002).

**Checkpoint**: `grep -n 'open-questions' .../06-ask-or-structure/CONTEXT.md` shows both the
existing label-apply line and the new guard's label-present condition.

---

## Phase 5: Polish — verification (run `quickstart.md` verbatim)

- [ ] T005 Run `grep -rn 'pylot\] outcome=' skills/ops/issue-to-prd/` from `/workspace` — expect
      zero hits (quickstart.md check 1).
- [ ] T006 Run `grep -rn 'PYLOT_OUTCOME_NONCE' skills/ops/issue-to-prd/` from `/workspace` — expect
      exactly two hits, one per migrated file (quickstart.md check 2).
- [ ] T007 Run `grep -rn 'pylot:[0-9a-fA-F]' skills/ops/issue-to-prd/` from `/workspace` — expect
      zero hits, confirming no literal nonce was introduced (quickstart.md check 3).
- [ ] T008 Run `grep -n 'status=success' <both CONTEXT.md files>` — expect one match in each
      (quickstart.md check 4).
- [ ] T009 Confirm `git diff --stat origin/main...HEAD -- skills/` lists exactly the two in-scope
      files (quickstart.md check 6).
- [ ] T010 Confirm `git diff --stat origin/main...HEAD -- <the other 12 skill dirs>` produces no
      output (quickstart.md check 7).

---

## Phase 6: Scaffolding removal (mandatory final step — nothing ships after this but the two files)

- [ ] T011 Paste the essentials of `plan.md`, `spec.md`, and this `tasks.md` into the eventual PR
      body (so the design record survives even though the files themselves do not ship).
- [ ] T012 Delete `/workspace/.specify/`, `/workspace/.claude/commands/speckit.*.md`, and
      `/workspace/specs/3277-issue-to-prd-nonce-marker/`, then `git add -A` and commit as the last
      commit on this branch, so the shipped diff contains only the two `CONTEXT.md` files.
- [ ] T013 Run `git diff --stat origin/main...HEAD -- .specify .claude/commands specs` from
      `/workspace` — expect no output (quickstart.md check 8), confirming no scaffolding shipped.

## Dependencies

- T001 (baseline) before T002–T004.
- T002 before T004 — same file, sequential.
- T003 is `[P]` — different file, no dependency on T002/T004.
- T005–T010 (Polish) after T002–T004 all complete.
- T011–T013 (scaffolding removal) last — only after T005–T010 all pass.

## Notes

- No `[P]` on T002/T004 — both touch `06-ask-or-structure/CONTEXT.md`.
- This tasks.md itself is deleted in T012; it does not ship.
- Reporting hazard: when executing these tasks and reporting results, describe the old marker form
  descriptively or keep literal examples fenced — never let the bare failure token land as prose in
  a mission report.
