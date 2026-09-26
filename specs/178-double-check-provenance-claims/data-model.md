# Data Model: Reconcile Diff-Provenance Claims in double-check

No persisted data store — this documents the conceptual entities stage 02's protocol prose must
name, not a schema.

## Entities

### Provenance/range claim
- **Definition**: an assertion in a PR body about a commit range other than the PR's own
  `<merge-base>..<PR head>` diff (e.g. "the merge from `develop` brought in only X since `<sha>`").
- **Shape bound**: distinguished from ordinary claims by citing (or implying) a *different* range,
  not by keyword matching — per spec Edge Cases, ordinary claims must keep resolving via the
  Changed Files manifest.
- **Fields** (as extracted by the reviewer, not stored): cited SHA (may be absent), claimed content
  of the range, PR's setup head SHA (from stage 01 handoff).

### Disposition
- **Values**: `backed` | `elsewhere` | `unbacked` (existing taxonomy — unchanged).
- **State transition for this category**: a provenance claim transitions to `unbacked` when (a) the
  range diff contradicts the claim, (b) no SHA is cited, or (c) the range cannot be diffed. It never
  transitions to `unknown` — that value stays reserved for a truncated/missing diff manifest.

### Setup head SHA (existing, referenced not redefined)
- **Source**: stage 01 handoff, `Setup head SHA` field (~line 154 of 01-setup/CONTEXT.md).
- **Role here**: the fixed terminus of the range diff — never local `HEAD` in the stage 01 checkout,
  since stage 01 merges the base branch into that checkout.
