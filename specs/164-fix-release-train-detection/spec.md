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
  the false positive on repos where `main` is the ordinary merge target and no promote flow exists;
  that case resolves to `unconfigured` instead (see SC-003). **Correction (stage-03 double-check,
  2026-09-11)**: this repo, `fellowship-dev/dogfooded-skills`, is NOT an example of the no-team-match
  case. Live `pylot teams list` shows it IS declared under the `pylot` team's `repos` array
  (alongside `fellowship-dev/pylot` and `fellowship-dev/pylot-skills`), with `deploy:
  {"release_mode":"ship"}` set and no `production_branch` sub-key — i.e. it hits FR-003's
  matched-team/field-absent branch and resolves `RELEASE_TRAIN_BASE=main`, the same as pylot's own
  PRs. The comment-2026-09-09 evidence (no `develop` branch, no deployable service, all recent PRs
  target `main`) is still accurate as a description of this repo's deploy shape, but it does not
  establish "no team declares this repo" — that premise was never independently checked against
  live team config before this spec was written, and turns out to be false. The genuine
  no-team-match case (SC-003) remains correctly handled by this fix; this repo simply isn't an
  instance of it.
- **FR-004**: Every decision (required / not-required / unconfigured) MUST print a rationale and record the resolved promote branch (or reason) in the stage-01 handoff, including which source produced it (team-declared vs. literal fallback vs. unconfigured).
- **FR-005**: No company-specific branch literals (`main`/`master`/`develop`) in a live predicate to infer or guess the promote branch from repo metadata — fixtures only, EXCEPT the single owner-mandated literal `main` used by FR-003's scoped fallback, which is an explicit dispatched value, not an inference.

## Success Criteria

- **SC-001**: Ordinary `feature -> develop` PRs never trigger the gate (false positive fixed).
- **SC-002**: `develop -> main` release train triggers the gate although `main` isn't default (false negative fixed).
- **SC-003**: A repo with NO team match at all never triggers the gate on any PR (third failure mode fixed) — distinct from a matched team with an unset field, which falls back to literal `main` per FR-003. SC-003 is satisfied in general by this fix (verified against the T007 fixture and the live no-match code path). **It is not, and was never claimed correctly to be, satisfied for `fellowship-dev/dogfooded-skills` specifically** — see the FR-003 correction above and the Assumptions section below. This repo resolves via the matched-team/literal-`main`-fallback path, not the no-team-match path, so it is a live instance of SC-002's fallback behavior (REQUIRED on `main`), not of SC-003.
- **SC-004**: Reverting to `base == default_branch` turns the SC-001/SC-002 fixtures red.

## Assumptions

- **Reconciling the owner dispatch (2026-09-10) with the third-failure-mode comment (2026-09-09)**:
  the dispatch's literal wording ("read it from the team's deploy config when present, else the
  literal `main`") is implemented with the field-level scoping in FR-003: "when present" is read as
  "the specific `deploy.production_branch` field is present on a matched team," not "any team
  config exists." This satisfies the dispatch's literal instruction for the case it was written to
  fix (pylot's own PRs, where a team matches but the field was never populated) while preserving
  SC-003 for the general no-team-match case, which the dispatch does not mention. This scoping was
  chosen over a blanket unconditional `main` fallback because the latter would silently regress
  SC-003.
  PRD scope fence/file list still applies (`stages/01-setup/CONTEXT.md`, `SKILL.md`,
  `test_evidence_gate.py`, `stages/02-review/CONTEXT.md:67`); only the mechanism changes.
- **Correction (stage-03 double-check, 2026-09-11)**: an earlier draft of this Assumptions section,
  and of FR-003/SC-003 above, illustrated "no team declares the repo at all" with
  `fellowship-dev/dogfooded-skills` as the concrete example. That example was never checked against
  live `pylot teams list` output and is factually wrong: this repo IS declared under the `pylot`
  team (`repos` array includes `fellowship-dev/dogfooded-skills`, `fellowship-dev/pylot`,
  `fellowship-dev/pylot-skills`; `deploy: {"release_mode":"ship"}`, no `production_branch`).
  Consequently this repo resolves via FR-003's matched-team/field-absent literal-`main` fallback,
  not via the no-team-match/`unconfigured` path — every PR into `main` here (including this PR)
  now correctly gets `RELEASE_TRAIN_BASE=main` and is classified REQUIRED under the new predicate.
  This does not change the fix's logic or correctness (the matched-team fallback is FR-003's
  intended behavior, and the dispatch's own live-damage examples are all pylot PRs experiencing
  exactly this path), but it does mean: (a) the 2026-09-09 comment's framing of dogfooded-skills as
  a "no promote flow, no team" repo describes its deploy shape accurately but not its team-match
  status; (b) whether a no-deploy-pipeline repo that happens to share a team entry with a real
  deploy repo *should* be exempted from the literal-`main` fallback is an open policy question this
  PR does not resolve and was not asked to resolve by any dated owner instruction found in issue
  #164's thread; and (c) the genuine no-team-match case this fix protects (SC-003) is a different,
  still-real case verified by the T007 fixture — dogfooded-skills is just not an example of it. See
  the PR body's "Independent review" section for how this affects the CTO REWORK comment (#164
  comment 3 / PR #179 comment 3).
