# speckit-proc

Issue-to-PR pipeline. Operator triages, dispatches a worker for speckit phases, verifies the result.

## Arguments

| Name | Source | Description |
|------|--------|-------------|
| `$0` | Positional | Issue number |
| `$1` | Positional | Org/repo (e.g., `fellowship-dev/pylot`) |

## Stage Chain

| Stage | Input From | Output |
|-------|-----------|--------|
| 01-triage | Arguments | `.procedure-output/speckit-proc/01-triage/triage.md` |
| 02-implement | 01-triage output | `.procedure-output/speckit-proc/02-implement/result.md` |
| 03-verify | 02-implement output | `.procedure-output/speckit-proc/03-verify/report.md` |

## Stage Routing

| Task | Go To |
|------|-------|
| Check issue state and deduplicate | `stages/01-triage/CONTEXT.md` |
| Dispatch worker for speckit pipeline | `stages/02-implement/CONTEXT.md` |
| Verify PR and deliverables | `stages/03-verify/CONTEXT.md` |

## Shared Context

None. All inputs are per-run arguments or GitHub API responses.
