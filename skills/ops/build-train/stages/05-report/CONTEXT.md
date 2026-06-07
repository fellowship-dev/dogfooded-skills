# Stage 05: Report (inline)

## Inputs
- `.procedure-output/build-train/00-setup/handoff.md`
- `.procedure-output/build-train/01-plan-order/handoff.md`
- `.procedure-output/build-train/02-build-fanout/handoff.md`
- `.procedure-output/build-train/03-merge-chain/handoff.md`
- `.procedure-output/build-train/04-final-pr/handoff.md`

## Task
Write the build-train report and emit the outcome marker. This stage runs INLINE in the
orchestrator — the `[pylot] outcome=...` marker MUST come from here, never a subagent.

## Steps

1. Aggregate the handoffs: issues attempted (stage 00), completed (merged, stage 03), skipped
   (stage 02/03), the wave plan (stage 01), and the final PR number (stage 04).

2. Write the report to `reports/YYYY-MM-DD-build-train-REPO.md`:
```markdown
# Build Train: $REPO
**Branch:** $BUILD_BRANCH
**Final PR:** #N
**Issues:** N attempted, M completed, K skipped

## Build waves
| Wave | Issues |
|------|--------|
| 1 | #10, #15, #16 |
| 2 | #14 |

## Issues
| # | Issue | Worker | PR | Status |
|---|-------|--------|----|--------|
| 1 | #10 Brand assets | session-abc | #50 | Merged |
| 2 | #14 Blog | session-def | #51 | Merged |

## What's left
- Issue #15: worker failed, needs manual dispatch
```

3. Emit the outcome marker (orchestrator only):
   - Success (final PR opened): `[pylot] outcome="build-train complete: final PR #N (M/N issues)" status=success`
   - Failure (nothing shipped): `[pylot] outcome="build-train failed at stage NN: {reason}" status=failed`
   - Blocked (set at stage 00): `[pylot] outcome="build-train blocked: existing build branch {name}" status=blocked`

## Output: handoff.md

Path: `.procedure-output/build-train/05-report/handoff.md`

```markdown
# Stage 05: Report
report_path: reports/YYYY-MM-DD-build-train-REPO.md
final_pr: #{N}
issues: {N attempted, M completed, K skipped}
outcome_marker: {the exact marker emitted}
```

## Success criteria
- Report written with wave plan + per-issue table + what's-left section
- Exactly one `[pylot] outcome=...` marker emitted, from the orchestrator

## Failure
- Report write fails → still emit the outcome marker (the marker is the source of truth)
