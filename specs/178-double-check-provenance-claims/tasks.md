# Tasks: Reconcile Diff-Provenance Claims in double-check

**Input**: `/specs/178-double-check-provenance-claims/` — plan.md, spec.md, research.md,
data-model.md, quickstart.md

**Tests**: Not applicable — issue scope explicitly forbids a new test entry point; verification is
the manual replay in `quickstart.md`.

**Organization**: single user story (US1); no Setup/Foundational phases — the only production
artifact is one existing file, edited additively.

## Phase 1: User Story 1 — Stage 02 classifies a provenance claim (P1) — MVP

**Independent test**: run `quickstart.md` steps 1-3 (positive / negative / SHA-less replay) against
the amended file.

- [X] T001 [US1] In `/workspace/skills/ops/double-check/stages/02-review/CONTEXT.md` step 2's
      extraction sentence (currently lines 41-46), add diff-provenance/range claims as a distinct
      category, bounded by shape (a commit range other than the PR's own merge-base diff), and name
      its evidence source: `git diff --stat <cited-sha>..<setup-head-sha>` in the stage 01
      handoff's recorded `REPO_DIR` (or `gh pr diff` at both SHAs when no checkout exists).
- [X] T002 [US1] In the same file's disposition list (currently lines 47-51), add the sentence: a
      provenance claim citing no SHA, or whose range cannot be diffed, is `unbacked` (not
      `unknown`, not "not a claim"). Depends on T001 (same list, sequential).
- [X] T003 [US1] Confirm the existing `unknown` paragraph (currently lines 68-70) is untouched and
      does not blur into the new text (spec Edge Cases / research.md decision). Depends on T002.

**Checkpoint**: US1 fully functional — a provenance claim in a PR body now resolves to a named
evidence source and a `backed`/`unbacked` disposition instead of silent pass-through.

---

## Phase 2: Polish

- [X] T004 Run `quickstart.md` step 1 (positive replay): confirm the recorded live-instance
      sentence resolves `unbacked` ⇒ `claims_reconciled: fail`.
- [X] T005 Run `quickstart.md` step 2 (negative replay): confirm an ordinary claim still resolves
      `backed` via the existing manifest.
- [X] T006 Run `quickstart.md` step 3 (SHA-less replay): confirm it resolves `unbacked`, not
      `unknown`.
- [X] T007 Run `quickstart.md` step 4 (diff review): `git diff main --
      skills/ops/double-check/stages/02-review/CONTEXT.md` shows exactly one file, additive hunks
      only, taxonomy/`unknown` text byte-identical to `main`.
- [X] T008 Run `quickstart.md` step 5 (doctrine check): `grep -niE 'pylot|fellowship|[0-9]{4}'`
      over the changed hunks returns nothing.

## Dependencies

- T001 → T002 → T003 (same file, same list — strictly sequential, no `[P]` tasks in this feature).
- Phase 2 depends on all of Phase 1.

## Notes

- No `[P]` tasks: the entire feature is two adjacent edits to one file.
- No models/services/endpoints — this is a prose-only change to an agent-facing protocol file.
- Commit after Phase 1 is complete and Phase 2 has been walked through.
