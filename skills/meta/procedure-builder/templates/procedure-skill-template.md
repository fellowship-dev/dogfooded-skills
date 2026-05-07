---
name: {{PROCEDURE_NAME}}
description: {{PROCEDURE_DESCRIPTION}}
argument-hint: "{{ARGUMENT_HINT}}"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# {{PROCEDURE_TITLE}}

{{PROCEDURE_PURPOSE}}

## When to Use

{{WHEN_TO_USE_BULLETS}}

## Prerequisites

{{PREREQUISITES}}

## Procedure

This is a multi-stage ICM procedure. Each stage has an explicit contract (Inputs/Process/Outputs) in its CONTEXT.md. Read the contract, follow the process, write the output.

### Arguments

- First positional argument: {{PRIMARY_ARG_DESCRIPTION}}
{{ADDITIONAL_ARGS}}
- `--stage N` -- resume from stage N (reads prior stage outputs)
- `--review` -- pause at checkpoint stages, exit with `status=review`

### Output Location

Stage artifacts are written to:

```
.procedure-output/{{PROCEDURE_NAME}}/
├── 01-{{STAGE_1_NAME}}/
├── 02-{{STAGE_2_NAME}}/
└── ...
```

## Execution

1. **Create output directory**

   ```bash
   mkdir -p ".procedure-output/{{PROCEDURE_NAME}}"
   ```

2. **Read CONTEXT.md** for the stage chain and shared context.

3. **Run stages sequentially:**

   For each stage:

   a. Read `stages/0N-<name>/CONTEXT.md`
   b. Load inputs per the Inputs table (respect selective section routing)
   c. Follow the Process steps exactly as written
   d. Run Audit checks if present -- revise until all pass
   e. If checkpoint + `--review`: write output, exit with `status=review`
   f. Write artifacts to `.procedure-output/{{PROCEDURE_NAME}}/0N-<name>/`

4. **Emit outcome marker:**

   ```
   [pylot] outcome="{{PROCEDURE_NAME}} complete: <summary>" status=success
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
