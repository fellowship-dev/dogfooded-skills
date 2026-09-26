# Feature Specification: Owner-Authority Gate Narrows `security` Parking

**Feature Branch**: `171-owner-authority-gate`
**Created**: 2026-09-11
**Status**: Draft
**Input**: GitHub issue fellowship-dev/dogfooded-skills#171

## User Scenarios & Testing
### User Story 1 — CTO review parks only on real owner decisions (P1)

Stop treating a security-flavoured finding as a park trigger by itself.
1. **Given** a PR carries `security` with no owner-authority match, **When** cto-review runs, **Then** it reaches the merge bar, not a park.
2. **Given** a diff matches one of five closed owner-authority classes, **When** cto-review runs, **Then** it applies `waiting-on-owner` and parks.

### User Story 2 — Owner gets one closed question per park (P2)

Every automated park names exactly one decision and its answerer.
1. **Given** an automated park fires, **When** the comment posts, **Then** it has exactly one closed yes/no or A-vs-B question and a named answerer.

### User Story 3 — Human override still hard-blocks (P2)

A human-applied `waiting-on-owner` keeps blocking merge regardless of the classifier.
1. **Given** a human applies `waiting-on-owner` and the classifier returns `none`, **When** cto-review runs, **Then** it still parks, naming the human as answerer.

### Edge Cases

- A reviewed migration on the normal review path (pylot#3372) must not match destructive-prod-data.
- A "credential"-named file with no secret exposure (pylot#3408) must not match secrets-handling.
- Classifier uncertainty resolves to no-park, never "when in doubt, park".

## Requirements
### Functional

- **FR-001**: `review-pr` MUST keep applying `security` under its unchanged detection condition, described only as classification metadata — never as a hold or block.
- **FR-002**: `cto-review`'s owner gate MUST fire only on a human-applied `waiting-on-owner` label or an owner-authority classifier match; `security` MUST NOT be a trigger.
- **FR-003**: `cto-review` MUST classify each diff against a closed, verbatim five-class taxonomy using quotable runtime-effect evidence, never file path/name; unmatched or uncertain classifies as `none`.
- **FR-004**: Every automated park MUST post one closed decision line, the diff evidence, and a named authorized answerer.
- **FR-005**: A human-applied `waiting-on-owner` MUST hard-block merge unconditionally, independent of the classifier.

## Success Criteria

- **SC-001**: Replaying fellowship-dev/pylot#3372 and #3408 against the new logic never applies `waiting-on-owner`.
- **SC-002**: A `security`-labelled PR with class `none` reaches the merge bar instead of parking.
- **SC-003**: Every automated park comment has exactly one decision line and one named answerer, never a generic "carries label(s) X" sentence.
- **SC-004**: A human-applied `waiting-on-owner` with class `none` still parks.

## Assumptions

- The `security` label's detector and the label itself are unchanged; only its downstream framing changes.
- Verification is static contract tests with fixed fixtures; live confirmation happens post-merge after catalog sync.
