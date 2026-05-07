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

This is a multi-stage ICM procedure run by the **operator**. Each stage dispatches work to a worker and produces a handoff file describing the result. The operator never reads worker repo files directly -- it observes results via worker logs, GitHub API, and structured handoff contracts.

### Arguments

- First positional argument: {{PRIMARY_ARG_DESCRIPTION}}
{{ADDITIONAL_ARGS}}
- `--stage N` -- resume from stage N (reads prior handoff files)
- `--review` -- pause at checkpoint stages, post output, exit with `status=review`

### Handoff Files

Each stage writes a handoff file -- a contract describing what the worker produced, NOT the artifact itself. The operator cannot access the worker repo, so handoff files capture metadata the operator needs to make decisions.

```
.procedure-output/{{PROCEDURE_NAME}}/
├── 01-{{STAGE_1_NAME}}.md     (handoff: path, summary, checklist)
├── 02-{{STAGE_2_NAME}}.md     (handoff: path, summary, checklist)
└── ...
```

Handoff file format:

```markdown
# Handoff: Stage 0N — <name>

## Artifact
- Path in repo: `<path to file the worker created>`
- Lines: <line count>
- Branch: `<branch name>`

## Summary
<2-3 sentences: what the worker produced>

## Checklist
- [ ] Has open questions: yes/no
- [ ] Includes test updates: yes/no
- [ ] Includes doc updates: yes/no
- [ ] Breaking changes: yes/no
{{STAGE_SPECIFIC_CHECKLIST_ITEMS}}

## Worker Status
- Exit: success/failed/partial
- Log excerpt: <last 5 lines of worker log>
```

The operator constructs handoff files from:
1. Worker log output (via `wait-for-worker.sh`)
2. GitHub API calls (`gh pr view`, `gh issue view`, etc.)
3. The worker's outcome marker

## Execution

1. **Parse arguments**

   ```bash
   TASK="$1"
   STAGE_START=1
   REVIEW_MODE=false

   for arg in "$@"; do
     case "$arg" in
       --stage) shift; STAGE_START="$1"; shift ;;
       --review) REVIEW_MODE=true; shift ;;
     esac
   done
   ```

2. **Create handoff directory**

   ```bash
   PROC_OUTPUT=".procedure-output/{{PROCEDURE_NAME}}"
   mkdir -p "$PROC_OUTPUT"
   ```

3. **Read CONTEXT.md** for the stage chain and shared context list.

4. **Run stages sequentially** starting from `$STAGE_START`:

   For each stage `0N-<name>`:

   a. Read `stages/0N-<name>/CONTEXT.md`

   b. **Load inputs** per the Inputs table:
      - Previous stage handoff: read from `$PROC_OUTPUT/0(N-1)-<prev>.md`
      - Reference material: read from `stages/0N-<name>/references/` or `shared/`

   c. **Execute Process steps.** The typical pattern for each stage:
      1. Prepare the worker prompt from the stage contract + prior handoff data
      2. Spawn worker: `bash scripts/spawn-worker.sh <env> <job_id> <session> <repo_dir> "<prompt>" <model>`
      3. Wait for worker: `bash scripts/wait-for-worker.sh <pid|container|arn> <log_file> <timeout>`
      4. Read worker log tail and outcome marker
      5. Verify result via GitHub API (check PR exists, issue state, labels, etc.)

   d. **Run Audit checks** if the stage has an Audit section:
      - Evaluate each pass condition using GitHub API or worker log data
      - If any check fails and is retriable: re-spawn worker with adjusted prompt
      - If not retriable: record failure in handoff, decide whether to continue or abort

   e. **Write handoff file** to `$PROC_OUTPUT/0N-<name>.md` with the structured format above

   f. **Checkpoint gate** (if stage has a Checkpoints section AND `$REVIEW_MODE` is true):
      - Post handoff summary to the mission log
      - Exit with: `[pylot] outcome="stage 0N complete, awaiting review" status=review`
      - Re-dispatch with `--stage (N+1)` after review

5. **Emit outcome marker** after all stages complete:

   ```
   [pylot] outcome="{{PROCEDURE_NAME}} complete: <summary of final deliverable>" status=success
   ```

## Resume from Stage N

When invoked with `--stage N`:

1. Skip stages 1 through N-1
2. Read their handoff files from `$PROC_OUTPUT/` -- they must exist
3. If prior handoffs are missing, exit with `status=failed` and report which handoff file is absent
4. Start execution at stage N using data from prior handoffs

## Review Gates

When invoked with `--review`:

- Stages WITHOUT a Checkpoints section run straight through
- Stages WITH a Checkpoints section pause after writing the handoff file:
  1. Post a summary describing what the worker produced and what the Checkpoints table says to review
  2. Exit with `status=review`

Without `--review`, all stages run straight through.

## Error Handling

**Worker fails** -- read the worker log. If the error is transient (timeout, network), retry the spawn (max 3 attempts per stage). If the error is structural (missing deps, blocked), record in handoff file and exit with `status=failed`.

**Prior handoff missing on resume** -- exit with `status=failed`. Report which handoff file is absent.

**Audit check fails after retries** -- exit with `status=partial`. Report which check fails, include worker log excerpt, list stages that completed successfully.

## Critical Rules

- **The operator dispatches, it does not implement.** Every code-touching action happens in a worker. The operator reads contracts, spawns workers, observes results, writes handoffs.
- **Handoff files describe artifacts, they do not contain them.** Path, line count, summary, checklist -- never the full content. The operator cannot access the worker repo.
- **Follow the stage contracts exactly.** The CONTEXT.md is the spec.
- **Load only what the Inputs table says.** Extra context dilutes quality.
- **Verify via GitHub API.** The operator checks PR state, labels, comments, issue state -- not repo files.
- **One stage at a time.** Do not read ahead to later stages.
- **Audit before handoff.** Never write the handoff file until audit checks pass.
