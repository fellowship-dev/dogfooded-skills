---
name: {{PROCEDURE_NAME}}
description: {{PROCEDURE_DESCRIPTION}}
argument-hint: "{{ARGUMENT_HINT}}"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, Agent
---

# {{PROCEDURE_TITLE}}

{{PROCEDURE_PURPOSE}}

## When to Use

{{WHEN_TO_USE_BULLETS}}

## Prerequisites

{{PREREQUISITES}}

## Procedure

This is a multi-stage ICM procedure. Each stage has an explicit contract (Inputs/Process/Outputs) in its CONTEXT.md.

### Arguments

- First positional argument: {{PRIMARY_ARG_DESCRIPTION}}
{{ADDITIONAL_ARGS}}
- `--stage N` -- resume from stage N (reads prior stage outputs from `.procedure-output/`)
- `--review` -- pause at checkpoint stages, post output, exit with `status=review`

### Output Location

Working artifacts are written to the repo, not this skill directory:

```
$REPO_DIR/.procedure-output/{{PROCEDURE_NAME}}/
├── 01-{{STAGE_1_NAME}}/
│   └── {{STAGE_1_ARTIFACT}}
├── 02-{{STAGE_2_NAME}}/
│   └── {{STAGE_2_ARTIFACT}}
└── ...
```

## Execution

1. **Parse arguments**

   ```bash
   TASK="$1"
   STAGE_START=1
   REVIEW_MODE=false

   # Parse flags
   for arg in "$@"; do
     case "$arg" in
       --stage) shift; STAGE_START="$1"; shift ;;
       --review) REVIEW_MODE=true; shift ;;
     esac
   done
   ```

2. **Create output directory**

   ```bash
   PROC_OUTPUT="$REPO_DIR/.procedure-output/{{PROCEDURE_NAME}}"
   mkdir -p "$PROC_OUTPUT"
   ```

3. **Read CONTEXT.md** for the stage chain and shared context list. Load shared context files listed in the Shared Context table.

4. **Run stages sequentially** starting from `$STAGE_START`:

   For each stage `0N-<name>`:

   a. Read `stages/0N-<name>/CONTEXT.md`

   b. **Load inputs** per the Inputs table:
      - Previous stage output: read from `$PROC_OUTPUT/0(N-1)-<prev>/`
      - Reference material: read from `stages/0N-<name>/references/` or `shared/`
      - Respect selective section routing -- load only the sections specified in the Inputs table

   c. **Execute Process steps** numbered in the CONTEXT.md. Each step is a concrete action -- follow them in order.

   d. **Run Audit checks** if the stage has an Audit section. For each check:
      - Evaluate the pass condition
      - If any check fails: revise the output and re-run the failed check
      - Do not proceed to the next step until all checks pass

   e. **Checkpoint gate** (if stage has a Checkpoints section AND `$REVIEW_MODE` is true):
      - Complete the stage and write output
      - Post a summary of what was produced to the mission log
      - Exit with: `[pylot] outcome="stage 0N complete, awaiting review" status=review`
      - The operator re-dispatches with `--stage (N+1)` after review

   f. **Write artifacts** to `$PROC_OUTPUT/0N-<name>/`

5. **Emit outcome marker** after all stages complete:

   ```
   [pylot] outcome="{{PROCEDURE_NAME}} complete: <summary of final deliverable>" status=success
   ```

## Resume from Stage N

When invoked with `--stage N`:

1. Skip stages 1 through N-1
2. Read their outputs from `$PROC_OUTPUT/` -- they must exist
3. If prior outputs are missing, exit with `status=failed` and report which stage output is missing
4. Start execution at stage N

This enables: run stages 01-03, human reviews output, re-dispatches with `--stage 4`.

## Review Gates

When invoked with `--review`:

- Stages WITHOUT a Checkpoints section run straight through (no pause)
- Stages WITH a Checkpoints section pause after completion:
  1. Write the stage output to `$PROC_OUTPUT/`
  2. Post a summary to the log describing what was produced and what the Checkpoints table says the human should decide
  3. Exit with `status=review`

Without `--review`, all stages run straight through regardless of Checkpoints sections.

## Error Handling

**Prior stage output missing on resume** -- exit with `status=failed`. Report which stage output directory is empty or missing. Do not attempt to re-run the missing stage.

**Audit check fails after 3 revision attempts** -- exit with `status=partial`. Report which check keeps failing, what the output looks like, and which stages completed successfully.

**External tool not available** -- check prerequisites. If a required tool is missing, exit with `status=blocked` and name the tool + install instructions from the stage's `references/` folder.

## Critical Rules

- **Follow the stage contracts exactly.** The CONTEXT.md is the spec. Do not improvise steps.
- **Load only what the Inputs table says.** Extra context dilutes quality.
- **Write to `$PROC_OUTPUT/`, never to the skill directory.** The skill is mounted read-only.
- **Audit before output.** Never write to the output directory until all audit checks pass.
- **Docs over outputs.** Reference files in `references/` and `shared/` are authoritative. Do not learn patterns from previous stage outputs (ICM Pattern 14).
- **One stage at a time.** Do not read ahead to later stages. Each stage is self-contained via its contract.
