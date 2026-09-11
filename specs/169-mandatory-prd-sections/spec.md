# Feature Specification: Mandatory "smallest version" and "what this deletes" sections; second mechanism is REWORK

**Feature Branch**: `169-mandatory-prd-sections`
**Created**: 2026-09-11
**Status**: Draft
**Input**: Owner ruling (Max, 2026-09-07) encoding pylot `docs/principles.md` XI/XII/XIII into `issue-to-prd` and `cto-review`. See fellowship-dev/dogfooded-skills#169.

## User Scenarios & Testing

### User Story 1 — issue-to-prd triages redundancy first, then states smallest version and deletions (P1)

Before drafting, `issue-to-prd` rejects requests that duplicate an existing mechanism by naming it; every published PRD then states the least change that works and what it retires, with unbacked claims as Open Questions.

**Acceptance**:
1. **Given** an issue duplicating an existing mechanism, **Then** verdict is DELETE/RETIRE, CLOSE, or RE-SCOPE (never PRD) and the mechanism is named.
2. **Given** a genuine gap, **Then** verdict is PRD and the published PRD has a non-templated "Smallest version that works" section (larger scope cites a failing case) and a "What this lets us delete" section ("nothing" needs a one-line reason).
3. **Given** a claim lacks a file:line citation or measured number, **Then** it is an Open Question, not an assertion.

### User Story 2 — cto-review flags redundant mechanisms and speculative generality (P2)

`cto-review` verdicts REWORK, naming the problem, when a diff adds a second mechanism for a covered need or speculative generality.

**Acceptance**:
1. **Given** a diff adds a second config/gate/pin/route for an already-served need, **Then** verdict is REWORK naming the mechanism to retire.
2. **Given** a diff adds unused configuration or a one-caller abstraction, **Then** verdict is REWORK.

### Edge Cases

- Smallest version equals full scope: section still exists and says so. A deliberate in-progress migration still triggers REWORK unless the old mechanism is retired in the same change.

## Requirements

### Functional

- **FR-001**: `issue-to-prd` MUST triage every issue into exactly one verdict — DELETE/RETIRE, CLOSE, RE-SCOPE, PRD, in that order — before drafting.
- **FR-002**: `issue-to-prd` MUST reject a PRD path that adds a mechanism for an already-served need, naming the existing mechanism.
- **FR-003**: The PRD template MUST make "Smallest version that works" and "What this lets us delete" mandatory, non-placeholder sections.
- **FR-004**: `issue-to-prd` MUST require every PRD claim to cite a file:line or measured number, else state it as an Open Question.
- **FR-005**: `cto-review` MUST verdict REWORK, naming the mechanism to retire, when a diff adds a second mechanism for an already-served need, or adds speculative generality (unused config, one-caller abstraction).

## Success Criteria

- **SC-001**: One real `issue-to-prd` run on a live issue shows both new sections, non-templated.
- **SC-002**: One real `cto-review` run on a live PR shows both new checklist rows with a verdict.
- **SC-003**: No skill source in this repo still recommends anything but REWORK/retire for a second mechanism.

## Assumptions

- Each skill's change stays self-contained in that skill's own files — no shared paragraph across `issue-to-prd` and `cto-review`.
- "Nothing to delete" is a valid PRD answer when it carries a one-line reason.
