# Research: Reconcile Diff-Provenance Claims in double-check

No `[NEEDS CLARIFICATION]` markers remain in spec.md — the source PRD had already resolved the
open design questions. Recorded here for traceability.

## Decision: extend existing taxonomy vs. new gate mechanism

- **Decision**: add a bounded category to the existing extraction/disposition lists in step 2.
- **Rationale**: the `claims_reconciled: fail` hard stop already exists and is non-waivable; the
  defect is that provenance claims never reach a classification, not that the stop is missing.
  Adding a category is a disposition fix, not a new detector.
- **Alternatives considered**: a dedicated extractor/parser + test entry point — rejected per
  issue scope (explicitly forbidden: "second mechanism for a need the `claims_reconciled` stop
  already serves").

## Decision: evidence source for the new category

- **Decision**: `git diff --stat <cited-sha>..<setup-head-sha>` in the `REPO_DIR` recorded by stage
  01's `## Local Checkout` handoff block.
- **Rationale**: stage 01 already records `Setup head SHA` and the checkout path — no new plumbing
  needed. Stage 01's own success criteria guarantee `REPO_DIR` always exists whenever stage 02 runs,
  so no fallback path is needed for a missing checkout. Terminating at local `HEAD` instead would
  inflate the range, because stage 01 merges the base branch into the checkout (01-setup lines
  81-100).
- **Alternatives considered**: diffing to local `HEAD` — rejected, produces false `unbacked`
  verdicts on honest PRs (spec Edge Cases).

## Decision: disposition for unverifiable provenance claims

- **Decision**: `unbacked`, not `unknown`.
- **Rationale**: `unknown` is reserved for a truncated/missing diff manifest and does not arm the
  hard stop; routing an unverifiable range claim there would silently reproduce the defect.
- **Alternatives considered**: a new `unverifiable` disposition — rejected, out of scope (taxonomy
  definitions are frozen per the issue).
