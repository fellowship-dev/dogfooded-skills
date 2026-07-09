# Stage 07: Publish

## Inputs
- `stages/06-ask-or-structure/output/handoff.md` (PRD draft)
- Issue number + repo

## Precondition
Stage 06 produced a PRD draft. Do NOT run if stage 06 exited early (questions path).

## Task
Rewrite the issue body with the PRD and apply final labels.

## Steps
1. Read stage 06 handoff — verify it contains a PRD (not a questions list)
2. Edit the issue body: `gh issue edit {number} --repo {repo} --body "{prd_content}"`
3. Add labels:
   - `gh issue edit {number} --repo {repo} --add-label "ready-to-work"`
   - `gh issue edit {number} --repo {repo} --add-label "prd-ready"`
4. Write confirmation to `stages/07-publish/output/handoff.md`

## Output: handoff.md
```markdown
# Stage 07: Publish

## Status
Published

## Actions taken
- Issue body rewritten with PRD
- Labels added: ready-to-work, prd-ready

## Issue URL
{url}
```

## Success criteria
- Issue body contains PRD structure (## Problem Statement visible)
- Labels `ready-to-work` and `prd-ready` both applied
- `open-questions` label NOT present (guard: only run when stage 06 is PRD path)
