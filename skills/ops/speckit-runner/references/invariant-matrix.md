# Invariant Matrix Contract

The runner persists the invariant matrix at
`specs/<feature>/invariant-matrix.tsv`. It is a cross-phase receipt, not a
producer-authored claim of success.

## Canonical schema

The file is UTF-8 TSV with one header, no embedded tabs or newlines, and these
columns in this exact order. Optional empty values use the literal `-` sentinel
so records never depend on trailing whitespace:

```text
id	class	provenance	success_behavior	negative_behavior	evidence_method	expected_check	applicability	state	repository	checkpoint	receipt	finding_ids
```

- `id` is a stable, unique `INV-NNN` identifier. Existing IDs are never
  renumbered during a run.
- `class` is one of `authorization-trust`, `state-data-integrity`,
  `failure-degradation`, `concurrency-idempotency`, or `lifecycle-cleanup`.
- `provenance` cites an issue, specification, task, or repository path and a
  section or line. A producer may not invent an invariant without this source.
- Behavior and evidence fields are non-empty and falsifiable. `expected_check`
  names a repository-owned check; producer prose is not a check.
- `applicability` is `applicable` or `not-applicable: <source-backed reason>`.
  Discovery classes are prompts, not quotas: omit unsupported classes.
- `state` is one of `passed`, `failed`, `not-run`, `unavailable`, `stale`, or
  `not-applicable`. Only an explicitly non-applicable row may use
  `not-applicable` state.
- `passed` and `failed` require repository identity, a full 40-hex checkpoint,
  and a secret-free supervisor receipt. No producer or reviewer narrative may
  set an execution state.
- `finding_ids` is `-` or a comma-separated list of stable `F-NNN` IDs.

## Discovery and planning

During planning, inspect issue, spec, tasks, and trusted repository guidance for
authorization/trust, state/data integrity, failure/degradation,
concurrency/idempotency, and lifecycle/cleanup boundaries. Emit every
source-backed invariant and no fabricated row for an unsupported class. New
applicable rows begin `not-run` with `-` repository, checkpoint, receipt, and
finding fields. Commit and push the matrix with the planning checkpoint and
emit its path, repository, and exact head as the matrix receipt.

## Supervisor reconciliation

Only the supervisor may update evidence states. Before any consumer uses the
matrix, compare every executed row with the reviewed repository and full
checkpoint. Change every unmatched `passed` or `failed` row to `stale`; preserve
the old repository, checkpoint, receipt, and findings as history. A fresh
supervisor observation may change `not-run` or `stale` to `passed`, `failed`, or
`unavailable`. Exit zero (or an equivalent directly observed success) is the
only route to `passed`; narrative summaries never are.

## Review and findings

The clean-context reviewer receives source artifacts, the matrix, branch/diff,
and supervisor receipts, but not producer rationale. It must address every
applicable row by ID; attempt its negative or boundary probe; check source,
implementation, and receipt contradictions; and create stable `F-NNN` findings
with concrete evidence. It uses row ID `OMITTED` for a source-backed invariant
absent from the matrix and returns an explicit row-addressed no-findings verdict
when falsification finds nothing.

Findings have `open`, `resolved`, or `declined` status and remain advisory.
Correction and optional final review preserve their IDs and dispositions.

## Lifecycle disclosure

Resume, correction, and final review reconcile the matrix against the exact
current repository/head before using receipts. A head change stales all
unmatched executed evidence and requires supervisor re-execution to restore an
execution state. Never discard `failed`, `not-run`, `unavailable`, `stale`, or
`not-applicable`; never discard unavailable-review records or unresolved and
declined findings.

PR preparation lists every applicable non-`passed` row with its exact state and
reason, first/final review availability, and all unresolved or declined
findings. These are transparent advisory context and do not prevent reaching
the runner's single PR-creation boundary.
