# Quality Score — fellowship-dev/dogfooded-skills

Last updated: 2026-04-21

## Domains

| Domain | Grade | Last audit | Notes |
|--------|-------|------------|-------|
| meta | A | 2026-04-21 | All signals green; 3 open issues (benchmarking, measurement, hyperskills) — within ✅ threshold |
| ops | B | 2026-04-21 | S4 ❌ — 7 open feature issues (cto-heartbeat, cto-review, hookshot, review-pr, security-check, pii-check, cold-start-check) |
| product | A | 2026-04-21 | All signals green; 0 open issues |

## Signal Applicability

| Signal | Applicable? | Reason |
|--------|------------|--------|
| S1 Doc Coverage | No | docs/code-structure.md absent; README.md documents namespace conventions |
| S2 FlowChad | No | Skills library — no frontend framework detected |
| S3 Staleness | Yes | — |
| S4 Open Issues | Yes | — |
| S5 Tests | No | No coverage reports found |
| S6 Hookshot | No | .claude/doc-coverage.json not configured |
| S7 Speckit Drift | No | Speckit not installed in this repo |

## Grade Summary

- A: 2 (meta, product)
- B: 1 (ops)
- C: 0
- D: 0
- F: 0

## History

| Date | Trigger | Summary |
|------|---------|---------|
| 2026-04-21 | tooling.dev daily sweep | 3 domains scanned, 0 regressions, 1 improvement (ops: F → B) |
| 2026-04-18 | PR #23 merged — entropy-check auto-detect inapplicable signals | ops: F (all signals N/A at time of scan) |
