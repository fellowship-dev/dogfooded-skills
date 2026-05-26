# Quality Score — fellowship-dev/dogfooded-skills

Last updated: 2026-05-26

## Domains

| Domain | Grade | Last audit | Notes |
|--------|-------|------------|-------|
| meta | B | 2026-05-26 | S3 ✅ (last commit 2026-05-07, 19d); S4 ✅ (3 open: measurement, benchmarking, hyperskills); S6 ❌ (hookshot not configured) |
| ops | C | 2026-05-26 | S3 ✅ (last commit 2026-05-23, 3d); S4 ⚠️ (5 open: cto-heartbeat, hookshot, pii-check, distill, spec-kit); S6 ❌ (hookshot not configured) |
| product | C | 2026-05-26 | S3 ⚠️ (last commit 2026-04-25, 31d — crossed 30d threshold); S4 ✅ (0 open); S6 ❌ (hookshot not configured) |

## Signal Matrix

| Domain | S1 Doc | S2 FlowChad | S3 Stale | S4 Issues | S5 Tests | S6 Hookshot |
|--------|--------|-------------|----------|-----------|----------|-------------|
| meta | N/A | N/A | ✅ (19d) | ✅ (3) | N/A | ❌ |
| ops | N/A | N/A | ✅ (3d) | ⚠️ (5) | N/A | ❌ |
| product | N/A | N/A | ⚠️ (31d) | ✅ (0) | N/A | ❌ |

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
- B: 1 (meta)
- C: 2 (ops, product)
- D: 0

## Dispatched This Run

(none — no D/F grades; product regression noted but C threshold does not trigger dispatch)

## Entropy Findings — 2026-05-26

### Regressions (grade dropped)
- **product**: B → C
  Reason: S3 staleness crossed 30d threshold. Last code commit 2026-04-25 is now 31d ago (was 26d on 2026-05-21).

### Improvements (grade improved)
- None.

### Stable
- meta: B (S6 hookshot not configured)
- ops: C (S4 ⚠️ 5 open; S6 hookshot not configured)

### Action Items
- product grade regression: new commit to skills/product/ would restore ✅ S3; or address S6 hookshot to reduce grade impact
- ops S4: close any of #16, #26, #29, #53, #62 to move back toward ✅ (need ≤3 open)
- #53 (distill): PRs #54/#55 reportedly merged — verify and close if resolved

## History

| Date | Trigger | Summary |
|------|---------|---------|
| 2026-04-21 | weekly sweep | 3 domains scanned; meta A, ops B, product A. S6 incorrectly excluded. |
| 2026-05-18 | weekly sweep | 3 domains; S6 methodology corrected. meta B, ops C, product B. Ops S4 improved (3 issues closed). 0 regressions (methodology fix), 0 real improvements. |
| 2026-05-19 | daily sweep | 3 domains, 0 regressions, 0 improvements. All signals stable. |
| 2026-05-20 | daily sweep | 3 domains, 0 regressions, 1 improvement. ops C→B (security-check closed, S4 ⚠️→✅). |
| 2026-05-21 | daily sweep | 3 domains, 1 regression, 0 improvements. ops B→C (#53 distill P1 triaged, S4 ✅→⚠️). Dispatched #16 (P1, pii-check). |
| 2026-05-25 | daily sweep | 3 domains, 0 regressions, 0 improvements. WIP=2: #62 dispatched today (spec-kit sync), #53 stale 4d+ (distill PRs #54/#55 merged — verify and close if resolved). ops S3 2d ✅. No new dispatch (WIP cap). |
| 2026-05-26 | daily sweep | 3 domains, 1 regression, 0 improvements. product B→C (S3 31d, crossed 30d threshold). ops C stable (S4 5 open). No new dispatch (C threshold, D/F not reached). |
