# speckit-proc

Issue-to-PR pipeline using structured speckit phases.

## Arguments

| Name | Source | Description |
|------|--------|-------------|
| `$0` | Positional | Issue number |
| `$1` | Positional | Org/repo (e.g., `fellowship-dev/pylot`) |

## Stage Chain

| Stage | Input From | Output |
|-------|-----------|--------|
| 01-preflight | Arguments | `.procedure-output/speckit-proc/01-preflight/report.md` |
| 02-specify | 01-preflight output | `.procedure-output/speckit-proc/02-specify/result.md` |
| 03-plan | 02-specify output | `.procedure-output/speckit-proc/03-plan/result.md` |
| 04-implement | 03-plan output | `.procedure-output/speckit-proc/04-implement/result.md` |
| 05-deliver | 04-implement output | `.procedure-output/speckit-proc/05-deliver/report.md` |

## Stage Routing

| Task | Go To |
|------|-------|
| Gather issue context and real data | `stages/01-preflight/CONTEXT.md` |
| Create feature specification | `stages/02-specify/CONTEXT.md` |
| Design plan and break into tasks | `stages/03-plan/CONTEXT.md` |
| Execute tasks and run tests | `stages/04-implement/CONTEXT.md` |
| Create PR, review, verify | `stages/05-deliver/CONTEXT.md` |

## Shared Context

None. All inputs are per-run arguments, repo state, or GitHub API responses.
