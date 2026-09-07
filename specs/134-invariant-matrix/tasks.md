# Tasks: Spec-Derived Invariant Matrix

## Phase 1: Setup

- [X] T001 Create invariant-matrix reference and fixture directories at `/workspace/skills/ops/speckit-runner/references/` and `/workspace/skills/ops/speckit-runner/tests/fixtures/invariant-matrix/`

## Phase 2: Foundational

- [X] T002 Define the canonical TSV schema, discovery classes, provenance rules, and state-transition rules in `/workspace/skills/ops/speckit-runner/references/invariant-matrix.md`
- [X] T003 Implement reusable schema, exact-checkpoint reconciliation, and disclosure assertions in `/workspace/skills/ops/speckit-runner/tests/invariant-matrix.test.sh`
- [X] T004 Add valid and malformed base matrices with stable row and finding IDs in `/workspace/skills/ops/speckit-runner/tests/fixtures/invariant-matrix/schema.tsv`

## Phase 3: User Story 1 — Derive durable invariants (P1) — MVP

**Independent test**: The contract test accepts source-backed rows for every applicable boundary class, omits an unsupported class, and rejects missing provenance or fabricated applicability.

- [X] T005 [P] [US1] Add source fixtures covering authorization/trust, state/data integrity, failure/degradation, concurrency/idempotency, lifecycle/cleanup, and one irrelevant category in `/workspace/skills/ops/speckit-runner/tests/fixtures/invariant-matrix/discovery.tsv`
- [X] T006 [US1] Add the planning-stage derivation prompt, persistence requirement, and matrix checkpoint receipt to `/workspace/skills/ops/speckit-runner/SKILL.md`
- [X] T007 [US1] Extend derivation assertions for five-class coverage, irrelevant-class omission, stable IDs, and all required columns in `/workspace/skills/ops/speckit-runner/tests/invariant-matrix.test.sh`

## Phase 4: User Story 2 — Falsify every applicable invariant (P2)

**Independent test**: Seeded violations are addressed by row ID, a source-backed omitted boundary produces an `OMITTED` finding, and no unrelated row is required.

- [X] T008 [P] [US2] Add seeded negative, contradiction, omitted-invariant, and no-findings review fixtures in `/workspace/skills/ops/speckit-runner/tests/fixtures/invariant-matrix/review.tsv`
- [X] T009 [US2] Replace the generic independent-review payload with clean-context row-by-row falsification, negative/boundary probes, contradiction checks, and omitted-invariant discovery in `/workspace/skills/ops/speckit-runner/SKILL.md`
- [X] T010 [US2] Extend review assertions for complete applicable-row coverage, all seeded challenges, omitted findings, and explicit no-findings verdicts in `/workspace/skills/ops/speckit-runner/tests/invariant-matrix.test.sh`

## Phase 5: User Story 3 — Preserve truthful lifecycle disclosure (P3)

**Independent test**: A head change stales unmatched receipts; every non-passing state and unavailable/residual review survives correction and PR disclosure without preventing the PR step.

- [X] T011 [P] [US3] Add old-head, corrected-head, non-passing-state, unavailable-reviewer, and residual-finding fixtures in `/workspace/skills/ops/speckit-runner/tests/fixtures/invariant-matrix/lifecycle.tsv`
- [X] T012 [US3] Add supervisor-only state updates, exact repository/head invalidation, finding preservation, correction/final-review reconciliation, and PR disclosure instructions to `/workspace/skills/ops/speckit-runner/SKILL.md`
- [X] T013 [US3] Extend lifecycle assertions to reject narrative-only passes, stale every unmatched receipt, preserve all six states, retain findings, and keep the sole PR boundary reachable in `/workspace/skills/ops/speckit-runner/tests/invariant-matrix.test.sh`
- [X] T014 [US3] Register the invariant suite in `/workspace/.github/workflows/tests.yml` and specify malformed-input rejection in `/workspace/specs/134-invariant-matrix/spec.md`

## Phase 6: Polish & Cross-Cutting

- [X] T015 Run `bash skills/ops/speckit-runner/tests/invariant-matrix.test.sh` and `bash skills/ops/speckit-runner/tests/pr-postcondition.test.sh` from `/workspace` and resolve every contract regression in `/workspace/skills/ops/speckit-runner/`
- [X] T016 Re-run the smoke-test procedure and reconcile documentation with observed behavior in `/workspace/specs/134-invariant-matrix/quickstart.md`

## Dependencies

- T001 → T002–T004 → T005–T007 (MVP) → T008–T010 → T011–T014 → T015–T016.
- US2 depends on the canonical schema and US1 persistence; US3 depends on the persisted matrix and review finding model.

## Parallel Execution Examples

- After T004: T005 can run while T006 changes `/workspace/skills/ops/speckit-runner/SKILL.md`.
- After T007: T008 can run before T009; after T010, T011 can run before T012.

## Implementation Strategy

- MVP: complete T001–T007 and run the US1 independent test.
- Incrementally add US2, then US3; finish with both repository-owned test commands in T014.
