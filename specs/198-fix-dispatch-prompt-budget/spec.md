# Feature Specification: Fix pylot-cli Dispatch Prompt-Size Budget Doc

**Feature Branch**: `198-fix-dispatch-prompt-budget`
**Created**: 2026-10-09
**Status**: Draft
**Input**: fellowship-dev/dogfooded-skills#198 — `skills/ops/pylot-cli/SKILL.md`'s Dispatch section
states the dispatch prompt-size budget as "4 KB," but the gateway guard
(`fellowship-dev/pylot:gateway/modules/missions/dispatch-overrides-guard.mts`) enforces
`ECS_OVERRIDES_LIMIT_BYTES (8192) - DISPATCH_OVERRIDES_RESERVED_BYTES (5632)` = 2560 bytes.

## User Scenarios & Testing

### User Story 1 — Dispatcher trusts the documented budget (P1)

An operator or worker building a dispatch prompt reads the Dispatch section and sizes the prompt to
the stated budget, so it does not fail the gateway's dispatch-overrides guard.

**Acceptance**:
1. **Given** the Dispatch section, **When** a dispatcher reads the prompt-size rule, **Then** it states ~2560 bytes, not "4 KB".
2. **Given** the Dispatch section, **When** a dispatcher scans it, **Then** all four dispatch-contract rules (`/skill` prefix, `team.role`, prompt size, no-secrets) each appear as one line.

### Edge Cases

- The separate no-secrets mention under "GitHub Auth Through the CLI" (SKILL.md:450-451) must remain
  untouched — it covers git-token credential handling, not the dispatch-payload rule.

## Requirements

### Functional

- **FR-001**: The Dispatch section MUST state the prompt-size budget as ~2560 bytes, not "4 KB".
- **FR-002**: The Dispatch section MUST state each of the four dispatch-contract rules (`/skill`
  prefix, `team.role`, prompt size, no-secrets) as one line each, replacing the current prose.
- **FR-003**: No other section of `SKILL.md` may be changed, including the existing no-secrets
  sentence under "GitHub Auth Through the CLI".
- **FR-004**: No file outside `skills/ops/pylot-cli/SKILL.md` may be changed; no file in
  `fellowship-dev/pylot` may be touched.

## Success Criteria

- **SC-001**: Diff touches only `skills/ops/pylot-cli/SKILL.md`, within the existing Dispatch section.
- **SC-002**: Dispatch section shows exactly 4 rule lines, one per rule, prompt-size line reading ~2560 bytes.
- **SC-003**: No duplicate or contradictory no-secrets statement is introduced elsewhere in the file.

## Assumptions

- Doc-only correction; no code, tests, or fixtures required (per issue's Testing Strategy).
- Byte figure (2560) and its derivation (8192 - 5632) are taken as given from the issue body and
  `fellowship-dev/pylot`'s guard constants; this spec does not re-derive or verify them against that
  repo, which is explicitly out of scope.
