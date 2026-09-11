# Implementation Plan: Fix Release-Train Detection in cto-review

**Branch**: `164-fix-release-train-detection` | **Date**: 2026-09-11 | **Spec**: `./spec.md`
**Input**: `/specs/164-fix-release-train-detection/spec.md`

## Summary

Replace the `base == default_branch` release-train proxy in cto-review step 5.5 with a
team-declared promote branch (`deploy.production_branch`, read via `pylot teams list`, mirroring
`resolve-merge-strategy.sh`'s existing `deploy.release_mode` lookup). No team entry or no declared
branch → gate fails open (`NEEDS_EVIDENCE=false`) and logs why; never falls back to a literal
`main`, per SC-003.

## Technical Context

- **Language/Version**: Bash (deployed predicate) + Python 3 (fixture harness)
- **Primary Dependencies**: `pylot` CLI (`teams list`), `jq`, `gh` — all already in use by `resolve-merge-strategy.sh`
- **Storage**: N/A (reads live team config, no local state)
- **Testing**: `python3 test_evidence_gate.py` (extracts real bash from CONTEXT.md and runs it against stub HTTP/CLI, per existing `_BuildRecordStub` and `test_resolve_merge_strategy.sh` patterns)
- **Target Platform**: cto-review stage-01 subagent (any repo cto-review runs against)
- **Project Type**: operational skill (bash procedure + Python test harness), no app/service layer
- **Performance Goals**: N/A — single CLI call per PR review, same cost profile as the existing `resolve-merge-strategy.sh` call already made in the same stage
- **Constraints**: zero `defaultBranchRef` reads; zero `main`/`master`/`develop` literals in live predicate (FR-005); must stay a single delimited bash block with stable anchors extractable by the test harness (mirrors `extract_gate_invocation()`)
- **Scale/Scope**: 4 files (scope-fenced by the PRD): `stages/01-setup/CONTEXT.md`, `SKILL.md`, `stages/01-setup/test_evidence_gate.py`, `stages/02-review/CONTEXT.md:67`

## Constitution Check

Project constitution is unfilled boilerplate (no repo-specific gates defined) — falling back to
this repo's own documented bar instead (PRD Testing Strategy + `test_resolve_merge_strategy.sh`
precedent):
- [x] Every new fixture extracted from the *real* deployed bash, never a re-typed copy (existing harness convention, `test_evidence_gate.py:211-236`)
- [x] Red-on-mutant required: reverting to `base == default_branch` must fail the new fixtures before merge
- [x] No silent fail-open: unconfigured path must print + record, not just default quietly (FR-004)
- [x] Reuse the existing `pylot` CLI stub pattern (`test_resolve_merge_strategy.sh`'s fake `pylot` binary) — no new mocking dependency

No violations requiring justification; Complexity Tracking table omitted.

## Project Structure

```text
specs/164-fix-release-train-detection/
├── plan.md         # this file
├── research.md     # Phase 0 — deploy.production_branch field, fail-open semantics
└── quickstart.md   # Phase 1 — manual fixture walkthrough
```
No `data-model.md` (no persistent entities) and no `contracts/` (no external API surface —
`pylot teams list` is an existing CLI contract already consumed by a sibling script).

**Structure Decision**: in-place edits to existing skill files only; no new files, directories, or
scaffolding beyond the two docs above. Matches the PRD's scope fence exactly.

## Complexity Tracking

*No violations — table omitted.*
