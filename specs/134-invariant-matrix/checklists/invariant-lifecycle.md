# Requirements Quality Checklist: Invariant Lifecycle

**Purpose**: Validate that invariant derivation, evidence ownership, review, and
disclosure requirements are complete and objectively interpretable.
**Created**: 2026-09-07
**Feature**: [spec.md](../spec.md)

## Completeness

- [x] CHK001 Are all persisted row fields and allowed evidence states specified? [Spec §Requirements, FR-002]
- [x] CHK002 Are derivation, supervisor verification, review, correction, resume, and PR disclosure phases all governed? [Spec §Requirements, FR-001–FR-007]

## Clarity

- [x] CHK003 Is the only authority permitted to produce a passing state unambiguous? [Spec §Requirements, FR-003]
- [x] CHK004 Is source-backed applicability distinguished from unsupported discovery classes? [Spec §User Story 1; §Edge Cases]

## Consistency

- [x] CHK005 Do review findings remain advisory while non-passing states remain truthfully disclosed? [Spec §User Story 3; FR-005]
- [x] CHK006 Is exact repository/checkpoint matching consistent across evidence invalidation and correction? [Spec §User Story 3; §Edge Cases]

## Measurability

- [x] CHK007 Are seeded review coverage and omitted-invariant detection quantified? [Spec §Success Criteria, SC-002]
- [x] CHK008 Are narrative-pass rejection and stale-receipt behavior objectively measurable? [Spec §Success Criteria, SC-003]

## Coverage

- [x] CHK009 Are all five discovery classes covered without turning them into mandatory quotas? [Spec §Assumptions; SC-001]
- [x] CHK010 Are malformed schema and contradictory lifecycle states explicitly addressed? [Spec §Edge Cases; FR-006]

## Edge Cases

- [x] CHK011 Is behavior defined when no source-backed invariant exists for a class or feature? [Spec §Edge Cases]
- [x] CHK012 Are reviewer unavailability, partial findings, and changed-head correction defined? [Spec §Edge Cases]
- [x] CHK013 Are stable IDs preserved when an omitted invariant is discovered later? [Spec §Edge Cases]
- [x] CHK014 Is the supervisor artifact's repository/checkpoint identity required at every lifecycle consumer? [Spec §Requirements, FR-007]
- [x] CHK015 Is reviewer completeness objectively defined beyond a completion marker? [Spec §Requirements, FR-007; SC-002]
