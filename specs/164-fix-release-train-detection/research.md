# Research: Fix Release-Train Detection

## Decision: promote-branch source

- **Decision**: Read `deploy.production_branch` from the repo's matching team entry via
  `pylot teams list`, same object as the existing `deploy.release_mode` field.
- **Rationale**: `resolve-merge-strategy.sh` already performs this exact lookup shape
  (`teams[] | select(repos[] matches repo) | .deploy.X`) one step earlier in the same stage-01
  script. Adding a sibling field costs nothing new — no new dependency, no new auth, no new
  request. The owner's 2026-09-10 dispatch names "team's deploy config" directly, matching this
  object.
- **Alternatives considered**:
  - *Playbook HTTP GET* (original PRD mechanism) — superseded by owner dispatch; also required a
    new endpoint call cto-review doesn't otherwise make.
  - *Head-side test (`head == develop`)* — rejected in the PRD itself: bakes in a company-specific
    integration-branch name.
  - *Reuse `defaultBranchRef`* — the bug being fixed.

## Decision: unconfigured fallback

- **Decision**: No team entry, or team entry with no `deploy.production_branch` → `NEEDS_EVIDENCE=false`,
  loud rationale line, `release_train_base: unconfigured (<reason>)` in handoff. Never compare
  against a bare literal `main`.
- **Rationale**: The owner dispatch's literal "else `main`" fallback, read unqualified, regresses
  SC-003 — dogfooded-skills has no team/deploy entry (it's a skills library, not deployed) and
  every PR targets `main` directly (comment 2026-09-09), so an unqualified literal-main comparison
  would misclassify every PR here as a release train again, reproducing the exact bug from a third
  angle. Treating "no team match at all" as unconfigured is the only reading that satisfies both
  the dispatch's stated goal (stop guessing from repo metadata) and the issue's own evidence.
- **Alternatives considered**:
  - *Literal `main` fallback whenever team config is unreachable/absent, no exception* — matches
    the dispatch's literal wording but is disproved by the dogfooded-skills fixture already in
    evidence; rejected.
  - *Fail closed (require evidence) when unconfigured* — rejected by the PRD's explicit ruling
    (dogfooded-skills bar #4, graceful degradation) and would block every train until every repo's
    team config is populated.

## Decision: test harness extension

- **Decision**: Extend `test_evidence_gate.py`'s freshness-layer pattern (extract real bash,
  run against a stub) with a stub `pylot` binary on PATH, following `test_resolve_merge_strategy.sh`'s
  fake-binary shape exactly (env-var controlled JSON payload, `PYLOT_TEST_FAIL` for unreachable).
  Delete `NECESSITY_FIXTURES` (n1-n5) and `needs_evidence()` — dead code modeling a retired bash
  path filter, per PRD scope.
- **Rationale**: Two working precedents already exist in this codebase for the two pieces this
  fixture needs (extract-real-bash, fake-CLI-stub); composing them needs no new technique.
