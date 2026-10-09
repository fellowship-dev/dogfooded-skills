# Implementation Plan: Trash Truck Doc Drift Correction

**Branch**: `159-trash-truck-doc-drift` | **Date**: 2026-10-09 | **Spec**: [spec.md](spec.md)
**Input**: `/specs/159-trash-truck-doc-drift/spec.md`

## Summary
Doc-truthfulness fix: four prose edits across four already-merged markdown files so they stop
over-promising bindings `approval_valid()` / `resolve_mode()` do not enforce, and so a
superseded plan doc declares its own non-normativity. No code, no new dependencies, no tests.

## Technical Context
- **Language/Version**: Markdown (prose only)
- **Primary Dependencies**: None — no code path touched
- **Storage**: N/A
- **Testing**: Existing `skills/ops/trash-truck/evals/test_retirement_contract.py` (unchanged;
  re-run to confirm baseline still passes after doc edits)
- **Target Platform**: N/A (documentation repo)
- **Project Type**: Internal-only (skill documentation correction)
- **Constraints**: Scope-fenced to exactly 4 content files (FR-005); no `git mv`, no rewording
  of plan doc body beyond KTD5/KTD2; no org/policy terms leak into the portable skill
- **Scale/Scope**: ~30 lines of prose across 4 files

## Constitution Check
The Spec-Kit constitution template used to bootstrap planning was the unpopulated default — no
gate derivable from it, and per this repo's convention the bootstrap scaffolding itself (that
template included) does not ship — see Correction. This feature instead gates against the
issue's own Implementation Constraints (binding for this feature):
- Fix direction is docs → code, never code → docs (never edit `rank_candidates.py`)
- No global-replace of "evidence cutoff"; 3 correct mentions must survive untouched
- No `docs/information-architecture.md`, no plan-doc rename/move/delete
- No new test file; no `owner-presence` detection mechanism added to `resolve_mode()`
- No `pylot`/`fellowship-dev`/label-semantics terms enter the portable skill files

PASS — plan only touches the 4 fenced content files with prose edits; no violation to justify.
Re-checked after Phase 1 design and after correction: still PASS.

## Project Structure
```text
specs/159-trash-truck-doc-drift/
├── plan.md            # this file
├── research.md        # Phase 0
├── data-model.md       # Phase 1 (N/A — no entities; documents affected doc sites instead)
├── quickstart.md       # Phase 1 — verification steps
└── tasks.md            # Phase 2
```
No `contracts/` — internal doc-only change, no external interface.

**Structure Decision**: Single project, doc-only. Real paths touched:
`README.md`, `skills/ops/trash-truck/SKILL.md`,
`skills/ops/trash-truck/references/candidate-packet.md`,
`docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md`.

## Complexity Tracking
No constitution violations — table omitted.

## Correction (independent review F-001)
Commit 347cbb2 bootstrapped `.specify/**` + `.claude/commands/speckit.*.md` to run this
planning round. Repo precedent (`56d2683`, `ec4c63d`, `fa3067d`, `fa930a2`) establishes that
scaffolding never ships; removed in the correction commit.
