# ICM Conventions Reference

Condensed reference for the procedure-builder. Canonical source: `_core/CONVENTIONS.md` in any ICM-enabled repo.

Source: [Interpreted Context Methodology](https://github.com/RinDig/Interpreted-Context-Methdology) by Jake Van Clief.

## Five-Layer Routing

```
Layer 0: SKILL.md / CLAUDE.md  -> "Where am I?"           (entry point, auto-loaded)
Layer 1: CONTEXT.md            -> "Where do I go?"          (read on entry)
Layer 2: Stage CONTEXT.md      -> "What do I do?"           (read per-stage)
Layer 3: Reference material    -> "What rules apply?"       (loaded selectively)
Layer 4: Working artifacts     -> "What am I working with?" (loaded selectively)
```

Layer 3 = persistent context (conventions, rules, design systems). Stays stable across runs.
Layer 4 = per-run context (previous stage outputs, source material). Changes every run.

Every token of irrelevant context dilutes attention. Load the minimum.

## 15 Patterns

1. **Stage contracts** -- every stage has Inputs table, Process steps, Outputs table. No exceptions.
2. **Handoffs via output folders** -- Stage N writes to `output/`, Stage N+1 reads from there.
3. **One-way cross-references** -- A references B, B never references A.
4. **Selective section routing** -- Inputs tables specify which SECTION to load, not just the file.
5. **Canonical sources** -- every fact has ONE home. Others point to it.
6. **CONTEXT.md = routing only** -- no definitions, rules, or examples. Under 80 lines.
7. **Tool prerequisites** -- setup guides in `references/` of the stage that needs them.
8. **Questionnaire design** -- flat, all-at-once, system-level only, derive don't ask, sensible defaults, ask once never again, examples over descriptions.
9. **Bundled skills** -- procedure can include skills in `skills/` folder for domain knowledge.
10. **Specs are contracts** -- define WHAT and WHEN, not HOW.
11. **Checkpoints** -- optional human review gates in creative stages.
12. **Stage audits** -- quality checks before output is written. Specific pass conditions.
13. **Value validation** -- content stages define value types to prevent useless output.
14. **Docs over outputs** -- reference docs are authoritative, not previous outputs.
15. **Shared constants** -- configurable values in shared files, not hardcoded.

## Templates

These templates are the canonical starting points for generated files. They live in `_core/templates/` in any ICM-enabled repo.

### Stage CONTEXT.md Template

```markdown
# [Stage Name]

[One sentence: what this stage does.]

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `../0N-prev/output/artifact.md` | Full file | The artifact to work from |
| Reference | `references/example.md` | "Relevant Section" | What it provides |

## Process

1. Read the input artifact from the previous stage
2. [Step two]
3. [Step three]
4. Save to output/

## Checkpoints

| After Step | Agent Presents | Human Decides |
|------------|---------------|---------------|
| [step #] | [what to show] | [what to choose] |

## Audit

| Check | Pass Condition |
|-------|---------------|
| [Check name] | [What "passing" looks like] |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| [Name] | `output/[slug]-[type].md` | [Description] |
```

Delete Checkpoints or Audit sections if the stage does not need them.

### Questionnaire Template

```markdown
# Onboarding Questionnaire

### Q1: [Question text]
- Placeholder: `{{PLACEHOLDER_NAME}}`
- Files: `path/to/file1.md`, `path/to/file2.md`
- Type: free text
- Default: [Default value if user wants to skip]

### Q2: [Question text]
- Placeholder: `{{PLACEHOLDER_NAME}}`
- Files: `path/to/file.md`
- Type: selection
- Options: Option A, Option B, Option C

### Q3: [Optional feature question]
- Type: yes/no
- If NO: Remove `stages/0N-name/` entirely
- If YES: Keep it
```

Questionnaire rules:
1. Flat structure -- no category groupings, just numbered questions
2. All at once -- user answers everything in one message
3. System-level only -- per-run details are collected by the entry stage, not the questionnaire
4. Derive, don't ask -- if a field can be inferred from another answer, fill it in
5. Sensible defaults -- every question has a default or example
6. Ask once, never again -- answers are baked into files permanently
7. Examples over descriptions -- ask for concrete examples, not abstract descriptions

## Quality Guardrails

- CONTEXT.md: under 80 lines (hard cap)
- Reference files: under 200 lines (split if longer)
- Plain English, no jargon
- No em dashes (use `--`)
- Empty persistent folders get `.gitkeep`
- Folders and files: `lowercase-with-hyphens`
- Stage folders: `01-`, `02-`, `03-` (zero-padded)
- Placeholders: `{{SCREAMING_SNAKE_CASE}}`
- Conditional sections: `{{?SECTION}}...{{/SECTION}}` wraps entire sections only

## Skill Integration

- **SKILL.md replaces CLAUDE.md** as the Layer 0 entry point. Procedures are skills with ICM internal structure.
- **Checkpoints become optional review gates.** Controlled by `--review` flag at invocation.
- **Stage artifacts live in `.procedure-output/<name>/`.** Written in the working directory. One file per stage: `01-<name>.md`, `02-<name>.md`, etc.
- **Questionnaires still apply.** Domain procedures (marketing, onboarding) need system-level config via `setup/questionnaire.md`.
- **Process steps are procedure-specific.** Each procedure defines its own stage logic -- the runtime does not prescribe how work is done, only that contracts are followed.

## Validation Checks (13 total)

1. Cross-reference integrity (all file paths resolve)
2. No circular dependencies (DAG only)
3. Placeholder coverage (every placeholder has a question)
4. Conditional section validity (wrap complete sections)
5. Stage handoff chain (unbroken N to N+1)
6. CONTEXT.md purity (routing only, no content)
7. Checkpoints in creative stages
8. Audits in creative/build stages
9. Contract purity (WHAT/WHEN, not HOW)
10. Line count check (80/200 caps)
11. Naming conventions
12. Tool prerequisites (guides exist, install + verify)
13. Quality scan (no em dashes, no jargon, clean markdown)
