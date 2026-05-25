# Quality Score — fellowship-dev/dogfooded-skills

Last updated: 2026-05-25

## Domains

| Domain | Grade | Last audit | Notes |
|--------|-------|------------|-------|
| meta | B | 2026-05-21 | S3 ✅ (last commit 2026-05-07, 14d); S4 ✅ (3 open: measurement, benchmarking, hyperskills); S6 ❌ (hookshot not configured) |
| ops | C | 2026-05-21 | S3 ✅ (last commit 2026-05-23, 2d); S4 ⚠️ (4 open: cto-heartbeat, hookshot, pii-check, distill); S6 ❌ (hookshot not configured) |
| product | B | 2026-05-21 | S3 ✅ (last commit 2026-04-25, 26d); S4 ✅ (0 open); S6 ❌ (hookshot not configured) |

## Signal Matrix

| Domain | S1 Doc | S2 FlowChad | S3 Stale | S4 Issues | S5 Tests | S6 Hookshot |
|--------|--------|-------------|----------|-----------|----------|-------------|
| meta | N/A | N/A | ✅ (14d) | ✅ (3) | N/A | ❌ |
| ops | N/A | N/A | ✅ (2d) | ⚠️ (4) | N/A | ❌ |
| product | N/A | N/A | ✅ (26d) | ✅ (0) | N/A | ❌ |

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
- B: 2 (meta, product)
- C: 1 (ops)
- D: 0

## Dispatched This Run

- **#16 — pii-check: scan skill output, issues, PRs, and docs for PII and private info leaks** (P1) — dispatched for crew execution

## Entropy Findings — 2026-05-21

### Regressions (grade dropped)
- **ops**: B → C
  Reason: New issue #53 ([distill] Phase 2 token counting via SSE regex is unreliable — cost_usd will return 0) triaged P1, added to ops domain. S4 ✅ (3 open) → ⚠️ (4 open).

### Improvements (grade improved)
- None.

### Stable
- meta: B (S6 hookshot not configured)
- product: B (S6 hookshot not configured)

### Action Items
- ops grade regression: address #53 (P1, reliability) or close any of the 4 open ops issues to restore ✅ S4

## History

| Date | Trigger | Summary |
|------|---------|---------|
| 2026-04-21 | weekly sweep | 3 domains scanned; meta A, ops B, product A. S6 incorrectly excluded. |
| 2026-05-18 | weekly sweep | 3 domains; S6 methodology corrected. meta B, ops C, product B. Ops S4 improved (3 issues closed). 0 regressions (methodology fix), 0 real improvements. |
| 2026-05-19 | daily sweep | 3 domains, 0 regressions, 0 improvements. All signals stable. |
| 2026-05-20 | daily sweep | 3 domains, 0 regressions, 1 improvement. ops C→B (security-check closed, S4 ⚠️→✅). |
| 2026-05-21 | daily sweep | 3 domains, 1 regression, 0 improvements. ops B→C (#53 distill P1 triaged, S4 ✅→⚠️). Dispatched #16 (P1, pii-check). |
| 2026-05-25 | daily sweep | 3 domains, 0 regressions, 0 improvements. WIP=2: #62 dispatched today (spec-kit sync), #53 stale 4d+ (distill PRs #54/#55 merged — verify and close if resolved). ops S3 2d ✅. No new dispatch (WIP cap). |
