---
name: speckit-proc
description: Issue-to-PR pipeline as an ICM procedure -- 7 stages from pre-flight through delivery. Operator drives a persistent worker session through speckit phases. Replaces speckit-runner.
argument-hint: "[issue-number] [org/repo]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# speckit-proc

Issue-to-PR pipeline. The operator triages via GitHub API, then drives a persistent worker session through specify, plan, tasks, implement, test, and deliver -- one resume per stage.

## When to Use

- Implementing a GitHub issue that requires code changes
- Any dev task routed through the speckit pipeline
- MANDATORY for all code tasks dispatched through Pylot crews

## Prerequisites

```bash
gh issue view $0 --repo $1 --json state --jq '.state' 2>/dev/null || echo "ERROR: cannot access issue"
```

Requires `gh` CLI with valid `GH_TOKEN` and worker dispatch scripts (`spawn-worker.sh` with `--resume` support, `wait-for-worker.sh`).

## Procedure

This is a multi-stage ICM procedure. Each stage has an explicit contract (Inputs/Process/Outputs) in its CONTEXT.md. Read the contract, follow the process, write the output.

### Arguments

- First positional argument: Issue number (e.g., `42`)
- Second positional argument: Org/repo (e.g., `fellowship-dev/pylot`)
- `--stage N` -- resume from stage N (reads prior stage outputs)
- `--review` -- pause at checkpoint stages, exit with `status=review`

### Output Location

Stage handoffs are written to:

```
.procedure-output/speckit-proc/
├── 01-preflight/
├── 02-specify/
├── 03-plan/
├── 04-tasks/
├── 05-implement/
├── 06-test/
└── 07-deliver/
```

## Execution

1. **Create output directory**

   ```bash
   mkdir -p ".procedure-output/speckit-proc"
   ```

2. **Read CONTEXT.md** for the stage chain and worker session info.

3. **Run stages sequentially:**

   For each stage:

   a. Read `stages/0N-<name>/CONTEXT.md`
   b. Load inputs per the Inputs table (respect selective section routing)
   c. Follow the Process steps exactly as written
   d. Run Audit checks if present -- revise until all pass
   e. If checkpoint + `--review`: write output, exit with `status=review`
   f. Write handoff to `.procedure-output/speckit-proc/0N-<name>/`

4. **Emit outcome marker:**

   ```
   [pylot] outcome="speckit-proc complete: <summary>" status=success
   ```

## Resume

With `--stage N`: skip stages 1 through N-1, read their handoffs from `.procedure-output/`, start at stage N. If prior handoffs are missing, exit with `status=failed`.

## Review Gates

With `--review`: stages with a Checkpoints section pause after completion and exit with `status=review`. Stages without checkpoints run straight through. Without `--review`, everything runs straight through.

## Critical Rules

- **Follow the stage contracts.** The CONTEXT.md Process section is the spec.
- **Load only what the Inputs table says.** Extra context dilutes quality.
- **Audit before output.** Do not write the handoff until all checks pass.
- **Docs over outputs.** Reference files are authoritative, not previous handoffs.
- **One stage at a time.** Do not read ahead to later stages.
- **Pre-flight is mandatory.** No real data = garbage output. Never skip stage 01.
- **One worker session.** Stage 02 spawns it, stages 03-07 resume it. Do not spawn fresh workers per stage.
