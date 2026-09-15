# Research: Spec-Derived Invariant Matrix

## Durable representation

- **Decision**: Persist the matrix as UTF-8 TSV with a fixed header and stable row IDs.
- **Rationale**: TSV remains readable in review, easy to validate with POSIX tooling, diff-friendly, and safe for multi-line-free prompt transport.
- **Alternatives**: Markdown tables are harder to parse reliably; JSON adds quoting noise and a stronger `jq` dependency; ephemeral shell variables cannot support resume.

## Discovery and applicability

- **Decision**: Treat authorization/trust, state/data integrity, failure/degradation, concurrency/idempotency, and lifecycle/cleanup as discovery prompts, not mandatory rows; every emitted row cites source evidence.
- **Rationale**: The classes exercise the required boundary breadth while the applicability rule prevents fabricated requirements.
- **Alternatives**: A mandatory five-row checklist violates FR-001/FR-002 for irrelevant classes; unconstrained prose cannot prove coverage or omissions.

## Evidence ownership and freshness

- **Decision**: Only supervisor-observed commands or inspections bound to repository identity and exact checkpoint may set `passed`; a changed checkpoint transitions unmatched evidence to `stale` until rerun.
- **Rationale**: This extends the shipped supervisor receipt model and prevents producer narrative or old results from becoming proof.
- **Alternatives**: Trusting producer summaries violates FR-003; discarding old evidence loses useful history; treating old results as `not-run` hides that they once ran against another head.

## Independent review protocol

- **Decision**: Give the reviewer source artifacts, matrix, branch/diff, and receipts without producer rationale; require row-addressed challenges, contradiction checks, and omitted-invariant findings.
- **Rationale**: Clean-context falsification minimizes anchoring and makes coverage measurable while keeping findings advisory.
- **Alternatives**: Free-form review does not establish row coverage; producer rationale contaminates independence; making findings blocking breaks the existing orchestration contract.

## Integration strategy

- **Decision**: Document the matrix lifecycle in `SKILL.md`, centralize schema/state rules in `references/invariant-matrix.md`, and test fixture transitions in one portable shell suite.
- **Rationale**: The repository is instruction-driven and its current runner tests are shell contracts; this avoids an unjustified application framework.
- **Alternatives**: A separate service or database increases operational surface; prompt-only rules lack a durable validator contract.
