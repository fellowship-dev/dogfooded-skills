# Quickstart: Verify the Release-Train Fix

**Prerequisite**: `jq` must be on `PATH` — the predicate and its test harness both shell out to it
(same pre-existing dependency `resolve-merge-strategy.sh` already has).

1. `python3 skills/ops/cto-review/stages/01-setup/test_evidence_gate.py` → exit 0, all green.
2. Confirm the pylot ordinary-PR fixture (base `develop`, team declares `deploy.production_branch: main`) → NOT REQUIRED.
3. Confirm the pylot release-train fixture (base `main`, same team config) → REQUIRED.
4. Confirm the no-team-match fixture (generic undeclared-repo shape: base `main`, no team entry — NOT the actual dogfooded-skills shape; that repo IS declared under the `pylot` team, see spec.md FR-003 correction) → NOT REQUIRED, rationale logged.
5. Confirm the team-entry-but-no-field fixture with base=main → REQUIRED, literal `main` fallback
   (owner dispatch 2026-09-10); the same fixture with a non-`main` base → NOT REQUIRED. Confirm the
   ambiguous-match fixture (two team entries claim the same repo) → NOT REQUIRED, `unconfigured`.
6. Red-on-mutant: `test_evidence_gate.py`'s `run_red_on_mutant_check()` runs the SC-001/SC-003/SC-002
   fixtures (T006/T007/T008/T010) against a held `MUTANT_PREDICATE` (the old `base == default_branch`
   block, never written to CONTEXT.md) and confirms they fail, then confirms the real, deployed
   predicate stays green on the same fixtures.
7. `sed -n '154,215p' skills/ops/cto-review/stages/01-setup/CONTEXT.md | grep -n "defaultBranchRef"` → no results (the *live* predicate block only; prose/mutant-fixture references explaining or proving the fix are expected elsewhere).
8. `grep -rnE '\b(master|develop)\b' skills/ops/cto-review/SKILL.md skills/ops/cto-review/stages/` → fixture/example/mutant-proof context only, never the live predicate. `main` is excluded from this
   check: it now appears once in the live predicate (`stages/01-setup/CONTEXT.md`) as the single,
   explicit, owner-mandated literal fallback value (FR-003) — not an inference from repo metadata.
