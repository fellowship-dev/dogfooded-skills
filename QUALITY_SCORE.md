# Quality Score — fellowship-dev/dogfooded-skills

Last updated: 2026-05-18

## Domains

| Domain | Grade | Last audit | Notes |
|--------|-------|------------|-------|
| meta | B | 2026-05-18 | S3 ✅ (last commit 2026-05-11, 7d); S4 ✅ (3 open: benchmarking, measurement, hyperskills); S6 ❌ (hookshot not configured) |
| ops | C | 2026-05-18 | S3 ✅ (last commit 2026-05-11, 7d); S4 ⚠️ (4 open: cto-heartbeat, hookshot, security-check, pii-check); S6 ❌ (hookshot not configured) |
| product | B | 2026-05-18 | S3 ✅ (last commit 2026-05-11, 7d); S4 ✅ (0 open); S6 ❌ (hookshot not configured) |

## Signal Matrix

| Domain | S1 Doc | S2 FlowChad | S3 Stale | S4 Issues | S5 Tests | S6 Hookshot |
|--------|--------|-------------|----------|-----------|----------|-------------|
| meta | N/A | N/A | ✅ (7d) | ✅ (3) | N/A | ❌ |
| ops | N/A | N/A | ✅ (7d) | ⚠️ (4) | N/A | ❌ |
| product | N/A | N/A | ✅ (7d) | ✅ (0) | N/A | ❌ |

## Signal Applicability

| Signal | Applicable? | Reason |
|--------|------------|--------|
| S1 Doc Coverage | No | docs/code-structure.md absent; README.md documents namespace conventions |
| S2 FlowChad | No | Skills library — no frontend framework detected |
| S3 Staleness | Yes | — |
| S4 Open Issues | Yes | — |
| S5 Tests | No | No coverage reports found |
| S6 Hookshot | Yes | Not configured ❌ (previously incorrectly marked N/A — methodology correction in this sweep) |

## Grade Summary

- A: 0
- B: 2 (meta, product)
- C: 1 (ops)
- D: 0

**Methodology note (2026-05-18)**: S6 (Hookshot) corrected from N/A to applicable per entropy-check spec ("S6 is always applicable"). Previous audits incorrectly excluded it. This caused meta and product to drop from A→B and ops from B→C. Real regression in ops: 3 issues closed since 2026-04-21 (cto-review, review-pr, cold-start-check resolved), reducing S4 from ❌ (7 issues) to ⚠️ (4 issues) — improvement in signal but grade still C due to S6.

## History

| Date | Trigger | Summary |
|------|---------|---------|
| 2026-04-21 | weekly sweep | 3 domains scanned; meta A, ops B, product A. S6 incorrectly excluded. |
| 2026-05-18 | weekly sweep | 3 domains; S6 methodology corrected. meta B, ops C, product B. Ops S4 improved (3 issues closed). 0 regressions (methodology fix), 0 real improvements. |
