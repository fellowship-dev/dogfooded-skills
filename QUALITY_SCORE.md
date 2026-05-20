# Quality Score — fellowship-dev/dogfooded-skills

Last updated: 2026-05-20

## Domains

| Domain | Grade | Last audit | Notes |
|--------|-------|------------|-------|
| meta | B | 2026-05-20 | S3 ✅ (last commit 2026-05-07, 13d); S4 ✅ (3 open: measurement, benchmarking, hyperskills); S6 ❌ (hookshot not configured) |
| ops | B | 2026-05-20 | S3 ✅ (last commit 2026-05-20, 0d); S4 ✅ (3 open: cto-heartbeat, hookshot, pii-check); S6 ❌ (hookshot not configured) |
| product | B | 2026-05-20 | S3 ✅ (last commit 2026-04-25, 25d); S4 ✅ (0 open); S6 ❌ (hookshot not configured) |

## Signal Matrix

| Domain | S1 Doc | S2 FlowChad | S3 Stale | S4 Issues | S5 Tests | S6 Hookshot |
|--------|--------|-------------|----------|-----------|----------|-------------|
| meta | N/A | N/A | ✅ (13d) | ✅ (3) | N/A | ❌ |
| ops | N/A | N/A | ✅ (0d) | ✅ (3) | N/A | ❌ |
| product | N/A | N/A | ✅ (25d) | ✅ (0) | N/A | ❌ |

## Signal Applicability

| Signal | Applicable? | Reason |
|--------|------------|--------|
| S1 Doc Coverage | No | docs/code-structure.md absent; README.md documents namespace conventions |
| S2 FlowChad | No | Skills library — no frontend framework detected |
| S3 Staleness | Yes | — |
| S4 Open Issues | Yes | — |
| S5 Tests | No | No coverage reports found |
| S6 Hookshot | Yes | Not configured ❌ |

## Grade Summary

- A: 0
- B: 3 (meta, ops, product)
- C: 0
- D: 0

## Entropy Findings — 2026-05-20

### Improvements (grade improved)
- ops: C → B
  Reason: security-check issue closed; S4 dropped from ⚠️ (4 open) to ✅ (3 open)

### Stable issues (same grade)
- meta: B (S6 hookshot not configured)
- product: B (S6 hookshot not configured)

### Action Items
- None — no domains at D or F

## History

| Date | Trigger | Summary |
|------|---------|---------|
| 2026-04-21 | weekly sweep | 3 domains scanned; meta A, ops B, product A. S6 incorrectly excluded. |
| 2026-05-18 | weekly sweep | 3 domains; S6 methodology corrected. meta B, ops C, product B. Ops S4 improved (3 issues closed). 0 regressions (methodology fix), 0 real improvements. |
| 2026-05-19 | daily sweep | 3 domains, 0 regressions, 0 improvements. All signals stable. |
| 2026-05-20 | daily sweep | 3 domains, 0 regressions, 1 improvement. ops C→B (security-check closed, S4 ⚠️→✅). |