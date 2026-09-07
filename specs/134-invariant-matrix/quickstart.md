# Quickstart: Invariant Matrix Smoke Test

1. From repository root, run `bash skills/ops/speckit-runner/tests/invariant-matrix.test.sh`.
2. Confirm fixtures cover all five discovery classes, omit an unsupported class, and reject an omitted source-backed invariant.
3. Confirm producer narrative cannot set `passed` and an exact-head change makes prior executed receipts `stale`.
4. Run `bash skills/ops/speckit-runner/tests/pr-postcondition.test.sh` to confirm the sole PR boundary still enforces head and issue linkage.
5. Inspect the generated disclosure fixture and confirm failed, not-run, unavailable, stale, reviewer-unavailable, and unresolved-finding details remain visible while PR preparation stays reachable.
