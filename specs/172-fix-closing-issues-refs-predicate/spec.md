# Feature Specification: Fix closingIssuesReferences Repo Predicate

**Feature Branch**: `172-fix-closing-issues-refs-predicate`
**Created**: 2026-09-11
**Status**: Draft
**Input**: fellowship-dev/dogfooded-skills#172 — speckit-runner filters `closingIssuesReferences` on
`.repository.nameWithOwner`, a field the real `gh pr view --json closingIssuesReferences` payload
does not contain. The predicate is always false, breaking both the Step 8 PR postcondition and the
Step 0 duplicate-PR resume gate.

## User Scenarios & Testing

### User Story 1 — Successful runs report success (P1)
A correctly-formed PR that closes its driving issue must pass the Step 8 postcondition instead of
failing on unmatched repo metadata.
**Acceptance**:
1. **Given** a PR whose `closingIssuesReferences` includes the driving issue in this repo, **When** `verify_pr_postcondition` runs, **Then** it returns success (exit 0).
2. **Given** the same issue number closed by a PR in a different repo, **When** the predicate runs, **Then** it is rejected (exit 1).

### User Story 2 — Re-runs reconcile instead of duplicating (P1)
Re-running an already-delivered issue must find the existing PR via closing linkage (Step 0) and
reconcile, not open a second PR.
**Acceptance**:
1. **Given** an open PR array containing one PR that closes issue N in this repo, **When** Step 0's resume/dedup gate runs, **Then** it selects that PR.
2. **Given** no PR closes issue N in this repo, **When** Step 0 runs, **Then** it finds none and proceeds to create one.

### Edge Cases
- `repository` key missing, or `closingIssuesReferences` empty → rejected, never a jq error.

## Requirements
### Functional

- **FR-001**: The repo-match predicate MUST compare `.repository.owner.login + "/" + .repository.name` against the target repo, not `.repository.nameWithOwner`.
- **FR-002**: The predicate MUST be byte-identical in `shared/pr-postcondition.sh` and `SKILL.md`'s Step 0 resume snippet.
- **FR-003**: The predicate MUST fail closed: a missing `repository` key or empty `closingIssuesReferences` array yields rejection, never a jq execution error.
- **FR-004**: The test suite MUST execute the real `jq` predicate against a real-shaped fixture (no reimplementation stub), and MUST fail when the predicate is reverted to `.repository.nameWithOwner`.

### Key Entities
- **closingIssuesReferences entry**: `{id, number, repository: {id, name, owner: {id, login}}, url}` — the real shape returned by `gh pr view --json closingIssuesReferences`.

## Success Criteria

- **SC-001**: `bash skills/ops/speckit-runner/tests/pr-postcondition.test.sh` passes, exit 0, including a new wrong-repo case against the real-shaped fixture.
- **SC-002**: Reverting only the predicate to `.repository.nameWithOwner` makes the suite fail (proves the test now catches this class of defect).
- **SC-003**: `grep -rn '\.repository\.nameWithOwner' skills/ops/speckit-runner/` returns zero results.

## Assumptions
- Scope is fenced to 3 files: `shared/pr-postcondition.sh`, `SKILL.md`, `tests/pr-postcondition.test.sh` (+ optional fixture). Other `nameWithOwner` call sites use `gh repo view --json nameWithOwner`, where the field genuinely exists — out of scope.
- `any(...)` vs "exactly one closing ref" semantics, and the branch-misnaming defect, are separate known issues — follow-ups only.
- No new runtime dependency: `jq` is already required by the helper.
