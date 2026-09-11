# Quickstart: Verify the Release-Train Fix

1. `python3 skills/ops/cto-review/stages/01-setup/test_evidence_gate.py` → exit 0, all green.
2. Confirm the pylot ordinary-PR fixture (base `develop`, team declares `deploy.production_branch: main`) → NOT REQUIRED.
3. Confirm the pylot release-train fixture (base `main`, same team config) → REQUIRED.
4. Confirm the no-team-match fixture (dogfooded-skills shape: base `main`, no team entry) → NOT REQUIRED, rationale logged.
5. Confirm the team-entry-but-no-field fixture → NOT REQUIRED, `unconfigured` reason logged.
6. Red-on-mutant: temporarily restore `BASE_BRANCH = DEFAULT_BRANCH`, rerun step 1, confirm fixtures 2 and 3 fail; revert.
7. `grep -rn "defaultBranchRef" skills/ops/cto-review/` → no results.
8. `grep -rnE '\b(main|master|develop)\b' skills/ops/cto-review/SKILL.md skills/ops/cto-review/stages/` → fixture/example context only.
