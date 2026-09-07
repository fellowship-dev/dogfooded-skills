# Feature Specification: Spec-Derived Invariant Matrix
**Feature Branch**: `134-invariant-matrix`
**Created**: 2026-09-07
**Status**: Draft
**Issue**: fellowship-dev/dogfooded-skills#134

## User Scenarios & Testing
### User Story 1 — Derive durable invariants (P1)
An implementer can trace each applicable load-bearing boundary from repository evidence to success, failure, and verification expectations.
**Acceptance**:
1. **Given** issue, specification, task, and repository guidance, **When** planning completes, **Then** a durable matrix records each applicable invariant, provenance, success behavior, negative behavior, strongest practical evidence, expected check, and state.
2. **Given** a discovery category unsupported by source evidence, **When** the matrix is derived, **Then** no mandatory row is fabricated for it.

### User Story 2 — Falsify every applicable invariant (P2)
An independent reviewer attempts to disprove each applicable row without receiving the producer's rationale.
**Acceptance**:
1. **Given** a review checkpoint, **When** review runs, **Then** the reviewer receives source artifacts, matrix, branch identity or diff, and receipts and returns row-addressed evidence or an explicit no-findings verdict.
2. **Given** seeded defects and an omitted boundary, **When** review runs, **Then** every seeded violation is challenged and omissions or contradictions are reported without unrelated mandatory rows.

### User Story 3 — Preserve truthful lifecycle disclosure (P3)
PR reviewers can distinguish verified, failed, unavailable, stale, and untested claims without blocking PR creation.
**Acceptance**:
1. **Given** a changed checkpoint identity, **When** prior evidence is reconciled, **Then** evidence not bound to the current repository and checkpoint becomes stale until refreshed.
2. **Given** failed review or incomplete evidence, **When** PR preparation runs, **Then** gaps and unresolved findings are disclosed and the sole PR boundary remains reachable.

### Edge Cases

- A discovery class with no source-backed boundary produces no row; a matrix
  with no applicable boundaries may contain only its canonical header.
- Multiple invariants may share a discovery class, but each keeps a unique,
  stable ID. A newly discovered or omitted invariant receives the next unused
  ID without renumbering existing rows.
- A repository match with a checkpoint mismatch, or a checkpoint match with a
  repository mismatch, stales every affected executed receipt. Partial commit
  identifiers never satisfy exact-checkpoint binding.
- Malformed rows, duplicate IDs, unknown states, applicability/state
  contradictions, and narrative-only pass claims are rejected before a later
  phase consumes the matrix.
- Reviewer timeout, invalid completion marker, or missing reviewer records an
  explicit unavailable reason. Partial findings remain linked and disclosed.
- A correction that changes HEAD cannot inherit earlier passed evidence; fresh
  supervisor execution is required. Failed, unavailable, stale, not-run, and
  not-applicable states remain distinct during disclosure.

## Requirements
### Functional
- **FR-001**: The planning checkpoint MUST persist a readable, machine-checkable invariant matrix derived only from issue, specification, task, and repository evidence.
- **FR-002**: Each row MUST retain provenance, success behavior, negative behavior, evidence method, expected check, applicability, and one distinct state: `passed`, `failed`, `not-run`, `unavailable`, `stale`, or `not-applicable`.
- **FR-003**: A row MUST reach `passed` only from supervisor-owned evidence bound to the reviewed repository and current checkpoint; any checkpoint change MUST invalidate unmatched evidence.
- **FR-004**: Independent review MUST attempt row-by-row falsification, negative and boundary inspection, contradiction checks, and omitted-invariant discovery without producer rationale.
- **FR-005**: Correction, optional final review, resume, and PR preparation MUST preserve row and finding state, disclose applicable gaps, retain advisory semantics, and preserve one producer, one reviewer, one correction pass, cleanup, and one PR-creation point.
- **FR-006**: Matrix consumers MUST reject malformed schema, duplicate or unstable IDs, unknown or contradictory states, incomplete executed-evidence bindings, and producer/reviewer narrative offered as passing evidence.

## Success Criteria
- **SC-001**: Portable fixtures yield an explicit negative or boundary row for all five required boundary classes and no fabricated row for an irrelevant class.
- **SC-002**: Review challenges 100% of seeded violations, identifies the deliberately omitted invariant, and reports contradictions with concrete evidence.
- **SC-003**: Zero rows pass from narrative alone, and 100% of prior-checkpoint receipts become stale after a checkpoint change until refreshed.
- **SC-004**: Reviewer unavailability and every non-passing applicable state reach PR preparation with accurate disclosure while all existing orchestration contracts continue to pass.

## Assumptions
- Issue #132's shipped receipt contract is authoritative; this feature extends rather than duplicates it.
- Issue #15 benchmark integration may remain unavailable, but deterministic acceptance fixtures are required now.
- Discovery categories guide evidence review and do not require empty or repository-specific rows.
