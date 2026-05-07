---
name: speckit-proc
description: ICM procedure for issue-to-PR pipeline -- triage, worker dispatch, verification. Operator-level choreography using speckit phases.
argument-hint: "[issue-number] [org/repo]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# speckit-proc

Structured operator procedure for implementing GitHub issues via the speckit pipeline. Triages the issue, dispatches a worker to run speckit phases, and verifies the deliverable.

## When to Use

- Implementing a GitHub issue that requires code changes
- Any dev task routed through specify, plan, tasks, implement
- Operator needs auditable, staged issue-to-PR workflow

## Prerequisites

```bash
gh issue view $0 --repo $1 --json state --jq '.state' 2>/dev/null || echo "ERROR: cannot access issue"
```

The operator environment must have `gh` CLI with valid `GH_TOKEN`, and worker dispatch scripts (`spawn-worker.sh`, `wait-for-worker.sh`) available.

## Procedure

This is a multi-stage ICM procedure. Each stage has an explicit contract (Inputs/Process/Outputs) in its CONTEXT.md. Read the contract, follow the process, write the output.

### Arguments

- First positional argument: Issue number (e.g., `42`)
- Second positional argument: Org/repo (e.g., `fellowship-dev/pylot`)
- `--stage N` -- resume from stage N (reads prior stage outputs)
- `--review` -- pause at checkpoint stages, exit with `status=review`

### Output Location

Stage artifacts are written to:

```
.procedure-output/speckit-proc/
├── 01-triage/
├── 02-implement/
└── 03-verify/
```

## Execution

1. **Create output directory**

   ```bash
   mkdir -p ".procedure-output/speckit-proc"
   ```

2. **Read CONTEXT.md** for the stage chain and shared context.

3. **Run stages sequentially:**

   For each stage:

   a. Read `stages/0N-<name>/CONTEXT.md`
   b. Load inputs per the Inputs table (respect selective section routing)
   c. Follow the Process steps exactly as written
   d. Run Audit checks if present -- revise until all pass
   e. If checkpoint + `--review`: write output, exit with `status=review`
   f. Write artifacts to `.procedure-output/speckit-proc/0N-<name>/`

4. **Emit outcome marker:**

   ```
   [pylot] outcome="speckit-proc complete: <summary>" status=success
   ```

## Resume

With `--stage N`: skip stages 1 through N-1, read their outputs from `.procedure-output/`, start at stage N. If prior outputs are missing, exit with `status=failed`.

## Review Gates

With `--review`: stages with a Checkpoints section pause after completion and exit with `status=review`. Stages without checkpoints run straight through. Without `--review`, everything runs straight through.

## Critical Rules

- **Follow the stage contracts.** The CONTEXT.md Process section is the spec.
- **Load only what the Inputs table says.** Extra context dilutes quality.
- **Audit before output.** Do not write to the output directory until all checks pass.
- **Docs over outputs.** Reference files are authoritative, not previous stage outputs.
- **One stage at a time.** Do not read ahead to later stages.
