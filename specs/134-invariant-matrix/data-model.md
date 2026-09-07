# Data Model: Invariant Matrix

## Invariant row

| Field | Meaning | Rule |
|---|---|---|
| `id` | Stable row identity | Unique `INV-NNN`; never renumber during a run |
| `class` | Discovery class | One of the five documented classes |
| `provenance` | Source locator | Issue/spec/task/repository path plus section or line |
| `success_behavior` | Required positive behavior | Concrete, falsifiable statement |
| `negative_behavior` | Failure or boundary expectation | Concrete, falsifiable statement |
| `evidence_method` | Strongest practical observation | Command, inspection, or artifact kind |
| `expected_check` | Repository-owned check identity/command | Must not be invented from producer prose |
| `applicability` | Whether the row governs this change | `applicable` or `not-applicable` with reason |
| `state` | Current evidence state | `passed`, `failed`, `not-run`, `unavailable`, `stale`, `not-applicable` |
| `repository` | Evidence repository identity | Required for executed evidence |
| `checkpoint` | Full reviewed commit SHA | Required for `passed` or `failed` |
| `receipt` | Secret-free observed result locator/summary | Required for executed evidence |
| `finding_ids` | Linked review findings | Empty or comma-separated stable IDs |

## Review finding

| Field | Meaning |
|---|---|
| `id` | Stable `F-NNN` identifier |
| `row_id` | Challenged row, or `OMITTED` for a missing invariant |
| `evidence` | Concrete contradiction, negative probe, or omission source |
| `status` | `open`, `resolved`, or `declined` |
| `disposition` | Correction rationale and residual disclosure |

## Relationships and transitions

- One matrix has many invariant rows; a row may have many findings.
- Planning creates applicable rows as `not-run`; unsupported classes create no rows. Explicit source-backed exclusions may be `not-applicable`.
- Supervisor execution changes `not-run|stale` to `passed|failed|unavailable`; only exit-zero or equivalent observed success can produce `passed`.
- Any repository/checkpoint mismatch changes executed states to `stale`; refresh evaluates them anew and keeps prior receipt history available.
- Review adds row-addressed or `OMITTED` findings but does not directly change evidence state.
- Correction/final review resolves or preserves findings; PR preparation serializes every applicable non-passing state and unresolved/declined finding.
