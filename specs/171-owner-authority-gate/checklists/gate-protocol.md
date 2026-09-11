# Gate-Protocol Checklist: Owner-Authority Gate Narrows `security` Parking

**Purpose**: Validate spec.md's requirements-writing quality for the dual-trigger gate protocol,
post-implementation
**Created**: 2026-09-11
**Feature**: [spec.md](../spec.md)

## Completeness

- [x] CHK001 Does the spec state the behavior for both possible label states (`security` present,
  `security` absent) under the new gate? [Spec §FR-001, §FR-002]
- [x] CHK002 Does the spec define what happens when neither trigger fires (merge-bar path)?
  [Spec §User Story 1 Scenario 1]
- [x] CHK003 Does the spec define what happens when only the human trigger fires with the
  classifier returning `none`? [Spec §User Story 3]
- [x] CHK004 Does the spec define what happens when only the classifier trigger fires with no
  human label applied? [Spec §User Story 1 Scenario 2]

## Clarity

- [x] CHK005 Is "one closed decision line" precise enough to exclude compound or open-ended
  questions? [Spec §User Story 2 Scenario 1: "exactly one closed yes/no or A-vs-B question"]
- [x] CHK006 Is "quotable runtime-effect evidence" distinguished clearly from file path/name
  evidence? [Spec §FR-003: "using quotable runtime-effect evidence, never file path/name"]

## Consistency

- [x] CHK007 Do FR-002 and FR-005 agree that the human-applied-label trigger and the classifier
  trigger are independent (neither can suppress the other)? [Spec §FR-002, §FR-005 — consistent:
  "MUST fire only on... OR..." / "MUST hard-block... independent of the classifier"]
- [x] CHK008 Does the Assumptions section's claim that only "downstream framing changes" for
  `security` agree with FR-001's unchanged-detector requirement? [Spec §Assumptions, §FR-001 —
  consistent]

## Measurability

- [x] CHK009 Is SC-001 objectively replayable without ambiguity about which fixtures to use?
  [Spec §SC-001 — names the two source PRs directly]
- [x] CHK010 Is SC-003's "never a generic ... sentence" phrased as something a static text check
  can verify (absence of a specific string), not a subjective judgment? [Spec §SC-003]

## Coverage

- [x] CHK011 Do all three user stories have at least one edge case or success criterion tied to
  them? [Spec §User Story 1 → SC-001/SC-002; §User Story 2 → SC-003; §User Story 3 → SC-004]
- [x] CHK012 Is the "classifier uncertainty" failure mode covered by an edge case, not just the
  happy path? [Spec §Edge Cases: "Classifier uncertainty resolves to no-park"]

## Edge Cases

- [x] CHK013 Are both worked-negative examples (pylot#3372, #3408) distinct in what they guard
  against (destructive-prod-data vs. secrets-handling), rather than duplicating one concern?
  [Spec §Edge Cases — distinct classes]
- [x] CHK014 Does the spec rule out the "when in doubt, park" fallback explicitly, rather than
  leaving it to implementer discretion? [Spec §Edge Cases — explicit]

## Notes

- All 14 items pass against spec.md as written — no spec-quality gaps found post-implementation.
- Not in scope for this checklist (implementation-validation, not spec-quality): whether the
  shipped code matches these requirements — that was verified separately via
  `test_owner_gate_contract.py` and `speckit.analyze`'s coverage pass, both of which found 100%
  requirement coverage.
