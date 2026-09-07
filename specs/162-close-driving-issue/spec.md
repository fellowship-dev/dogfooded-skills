# Feature Specification: Close Driving Issues and Decompose Remainders

**Feature Branch**: `162-close-driving-issue`
**Created**: 2026-09-07
**Status**: Implemented; delivery receipts pending
**Input**: Issue #162

## User Scenarios & Testing

### User Story 1 — Review Partial Delivery (P1)
As a PR reviewer, I identify unmet acceptance criteria without leaving the driving issue open for redispatch.
**Acceptance**:
1. **Given** a PR closes an issue but misses named acceptance criteria, **When** it is reviewed, **Then** a Bug finding requires finishing those items or filing and linking a conforming follow-up while retaining the closing reference.
2. **Given** a PR uses `Refs` for its driving issue, **When** it is reviewed, **Then** a finding requires exactly one closing reference for that issue.

### User Story 2 — Author Decomposed Work (P2)
As a PR author, I can split deliberate multi-PR work into independently tracked and closed issues.
**Acceptance**:
1. **Given** an explicitly out-of-scope remainder, **When** I self-audit the PR, **Then** the PR closes exactly one driving issue and links a follow-up rather than failing shippability.

### User Story 3 — File Consistent Follow-ups (P3)
As an agent, I can use one shared contract for follow-up issues regardless of which skill directs me.
**Acceptance**:
1. **Given** unmet criteria from issue N, **When** a follow-up is filed, **Then** its title and body begin with `Follow-up of #N`, its remaining criteria are copied verbatim, and it carries `ready-to-work` plus N's priority.

### Edge Cases

- Related-but-not-driving issues may use `Refs` only when clearly distinguished from the driving issue.
- Issues without acceptance criteria do not trigger an unmet-criteria assessment.

## Requirements

### Functional

- **FR-001**: Review guidance MUST retain `Closes #N` for a driving issue and require either completion in the PR or a linked follow-up for every named unmet criterion.
- **FR-002**: Review guidance MUST emit a calibrated-confidence Bug finding when the driving issue uses `Refs`, requiring a closing reference instead.
- **FR-003**: Author guidance MUST require exactly one driving issue per PR, always linked with `Closes`, and decompose multi-PR work into one issue per PR.
- **FR-004**: Both skills MUST reference one follow-up template containing Origin, Remaining acceptance criteria, and Out of scope sections, with verbatim remaining criteria and inherited workflow labels.
- **FR-005**: No skill guidance may recommend `Refs` for a driving issue; valid related-only usage MUST be explicitly identified as such.

## Success Criteria

- **SC-001**: Repository search finds zero instructions recommending `Refs #N` for a driving issue.
- **SC-002**: All skill corpus and lint checks pass after the guidance change.
- **SC-003**: One real review of a PR with an unmet criterion produces the new finish-or-follow-up wording and is linked as evidence.
- **SC-004**: The closing PR records the gateway catalog version synced after merge.

## Assumptions

- Gateway enforcement, reconciliation retirement, operational-tail semantics, and stale duplicate triage remain outside this feature.
