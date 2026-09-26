# Quickstart: Invariant Matrix Smoke Test

1. From repository root, run `bash skills/ops/speckit-runner/tests/invariant-matrix.test.sh`.
2. Confirm fixtures cover all five discovery classes and execute seeded authorization, secret-handling, process-tree cancellation, session-continuity, and compatibility defects.
3. Confirm producer narrative cannot set `passed` and an exact-head change makes prior executed receipts `stale`.
4. Run `bash skills/ops/speckit-runner/tests/pr-postcondition.test.sh` to confirm the sole PR boundary still enforces head and issue linkage.
5. Inspect the generated disclosure fixture and confirm failed, not-run, unavailable, stale, reviewer-unavailable, and unresolved-finding details remain visible while PR preparation stays reachable.

## Observed implementation receipt

On 2026-09-07 both commands completed with exit status 0. The invariant suite
accepted the persisted planning matrix, covered all five source-backed discovery
classes with no fabricated class, detected all five seeded behavioral defects,
rejected incomplete review and narrative-only passing evidence, staled an old-head
receipt, and preserved every lifecycle state and advisory disclosure. The PR
postcondition suite accepted the matching head/linkage case and rejected both
wrong-head and missing-linkage cases.
