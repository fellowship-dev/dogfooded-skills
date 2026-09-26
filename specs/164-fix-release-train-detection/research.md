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
- **Rationale**: The owner dispatch's literal "else `main`" fallback, read unqualified, would
  regress SC-003 for genuine no-team-match repos: an unqualified literal-main comparison with no
  team-match gate at all would misclassify every PR on any undeclared repo as a release train,
  reproducing the exact bug from a third angle. Treating "no team match at all" as unconfigured is
  the only reading that satisfies both the dispatch's stated goal (stop guessing from repo
  metadata) and the issue's own evidence of that third failure mode. **Correction (stage-03
  double-check, 2026-09-11)**: this section originally cited `fellowship-dev/dogfooded-skills`
  itself as the concrete no-team-match example. That citation was never checked against live
  `pylot teams list` output and is wrong — this repo IS declared under the `pylot` team (`deploy:
  {"release_mode":"ship"}`, no `production_branch`), so it resolves via the matched-team/
  field-absent literal-`main` fallback, not via `unconfigured`. The underlying decision (no-team-
  match → unconfigured, never a bare literal-main comparison) is unaffected and still correct in
  general; only the illustrative example was wrong. No repo used as the actual SC-003 test fixture
  (`test_evidence_gate.py`'s T007, `acme/undeclared-repo`) is a real, currently-team-matched repo,
  so the fixture itself remains valid — it was just confusingly named after the real repo whose
  reported symptom (comment 2026-09-09) inspired it.
- **Alternatives considered**:
  - *Literal `main` fallback whenever team config is unreachable/absent, no exception* — matches
    the dispatch's literal wording but would regress SC-003 for genuine no-team-match repos;
    rejected.
  - *Fail closed (require evidence) when unconfigured* — rejected by the PRD's explicit ruling
    (graceful degradation) and would block every train until every repo's team config is populated.

## Decision: test harness extension

- **Decision**: Extend `test_evidence_gate.py`'s freshness-layer pattern (extract real bash,
  run against a stub) with a stub `pylot` binary on PATH, following `test_resolve_merge_strategy.sh`'s
  fake-binary shape exactly (env-var controlled JSON payload, `PYLOT_TEST_FAIL` for unreachable).
  Delete `NECESSITY_FIXTURES` (n1-n5) and `needs_evidence()` — dead code modeling a retired bash
  path filter, per PRD scope.
- **Rationale**: Two working precedents already exist in this codebase for the two pieces this
  fixture needs (extract-real-bash, fake-CLI-stub); composing them needs no new technique.
