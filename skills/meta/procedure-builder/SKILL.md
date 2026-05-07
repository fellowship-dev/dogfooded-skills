---
name: procedure-builder
description: Scaffold a multi-stage ICM procedure from a structured spec -- five-stage pipeline producing workflow map, stage contracts, folder scaffold, onboarding questionnaire, and validation report.
argument-hint: "[spec-file-path]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# procedure-builder

Build a complete ICM (Interpreted Context Methodology) procedure from a structured spec file. Follows the same five-stage pipeline as the ICM workspace-builder, producing the same intermediate artifacts at each stage.

## When to Use

- Building a new multi-stage workflow (speckit, deps-check, review pipeline, etc.)
- Converting an existing monolithic runner skill into a staged procedure
- Creating domain-specific procedures for a team repo (marketing, onboarding, etc.)

## When NOT to Use

- Single-step operations -- use a regular skill instead
- Interactive workflows that need human dialog at every step

## Prerequisites

```bash
test -f "$1" && echo "Spec found" || echo "ERROR: spec file not found"
grep -c '^## Stage' "$1"  # Must have at least 2 stages
```

The spec file must follow the format in `references/spec-format.md`.

## Procedure

This skill runs five stages sequentially, each producing an artifact that feeds the next. The stages mirror the ICM workspace-builder exactly.

Read `references/icm-conventions.md` before starting -- every convention applies.

### Stage 01: Discovery

**Same as ICM workspace-builder Stage 01, but reads a spec file instead of interviewing the user.**

**Input:** The spec file at `$1`.

**Process:**

1. Read the spec file completely
2. Extract the procedure name, one-line purpose, target directory, and arguments
3. For each stage in the spec, extract:
   - What goes in (files, API responses, arguments, previous stage output)
   - What comes out (the artifact this stage produces, its format)
   - What the agent needs to know (reference material, rules, constraints)
4. Identify shared context -- information used across multiple stages. These become files in `shared/`
5. Identify user-specific variables -- details that vary per installation or per team. These become `{{PLACEHOLDER}}` variables for the questionnaire
6. Identify optional stages -- stages some installations might skip. These become conditional sections
7. Identify tool prerequisites -- external tools needed (CLI tools, APIs, SDKs). Note which stages need them
8. Identify relevant skills -- existing Claude Code skills that provide domain knowledge for the procedure's stages. Scan `~/.claude/skills/` and `~/.agents/skills/` for candidates. List matches with a brief note on what each provides
9. Run the audit checks:
   - Every stage has a clear single responsibility and a named output artifact
   - Every stage's inputs are either user-provided, from shared context, or produced by a prior stage
   - Cross-stage resources (shared context) are listed separately from stage-specific references
   - Every user-specific detail is captured as a named placeholder variable

**Output:** Write `workflow-map.md` to the working directory. Structure:

```markdown
# Workflow Map: <procedure-name>

<One-line purpose>

## Target
- Directory: <target dir>
- Arguments: <invocation args>

## Stages
### 01-<name>
- Inputs: <list>
- Output: <artifact name and format>
- Agent needs: <reference material>
- Type: <creative | linear | build>

### 02-<name>
...

## Shared Context
- <name>: <description, which stages use it>

## User-Specific Variables
- {{VAR_NAME}}: <what it configures, which files it appears in>

## Optional Stages
- <stage>: <condition for removal>

## Tool Prerequisites
- <tool>: <which stages, required or optional>

## Selected Skills
- <skill-name>: <what it provides, which stages reference it>
```

### Stage 02: Mapping

**Same as ICM workspace-builder Stage 02.**

**Input:** `workflow-map.md` from Stage 01.

**Process:**

1. Read the workflow map
2. For each stage, write the formal Inputs/Process/Outputs contract following ICM Pattern 1 (Stage Contracts). Use the stage-context-template format:
   - Inputs table with selective section routing (specify which SECTION of a file, not just the file)
   - Numbered process steps -- concrete actions, not vague descriptions
   - Outputs table with artifact name, location, format
3. For each stage, determine:
   - Does it need a Checkpoint section? (creative stages: yes. linear stages: no)
   - Does it need an Audit section? (creative and build stages: yes. extraction/conversion: no)
4. Map cross-references: draw the dependency graph showing which stages read from which
5. Verify canonical sources: each piece of information has ONE home
6. Verify one-way references: if A references B, B does NOT reference A
7. Verify every stage's output is consumed by at least one downstream stage or is the final deliverable
8. Run the audit checks:
   - No circular references -- dependency graph flows one direction only
   - Every stage's output is consumed downstream or is the final deliverable
   - Every stage has Inputs, Process, and Outputs with no empty fields
   - No information is defined as authoritative in more than one place

**Output:** Write `stage-contracts.md` to the working directory. Structure:

```markdown
# Stage Contracts: <procedure-name>

## Dependency Diagram

01-name --> 02-name --> 03-name
              \--> shared/config.md

## Stage 01: <name>

### Inputs
| Source | File/Location | Section/Scope | Why |
...

### Process
1. ...

### Checkpoints (if applicable)
| After Step | Agent Presents | Human Decides |
...

### Audit (if applicable)
| Check | Pass Condition |
...

### Outputs
| Artifact | Location | Format |
...

## Stage 02: <name>
...
```

### Stage 03: Scaffolding

**Same as ICM workspace-builder Stage 03.**

**Input:** `stage-contracts.md` from Stage 02, `workflow-map.md` from Stage 01.

**Process:**

1. Read the stage contracts
2. Read the workflow map for tool prerequisites, selected skills, and shared context
3. Create the procedure folder structure:
   ```
   <name>/
   ├── SKILL.md
   ├── CONTEXT.md
   ├── setup/
   │   └── questionnaire.md    (placeholder -- populated in Stage 04)
   ├── stages/
   │   ├── 01-<name>/
   │   │   ├── CONTEXT.md
   │   │   ├── references/
   │   │   └── output/.gitkeep
   │   ├── 02-<name>/
   │   │   ├── CONTEXT.md
   │   │   ├── references/
   │   │   └── output/.gitkeep
   │   └── ...
   └── shared/
   ```
4. Write each stage CONTEXT.md from the contracts using the stage-context-template:
   - Title + one-sentence purpose
   - Inputs table (with selective section routing per ICM Pattern 4)
   - Process steps (concrete, numbered)
   - Checkpoints section (if stage type is creative -- delete section otherwise)
   - Audit section (if stage type is creative or build -- delete section otherwise)
   - Outputs table
   - **Hard cap: 80 lines.** Move content to `references/` if exceeded.
5. Write the procedure-level CONTEXT.md:
   - Task routing table
   - Stage chain table (stage, input from, output)
   - Shared context table
   - **Hard cap: 80 lines.**
6. Write the SKILL.md entry point using `templates/procedure-skill-template.md` as the base. Copy the template, then replace all `{{PLACEHOLDER}}` variables with values from the workflow map and contracts:
   - `{{PROCEDURE_NAME}}`, `{{PROCEDURE_TITLE}}`, `{{PROCEDURE_PURPOSE}}`, `{{PROCEDURE_DESCRIPTION}}`
   - `{{ARGUMENT_HINT}}`, `{{PRIMARY_ARG_DESCRIPTION}}`, `{{ADDITIONAL_ARGS}}`
   - `{{WHEN_TO_USE_BULLETS}}`, `{{PREREQUISITES}}`
   - `{{STAGE_N_NAME}}`, `{{STAGE_N_ARTIFACT}}` for each stage
   - The template handles: stage chain execution, output directory management, `--stage N` resume, `--review` checkpoint gates, error handling, and critical rules. Do not modify the execution, resume, or error handling sections -- they are standardized across all procedures.
7. Create placeholder reference files in `shared/` for each shared context item from the workflow map. Use `{{PLACEHOLDER}}` variables for user-specific content.
8. Create stage-specific reference files in `stages/NN/references/` where needed
9. If skills were identified, note them in the SKILL.md prerequisites. If they should be bundled (domain-specific knowledge), create a `skills/` folder and document the bundle.
10. If tool prerequisites were identified, write setup guides in the relevant stage's `references/` folder
11. Add `.gitkeep` in all `output/` directories
12. Run the audit checks:
    - Every stage has CONTEXT.md, `output/`, and `references/`
    - Every stage CONTEXT.md matches the contracts from Stage 02
    - All placeholders use `{{SCREAMING_SNAKE_CASE}}`
    - Every `output/` directory has `.gitkeep`
    - No CONTEXT.md exceeds 80 lines
    - All folders and files use `lowercase-with-hyphens`
    - Stage folders use zero-padded prefixes (`01-`, `02-`)

**Output:** The complete procedure folder written to the target directory.

### Stage 04: Questionnaire Design

**Same as ICM workspace-builder Stage 04.**

**Input:** `workflow-map.md` from Stage 01 (for user-specific variables), the scaffolded procedure from Stage 03.

**Process:**

1. Read the workflow map's user-specific variables section
2. Scan all markdown files in the scaffolded procedure for `{{PLACEHOLDER}}` patterns. Build a complete list.
3. Split variables into two buckets:
   - **System-level:** Things that stay the same across runs (API endpoints, credentials config, team identity, tool preferences). These become setup questions.
   - **Per-run:** Things that change each pipeline run (issue number, repo, target branch). These do NOT become setup questions -- the SKILL.md collects them as arguments.
4. For each system-level placeholder, write a question:
   - Question text (plain English, non-technical)
   - The placeholder(s) it populates
   - The files where those placeholders appear
   - Input type (free text, selection, yes/no)
   - A sensible default or example
5. For yes/no questions about optional stages: specify which stage folder to remove if NO
6. Write ALL questions as a flat numbered list -- no category groupings
7. Verify every system-level placeholder has a corresponding question
8. Verify per-run variables are handled by SKILL.md arguments, not the questionnaire
9. Run the audit checks:
   - Every system-level placeholder has a question
   - No per-run variables in the questionnaire
   - Flat structure (no category groupings)
   - Every question has a default or example

**Output:** Write `setup/questionnaire.md` in the procedure folder, following the questionnaire-template format.

If the procedure has NO user-specific variables (pure system procedure with no configuration), write a minimal questionnaire that says "No configuration needed" and skip placeholder replacement.

### Stage 05: Validation

**Same as ICM workspace-builder Stage 05. All 13 checks.**

**Input:** The scaffolded procedure from Stage 03, the questionnaire from Stage 04.

**Process:**

Run each check. Record pass/fail and issues found.

1. **Cross-reference integrity.** Every file path in any CONTEXT.md Inputs table must point to a real file. List broken references.

2. **No circular dependencies.** Trace the reference graph. Confirm it is a directed acyclic graph.

3. **Placeholder coverage.** Scan all files for `{{PLACEHOLDER}}` patterns. Every placeholder must have a question in the questionnaire. Every question must map to at least one file. List orphans.

4. **Conditional section validity.** Every `{{?SECTION}}...{{/SECTION}}` block wraps a complete section (heading + content). No inline conditionals.

5. **Stage handoff chain.** Stage N's output location matches Stage N+1's Inputs table reference. List the chain, flag gaps.

6. **CONTEXT.md purity.** No CONTEXT.md contains actual reference content. Only: title, description, Inputs table, Process steps, Checkpoints (optional), Audit (optional), Outputs table.

7. **Checkpoints in creative stages.** Creative stages have at least one checkpoint. Checkpoint tables reference valid step numbers.

8. **Audits in creative/build stages.** Creative and build stages have Audit sections with specific pass conditions.

9. **Contract purity.** Spec stages define WHAT and WHEN, not HOW. No implementation details in spec outputs.

10. **Line count check.** Flag any CONTEXT.md over 80 lines. Flag any reference file over 200 lines.

11. **Naming conventions.** `lowercase-with-hyphens`. Zero-padded stage prefixes. `.gitkeep` in empty `output/` folders.

12. **Tool prerequisites.** If tool setup guides exist: each listed tool has a guide, guides include install steps and verification commands.

13. **Quality scan.** No em dashes (replace with `--`). No jargon without explanation. Clean markdown formatting.

Fix any failures in the scaffolded procedure, then re-run the failed checks.

**Output:** Write `validation-report.md` to the working directory. Format:

```markdown
# Validation Report: <procedure-name>

## Results

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | Cross-reference integrity | PASS/FAIL | <details> |
| 2 | No circular dependencies | PASS/FAIL | <details> |
| ... | ... | ... | ... |
| 13 | Quality scan | PASS/FAIL | <details> |

## Issues Fixed
- <description of fix>

## Summary
<N>/13 checks passed. <Procedure is ready / Issues remain.>
```

## Error Handling

**Spec has fewer than 2 stages** -- stop. A single-stage process is a skill, not a procedure.

**Stage CONTEXT.md exceeds 80 lines** -- move content to `references/`. This is a hard cap.

**Circular dependency found** -- report the cycle. The spec must be restructured.

**Validation check fails after fix attempt** -- report the failure. Do not ship with known failures.

## Critical Rules

- **Follow every ICM convention.** All 15 patterns from CONVENTIONS.md apply. Do not skip any.
- **Produce all five artifacts.** workflow-map.md, stage-contracts.md, the procedure folder, questionnaire.md, validation-report.md. Even if a stage seems trivial, produce its artifact.
- **80-line CONTEXT.md cap is hard.** Not a guideline. Move content to references.
- **200-line reference file cap is hard.** Split if exceeded.
- **Selective section routing.** Inputs tables specify which SECTION to load, not just file paths.
- **Working artifacts in repo, not skill.** Output path: `$REPO_DIR/.procedure-output/<name>/`.
- **No em dashes.** Use `--`.
- **Every validation check must pass.** Do not report success with known failures.
- **Templates are mandatory.** Use the stage-context-template and questionnaire-template formats from `_core/templates/`. Do not invent your own format.
