# Requirements Checklist: Driving-Issue Workflow Contract

**Purpose**: Validate that the close-and-decompose requirements are complete and unambiguous
**Created**: 2026-09-07
**Feature**: [spec.md](../spec.md)

## Completeness

- [x] Is the required relationship between a PR and its one driving issue defined? [Spec §FR-003]
- [x] Are all required follow-up fields, labels, and links specified? [Spec §FR-004]

## Clarity

- [x] Is driving-issue `Refs` usage unambiguously prohibited? [Spec §FR-002, §FR-005]
- [x] Is related-only `Refs` usage clearly distinguished from a driving issue? [Spec §Edge Cases]

## Consistency

- [x] Do reviewer and author requirements use the same close-and-decompose model? [Spec §FR-001–FR-004]
- [x] Do the user stories and functional requirements agree on retaining a closing reference? [Spec §US1, §FR-001]

## Measurability

- [x] Can prohibited driving-issue `Refs` guidance be detected by repository inspection? [Spec §SC-001]
- [x] Are the required follow-up opening text and verbatim criteria objectively checkable? [Spec §US3]

## Coverage

- [x] Are both `Refs`-only and partially delivered driving-issue review flows specified? [Spec §US1]
- [x] Is deliberate multi-PR author decomposition specified independently of review behavior? [Spec §US2]
- [x] Are local, live-review, and post-merge evidence classes represented? [Spec §SC-002–SC-004]

## Edge Cases

- [x] Is behavior for an issue without acceptance criteria defined? [Spec §Edge Cases]
- [x] Is priority-label behavior bounded to inheritance rather than label invention? [Spec §US3]
