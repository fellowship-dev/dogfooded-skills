# Feature Specification: Trash Truck Doc Drift Correction

**Feature Branch**: `159-trash-truck-doc-drift`
**Created**: 2026-10-09
**Status**: Draft
**Input**: Correct trash-truck docs over-promising bindings the retirement validator does not
enforce; clarify a superseded plan doc's normativity (issue #159).

## User Scenarios & Testing

### User Story 1 — Honest approval-binding claim (P1)
Curator reading `candidate-packet.md` should not believe a stale evidence cutoff is
mechanically caught by `approval_valid()`.
**Acceptance**: Packet binding sentence + plan KTD5 list only fingerprint, manifest,
exclusions — not evidence cutoff.

### User Story 2 — Discoverable breaking-grammar notice (P2)
Consumer scanning the README table should see the `focus:<name>` → `mode:`/`candidate:`/
`persist:` break in the `ops/trash-truck` row itself.
**Acceptance**: Row cell states the grammar break and points to the note below the table.

### User Story 3 — Honest owner-presence fail-safe (P2)
Owner reading Non-Negotiable Boundaries should see owner-presence framed as instruction-level
and unverifiable, with its compensating control named.
**Acceptance**: SKILL.md Boundaries, mode table, and plan KTD2 all agree it's unenforceable
and name the compensating control (exact-fingerprint owner selection).

### User Story 4 — Discoverable non-normative plan doc (P3)
Maintainer opening the plan doc should see it's a historical record, not the live rubric.
**Acceptance**: One-line banner above the H1 points to `skills/ops/trash-truck/references/`;
body otherwise unchanged, not moved/renamed.

## Requirements
### Functional
- **FR-001**: `candidate-packet.md` + plan KTD5 MUST drop "evidence cutoff" from the binding claim.
- **FR-002**: README `ops/trash-truck` row MUST itself state the breaking grammar change.
- **FR-003**: SKILL.md Boundaries MUST call owner-presence unenforceable + name the compensating
  control; mode table + plan KTD2 MUST be made consistent with it.
- **FR-004**: Plan doc MUST gain a one-line normative-pointer banner above its H1 only.
- **FR-005**: Only README.md, SKILL.md, candidate-packet.md, and the plan doc MUST change.

## Success Criteria
- **SC-001**: `grep -rc "evidence cutoff" --include=*.md .` totals 3 (correct survivors only).
- **SC-002**: README row itself, not just the blockquote, carries the breaking-grammar fact.
- **SC-003**: Owner-presence claim reads consistently at all 3 sites.
- **SC-004**: `test_retirement_contract.py` still passes, unchanged from baseline.

## Assumptions
- Validator code (`rank_candidates.py`) is correct/untouched; only prose changes. Issue items 1
  (pylot#3378 sequencing) and 6 (live readback) are external, out of scope.
