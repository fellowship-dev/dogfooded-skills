# Implementation Plan: Fix pylot-cli Dispatch Prompt-Size Budget Doc

**Branch**: `198-fix-dispatch-prompt-budget` | **Date**: 2026-10-09 | **Spec**: `./spec.md`
**Input**: `/specs/198-fix-dispatch-prompt-budget/spec.md`

## Summary

Rewrite `skills/ops/pylot-cli/SKILL.md`'s Dispatch section (lines 26-40) in place: replace the
prose stating a "4 KB" prompt-size budget with the gateway's real enforced figure (~2560 bytes =
`ECS_OVERRIDES_LIMIT_BYTES` 8192 − `DISPATCH_OVERRIDES_RESERVED_BYTES` 5632), and consolidate the
four dispatch-contract rules (`/skill` prefix, `team.role`, prompt size, no-secrets) into one line
each. No code change, no new mechanism — a correction to an existing doc passage.

## Technical Context

- **Language/Version**: Markdown (prose documentation)
- **Primary Dependencies**: None
- **Storage**: N/A
- **Testing**: `npx markdownlint-cli2 skills/ops/pylot-cli/SKILL.md` (warnings only, non-blocking)
- **Target Platform**: N/A — documentation consumed by dispatchers (operators/workers)
- **Project Type**: documentation (single Markdown file edit)
- **Performance Goals**: N/A
- **Constraints**: scope-fenced to `skills/ops/pylot-cli/SKILL.md` only; must not touch
  `fellowship-dev/pylot` or the existing no-secrets sentence at SKILL.md:450-451
- **Scale/Scope**: 1 file, ~15 lines (the existing Dispatch section, SKILL.md:26-40)

## Constitution Check

Project constitution is unfilled boilerplate (no repo-specific gates defined) — falling back to
the issue's own documented bar instead:

- [x] Diff touches only `skills/ops/pylot-cli/SKILL.md`, within the Dispatch section
- [x] Four rule lines present, one per rule, prompt-size line reading ~2560 bytes
- [x] No duplicate/contradictory no-secrets statement introduced elsewhere in the file
- [x] No `fellowship-dev/pylot` file touched

No violations requiring justification; Complexity Tracking table omitted.

## Project Structure

```text
specs/198-fix-dispatch-prompt-budget/
├── plan.md         # this file
├── research.md     # Phase 0 — confirms the 2560-byte figure and its derivation
└── quickstart.md   # Phase 1 — manual verification walkthrough
```

No `data-model.md` (no entities — pure prose edit) and no `contracts/` (no external interface;
this is an internal documentation correction, not an API/CLI/UI surface).

**Structure Decision**: in-place edit to the single scope-fenced file only; no new files beyond
the two docs above.

## Complexity Tracking

*No violations — table omitted.*
