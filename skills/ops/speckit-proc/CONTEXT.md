# speckit-proc

Issue-to-PR pipeline. Operator triages, then drives a persistent worker session through speckit phases.

## Arguments

| Name | Source | Description |
|------|--------|-------------|
| `$0` | Positional | Issue number |
| `$1` | Positional | Org/repo (e.g., `fellowship-dev/pylot`) |

## Stage Chain

| Stage | Input From | Output |
|-------|-----------|--------|
| 01-preflight | Arguments | `01-preflight/handoff.md` |
| 02-specify | 01-preflight handoff | `02-specify/handoff.md` |
| 03-plan | 02-specify handoff | `03-plan/handoff.md` |
| 04-tasks | 03-plan handoff | `04-tasks/handoff.md` |
| 05-implement | 04-tasks handoff | `05-implement/handoff.md` |
| 06-test | 05-implement handoff | `06-test/handoff.md` |
| 07-deliver | 06-test handoff | `07-deliver/handoff.md` |

All handoff paths relative to `.procedure-output/speckit-proc/`.

## Stage Routing

| Task | Go To |
|------|-------|
| Gather issue context and real data | `stages/01-preflight/CONTEXT.md` |
| Spawn worker, create feature spec | `stages/02-specify/CONTEXT.md` |
| Design implementation approach | `stages/03-plan/CONTEXT.md` |
| Break plan into atomic tasks | `stages/04-tasks/CONTEXT.md` |
| Execute tasks | `stages/05-implement/CONTEXT.md` |
| Run tests and fix failures | `stages/06-test/CONTEXT.md` |
| Create PR, review, verify | `stages/07-deliver/CONTEXT.md` |

## Worker Session

Stages 02-07 share a single persistent worker session. Stage 02 spawns it (`--session-id`), stages 03-07 resume it (`--resume`). See `shared/worker-dispatch.md` for mechanics.
