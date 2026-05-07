---
name: speckit-proc
description: Issue-to-PR pipeline as an ICM procedure -- pre-flight, specify, plan, implement, deliver. Replaces speckit-runner with structured stage contracts.
argument-hint: "[issue-number] [org/repo]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# speckit-proc

Structured issue-to-PR pipeline. Takes a GitHub issue through pre-flight, specification, planning, implementation, and delivery -- each as a formally contracted stage.

## When to Use

- Implementing a GitHub issue that requires code changes
- Any dev task that should go through specify, plan, tasks, implement
- MANDATORY for all code tasks dispatched through Pylot crews

## Prerequisites

```bash
gh issue view $0 --repo $1 --json state --jq '.state' 2>/dev/null || echo "ERROR: cannot access issue"
```

Requires `gh` CLI with valid `GH_TOKEN`. Speckit skills (`/speckit-specify`, `/speckit-plan`, etc.) enhance each stage but are not strictly required -- Process steps can be followed directly.

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
├── 01-preflight/
├── 02-specify/
├── 03-plan/
├── 04-implement/
└── 05-deliver/
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
- **Pre-flight is mandatory.** No real data = garbage output. Never skip stage 01.
- **Run tests yourself.** Never trust documented results from earlier phases.
