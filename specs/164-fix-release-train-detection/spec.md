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
  field already read by `resolve-merge-strategy.sh` — same object, same lookup pattern, cross-repo
  addition tracked as a dependency, not built here.

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

## Requirements

- **FR-001**: MUST NOT use repo default-branch metadata (`defaultBranchRef`) to decide release-train status, in either direction.
- **FR-002**: MUST resolve the promote branch from `deploy.production_branch` in the repo's matching
  team entry (`pylot teams list`), sibling to the existing `deploy.release_mode` field, when present.
- **FR-003**: MUST NOT fall back to comparing against the literal `main` when no team declares a promote branch — that reproduces the false positive on repos where `main` is the ordinary target (dogfooded-skills, comment 2026-09-09).
- **FR-004**: Every decision (required / not-required / unconfigured) MUST print a rationale and record the resolved promote branch (or reason) in the stage-01 handoff.
- **FR-005**: No company-specific branch literals (`main`/`master`/`develop`) in a live predicate — fixtures only.

## Success Criteria

- **SC-001**: Ordinary `feature -> develop` PRs never trigger the gate (false positive fixed).
- **SC-002**: `develop -> main` release train triggers the gate although `main` isn't default (false negative fixed).
- **SC-003**: A repo with no declared promote branch never triggers the gate on any PR (third failure mode fixed).
- **SC-004**: Reverting to `base == default_branch` turns the SC-001/SC-002 fixtures red.

## Assumptions

- Owner dispatch (2026-09-10) supersedes the PRD's playbook-GET mechanism and its ban on team
  config, but not SC-003 (unmentioned by the dispatch; violated by an unqualified "else literal
  main") — FR-002+FR-003 together is the only reading consistent with all owner input. PRD scope
  fence/file list still applies (`stages/01-setup/CONTEXT.md`, `SKILL.md`, `test_evidence_gate.py`,
  `stages/02-review/CONTEXT.md:67`); only the mechanism changes.
