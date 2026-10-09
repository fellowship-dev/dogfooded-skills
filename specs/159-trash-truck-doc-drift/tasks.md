# Tasks: Trash Truck Doc Drift Correction

**Input**: `/workspace/specs/159-trash-truck-doc-drift/` — plan.md, spec.md (required);
research.md, data-model.md, quickstart.md (available). No `contracts/` (internal doc-only).

**Tests**: No test tasks generated — not TDD; the one existing eval
(`test_retirement_contract.py`) is unchanged and only re-run for verification.

**Organization**: One phase per user story; each story edits disjoint prose and is
independently verifiable. The plan doc (`docs/plans/2026-09-05-001-refactor-trash-truck-
retirement-plan.md`) and `SKILL.md` each receive edits from more than one story — those
edits are explicitly sequenced (never `[P]`) to avoid clobbering.

## Phase 1: Setup

- [ ] T001 Run baseline: `python3 skills/ops/trash-truck/evals/test_retirement_contract.py`
  (expect pass) and `grep -rc "evidence cutoff" --include=*.md .` (expect 5) before any edit.

*(No Foundational phase — no shared schema/framework/model work; stories touch disjoint prose.)*

---

## Phase 2: User Story 1 — Honest approval-binding claim (P1) — MVP

**Independent test**: `grep -n "evidence cutoff" skills/ops/trash-truck/references/candidate-packet.md docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md` shows only the two correct/untouched mentions (packet `:113`), none in the binding sentence or KTD5.

- [ ] T002 [P] [US1] Edit `skills/ops/trash-truck/references/candidate-packet.md:135` — change
  "...binds the owner only to the fingerprint, manifest, exclusions, and evidence cutoff
  displayed at selection time." → "...binds the owner only to the fingerprint, manifest, and
  exclusions displayed at selection time."
- [ ] T003 [P] [US1] Edit `docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md:181`
  (KTD5) — change "...plus the displayed manifest and evidence cutoff." → "...plus the
  displayed manifest."

**Checkpoint**: `grep -rc "evidence cutoff" --include=*.md .` totals 3.

---

## Phase 3: User Story 2 — Discoverable breaking-grammar notice (P2)

**Independent test**: rendering `README.md`'s `ops/trash-truck` row cell alone shows the
breaking-grammar fact, without reading the blockquote below.

- [ ] T004 [US2] Edit `README.md:67` — append to the `ops/trash-truck` row description:
  "— **breaking:** the `focus:<name>` invocation grammar was replaced by `mode:` /
  `candidate:` / `persist:`; see note below." Keep the existing blockquote at `:69` unchanged.

**Checkpoint**: README row itself states the break; blockquote at `:69` untouched.

---

## Phase 4: User Story 3 — Honest owner-presence fail-safe (P2)

**Independent test**: `grep -n "owner is unclear\|owner presence\|interactive owner" skills/ops/trash-truck/SKILL.md docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md` shows all matches framed as unenforceable + naming the compensating control.

- [ ] T005 [US3] Edit `skills/ops/trash-truck/SKILL.md:32-39` (Non-Negotiable Boundaries) — add
  a bullet naming owner-presence detection as instruction-level/unverifiable by
  `resolve_mode()`, and naming the compensating control (execution requires explicit owner
  selection of an exact fingerprint, §5–§7). Mirror the honest-limitation shape of
  `candidate-packet.md:148`.
- [ ] T006 [US3] Edit `skills/ops/trash-truck/SKILL.md:28` (mode table, "Presence of an
  interactive owner is unclear" row) — reword to be consistent with the T005 bullet; same file
  as T005, run after it.
- [ ] T007 [US3] Edit `docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md:178`
  (KTD2) — align wording with the T005/T006 framing. Same file as T003; run after T003
  completes.

**Checkpoint**: all three sites (mode table, Boundaries, KTD2) read consistently; none
asserts a mechanical guarantee.

---

## Phase 5: User Story 4 — Discoverable non-normative plan doc (P3)

**Independent test**: opening the plan doc shows a one-line banner above the H1 pointing at
`skills/ops/trash-truck/references/`; `git log --diff-filter=R` shows no rename.

- [ ] T008 [US4] Add a one-line banner above the H1 in
  `docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md` pointing to
  `skills/ops/trash-truck/references/` as normative. Same file as T003/T007 — run last of the
  three plan-doc edits. Do not rename/move the file; do not reword the body elsewhere.

**Checkpoint**: banner renders above H1; `git diff` on the plan doc shows only banner +
KTD5 + KTD2 lines changed.

---

## Phase 6: Polish

- [ ] T009 Run all 9 steps of `specs/159-trash-truck-doc-drift/quickstart.md` end to end.
- [ ] T010 Run `npx markdownlint-cli2` on the four changed files; fix any new warnings.
- [ ] T011 Re-run `python3 skills/ops/trash-truck/evals/test_retirement_contract.py`; confirm
  still passes, unchanged from T001 baseline.

## Dependencies

- Setup (T001) → Stories (Phase 2–5, any order across stories) → Polish (T009–T011).
- Within `docs/plans/...retirement-plan.md`: T003 (US1) → T007 (US3) → T008 (US4), strictly
  sequential (same file).
- Within `skills/ops/trash-truck/SKILL.md`: T005 → T006, strictly sequential (same file).
- T002 and T003 are `[P]` (different files, no shared dependency).

## Notes

- MVP = Phase 2 (US1) alone: fixes the only drift the issue's CTO review called a correctness
  risk (over-promised binding); US2–US4 are discoverability/honesty polish and ship
  independently after.
- Commit after each phase checkpoint, not each task — four files, ~30 lines of prose total.
