# Quickstart: Verify the Release-Train Fix

1. `python3 skills/ops/cto-review/stages/01-setup/test_evidence_gate.py` → exit 0, all green.
2. Confirm the pylot ordinary-PR fixture (base `develop`, team declares `deploy.production_branch: main`) → NOT REQUIRED.
3. Confirm the pylot release-train fixture (base `main`, same team config) → REQUIRED.
4. Confirm the no-team-match fixture (dogfooded-skills shape: base `main`, no team entry) → NOT REQUIRED, rationale logged.
5. Confirm the team-entry-but-no-field fixture → NOT REQUIRED, `unconfigured` reason logged.
6. Red-on-mutant: `test_evidence_gate.py`'s `run_red_on_mutant_check()` runs the SC-001/SC-003/SC-002
   fixtures against a held `MUTANT_PREDICATE` (the old `base == default_branch` block, never written
   to CONTEXT.md) and confirms they fail, then confirms the real, deployed predicate stays green on
   the same fixtures.
7. `sed -n '154,197p' skills/ops/cto-review/stages/01-setup/CONTEXT.md | grep -n "defaultBranchRef"` → no results (the *live* predicate block only; prose/mutant-fixture references explaining or proving the fix are expected elsewhere).
8. `grep -rnE '\b(main|master|develop)\b' skills/ops/cto-review/SKILL.md skills/ops/cto-review/stages/` → fixture/example/mutant-proof context only, never the live predicate.
