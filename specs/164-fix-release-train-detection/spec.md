# Feature Specification: Fix Release-Train Detection in cto-review

**Feature Branch**: `164-fix-release-train-detection`
**Created**: 2026-09-11
**Status**: Draft
**Input**: fellowship-dev/dogfooded-skills#164 — step 5.5's `base == default_branch` release-train
proxy inverts when the default branch isn't the promote target, and misfires when no promote
branch exists at all.

## Clarifications

### Session 2026-09-11
- Q: Field name/path for the team-declared promote branch (no such field exists in `pylot teams
  list` today)? → A: `deploy.production_branch`, sibling to the existing `deploy.release_mode`
  field already read by `resolve-merge-strategy.sh` — same object, same lookup pattern. This is a
  cross-repo schema/data dependency on `fellowship-dev/pylot`, NOT built here and, as of this
  writing, **not yet filed as a tracking issue in that repo**. Until it lands, every repo resolves
  `unconfigured` (fail-open) and the false-negative this issue exists to fix (SC-002) stays latent
  in practice, not just on paper. **Action required at PR time**: file and link a tracking issue in
  `fellowship-dev/pylot` for the schema addition, or explicitly accept the interim fail-open state
  in the PR description — this worker has no write access to file it from here.

## User Scenarios & Testing

### User Story 1 — Ordinary PRs are never blocked (P1)

Running `/cto-review` on an ordinary PR must never require staging evidence, regardless of the
repo's default branch.

**Acceptance**:
1. **Given** default branch `develop`, **When** a PR targets `develop`, **Then** NOT required.
2. **Given** a repo with no promote branch declared, **When** any PR is reviewed, **Then** NOT required.

### User Story 2 — The real release train is never exempt (P2)

The owner ruling (pylot#3389) requires the gate to trigger for the real release-train PR even when
its promote branch isn't the repo's default branch.

**Acceptance**:
1. **Given** promote target `main` and default branch `develop`, **When** a PR targets `main`, **Then** REQUIRED.
2. **Given** a team matches the repo but declares no `deploy.production_branch`, **When** a PR
   targets `main`, **Then** REQUIRED (owner-mandated literal fallback, dispatch 2026-09-10).

## Requirements

- **FR-001**: MUST NOT use repo default-branch metadata (`defaultBranchRef`) to decide release-train status, in either direction.
- **FR-002**: MUST resolve the promote branch from `deploy.production_branch` in the repo's matching
  team entry (`pylot teams list`), sibling to the existing `deploy.release_mode` field, when present.
- **FR-003**: When a team entry matches the repo but declares no `deploy.production_branch`, MUST
  fall back to the literal `main` (owner dispatch, 2026-09-10: "read it from the team's deploy
  config when present, else the literal `main`"). This fallback is scoped to a *matched* team with
  an unset field — it MUST NOT fire when no team declares the repo at all, which would reproduce
  the false positive on repos where `main` is the ordinary merge target and no promote flow exists
  (dogfooded-skills, comment 2026-09-09); that case resolves to `unconfigured` instead (see SC-003).
- **FR-004**: Every decision (required / not-required / unconfigured) MUST print a rationale and record the resolved promote branch (or reason) in the stage-01 handoff, including which source produced it (team-declared vs. literal fallback vs. unconfigured).
- **FR-005**: No company-specific branch literals (`main`/`master`/`develop`) in a live predicate to infer or guess the promote branch from repo metadata — fixtures only, EXCEPT the single owner-mandated literal `main` used by FR-003's scoped fallback, which is an explicit dispatched value, not an inference.

## Success Criteria

- **SC-001**: Ordinary `feature -> develop` PRs never trigger the gate (false positive fixed).
- **SC-002**: `develop -> main` release train triggers the gate although `main` isn't default (false negative fixed).
- **SC-003**: A repo with NO team match at all never triggers the gate on any PR (third failure mode fixed) — distinct from a matched team with an unset field, which falls back to literal `main` per FR-003.
- **SC-004**: Reverting to `base == default_branch` turns the SC-001/SC-002 fixtures red.

## Assumptions

- **Reconciling the owner dispatch (2026-09-10) with the third-failure-mode comment (2026-09-09)**:
  the dispatch's literal wording ("read it from the team's deploy config when present, else the
  literal `main`") is implemented with the field-level scoping in FR-003: "when present" is read as
  "the specific `deploy.production_branch` field is present on a matched team," not "any team
  config exists." This satisfies the dispatch's literal instruction for the case it was written to
  fix (pylot's own PRs, where a team matches but the field was never populated) while preserving
  SC-003 for the case the dispatch does not mention (no team declares the repo at all — the
  dogfooded-skills shape). No team match is a strictly narrower, pre-existing case the dispatch's
  sentence does not literally cover (there is no "the team" to have a deploy config for). This
  scoping was chosen over a blanket unconditional `main` fallback because the latter would silently
  regress SC-003.
  PRD scope fence/file list still applies (`stages/01-setup/CONTEXT.md`, `SKILL.md`,
  `test_evidence_gate.py`, `stages/02-review/CONTEXT.md:67`); only the mechanism changes.
