# Feature Specification: Reconcile Diff-Provenance Claims in double-check

**Feature Branch**: `178-double-check-provenance-claims`
**Created**: 2026-09-12
**Status**: Draft
**Input**: double-check stage 02's claim-reconciliation gate cannot adjudicate diff-provenance
(range) claims — assertions about what a base-branch merge brought in. These match no taxonomy
category, so they're certified by silence (3 consecutive cycles), licensing stale test receipts
when the "no source delta" claim is wrong.

## User Scenarios & Testing

### User Story 1 — Stage 02 classifies a provenance claim (P1)

As the stage 02 reviewer, a diff-provenance/range claim must resolve to a named evidence source,
so it's classified instead of silently passing through.

**Acceptance**:
1. **Given** a PR body claims "no source delta since `<sha>`", **When** stage 02 extracts claims,
   **Then** it's recognized as the provenance/range category, evidenced by a range diff from the
   cited SHA to the setup head SHA.
2. **Given** the range diff contradicts the claim, or the claim cites no SHA / an undiffable range,
   **When** dispositioned, **Then** it's marked `unbacked` — never `unknown` — arming the existing
   non-waivable `claims_reconciled: fail` stop.

### Edge Cases

- Ordinary (non-range) claims keep resolving via the Changed Files manifest; category must not
  widen and catch them.
- Range terminates at the PR's recorded setup head SHA, not local `HEAD` (stage 01 merges base
  into the checkout, which would inflate the range).

## Requirements

### Functional

- **FR-001**: Extraction list MUST include diff-provenance/range claims as a distinct category,
  bounded by shape (a commit range other than the PR's own merge-base diff).
- **FR-002**: Evidence source MUST be named: `git diff --stat <cited-sha>..<setup-head-sha>` in
  the stage 01 handoff's recorded checkout (or `gh pr diff` at both SHAs if no checkout).
- **FR-003**: A claim citing no SHA, or an undiffable range, MUST disposition to `unbacked`.
- **FR-004**: Non-range claims MUST be unaffected; change MUST be additive to the extraction and
  disposition lists in `skills/ops/double-check/stages/02-review/CONTEXT.md` step 2 only — no
  new file, helper, or test entry point.

## Success Criteria

- **SC-001**: Replaying the recorded live claim ("both merges brought in only an unrelated file —
  no source delta") against the amended step yields `claims_reconciled: fail`.
- **SC-002**: An ordinary claim (e.g. "adds `--org` to a CLI subcommand") still resolves `backed`.
- **SC-003**: Diff touches exactly one file, additive hunks only.

## Assumptions

- Prose-only; no code, schema, or cross-skill coupling. Taxonomy definitions and the `unknown`
  (truncated-manifest) paragraph stay unchanged — only the two lists are extended.
