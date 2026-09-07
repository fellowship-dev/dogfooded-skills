# Invariant Matrix TSV Contract

The persisted matrix is tab-separated UTF-8 with exactly one header and no embedded tabs or newlines in fields. Optional empty values use the literal `-` sentinel.

```text
id	class	provenance	success_behavior	negative_behavior	evidence_method	expected_check	applicability	state	repository	checkpoint	receipt	finding_ids
```

Contract rules:

- `id` matches `INV-[0-9]{3}` and is unique.
- `class` is `authorization-trust`, `state-data-integrity`, `failure-degradation`, `concurrency-idempotency`, or `lifecycle-cleanup`.
- `applicability` is `applicable` or a source-backed `not-applicable: <reason>`; discovery classes without evidence are omitted.
- `state` is exactly `passed`, `failed`, `not-run`, `unavailable`, `stale`, or `not-applicable`; an applicability/state contradiction is invalid.
- `passed` and `failed` require repository identity, a full 40-hex checkpoint, and a supervisor-owned receipt. Other states use `-` for absent bindings and carry a reason where relevant.
- A current `passed` row must match the reviewed repository and checkpoint. Reconciliation changes every unmatched executed row to `stale` before later phases consume it.
- Review output addresses each applicable row by ID and uses `OMITTED` for a source-backed invariant absent from the matrix.
- A completed review contains exactly one structured finding or explicit no-findings verdict for every applicable row; a marker alone is invalid.
- The supervisor passes the complete reconciled TSV with exact repository and checkpoint identity to every later lifecycle consumer.
- Lifecycle consumers preserve IDs, states, receipts, and findings; PR preparation discloses all applicable states other than `passed`, review unavailability, and unresolved or declined findings.
