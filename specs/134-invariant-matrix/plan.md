# Implementation Plan: Spec-Derived Invariant Matrix

**Branch**: `134-invariant-matrix` | **Date**: 2026-09-07 | **Spec**: [spec.md](spec.md)
**Input**: `/specs/134-invariant-matrix/spec.md`

## Summary

Extend `speckit-runner` with a durable, machine-checkable invariant matrix derived at planning time, updated only from supervisor-owned evidence, and carried through independent review, correction, optional final review, and PR disclosure. A documented TSV contract and portable shell fixtures keep the orchestration inspectable without adding runtime dependencies.

## Technical Context

- **Language/Version**: POSIX shell orchestration; Markdown prompt/reference contracts
- **Primary Dependencies**: `bash`/POSIX utilities, `git`, `gh`, `jq`, existing Pylot worker API
- **Storage**: Versioned planning TSV plus supervisor-owned, exact-head serialized TSV and review/finding summaries
- **Testing**: Portable shell contract tests with fixture matrices and static prompt assertions
- **Target Platform**: Linux operator with the existing `speckit-runner` prerequisites
- **Project Type**: Instruction-driven CLI skill
- **Performance Goals**: Matrix validation and reconciliation complete in under 1 second for 100 rows
- **Constraints**: No producer claim can pass a row; exact repository/checkpoint binding; reviewer remains advisory; one correction and one PR boundary
- **Scale/Scope**: One skill, one matrix contract, five required boundary-class fixtures, lifecycle regression coverage

## Constitution Check

The constitution contains placeholders rather than enforceable gates. The design follows repository evidence, adds deterministic tests, documents the state model, and introduces no new access or framework surface. Pre-design and post-design: PASS; no violations or unresolved clarifications.

## Project Structure

```text
skills/ops/speckit-runner/
├── SKILL.md
├── validate-review-output.sh
├── references/invariant-matrix.md
└── tests/{invariant-matrix.test.sh,fixtures/invariant-matrix/}
specs/134-invariant-matrix/{plan.md,research.md,data-model.md,contracts/invariant-matrix.tsv.md,quickstart.md,tasks.md}
```

**Structure Decision**: Keep executable behavior and its contract beside `skills/ops/speckit-runner`; keep design artifacts under the authoritative feature directory. The matrix is a cross-phase internal interface, so it receives a contract even though no network API is added.

## Design Approach

- Derive rows only from cited issue/spec/task/repository evidence across five discovery classes: authorization/trust, state/data integrity, failure/degradation, concurrency/idempotency, and lifecycle/cleanup; unsupported classes produce no row.
- Require stable row IDs and TSV fields for provenance, behaviors, evidence method, expected check, applicability, state, repository, checkpoint, receipt, and finding linkage.
- Permit `passed` only after supervisor execution at the exact pushed head; reconcile changed heads by making unmatched evidence `stale`, never by copying producer narrative.
- Give the clean-context reviewer source artifacts plus matrix/diff/receipts, require row-addressed falsification and omitted-row discovery, then preserve findings through one correction and optional final review.
- Validate schema, state transitions, five-class positive/negative fixtures, omitted/irrelevant classes, stale-head behavior, reviewer unavailability, and PR disclosure while retaining existing PR-postcondition tests.
- Serialize supervisor reconciliation with repository/checkpoint identity for every later consumer, and reject incomplete or malformed review output before accepting its completion marker.

## Complexity Tracking

No constitution violations require exceptions.
