# Stage 07: Publish

## Inputs
- `stages/06-ask-or-structure/output/handoff.md` (PRD draft)
- `stages/05b-prototype-gate/output/handoff.md` (verdict — gates one label below)
- Issue number + repo

## Precondition
Stage 06 produced a PRD draft. Do NOT run if stage 06 exited early (questions path).
Stage 00 returned `proceed` — this stage rewrites the body, and that is exactly what the guard
protects `no-automation` / `epic` issues from.

## Task
Rewrite the issue body with the PRD and apply final labels.

## Steps
1. Read stage 06 handoff — verify it contains a PRD (not a questions list)
2. Edit the issue body: `gh issue edit {number} --repo {repo} --body "{prd_content}"`
3. Add labels:
   - `gh issue edit {number} --repo {repo} --add-label "prd-ready"`
   - `gh issue edit {number} --repo {repo} --add-label "ready-to-work"` — **unless** stage 05b's
     verdict is `dispatch` or `already-dispatched` (see below)
4. Write confirmation to `stages/07-publish/output/handoff.md`

### The pending-variants interlock

When prototype variants are in flight, the design basis does not exist yet. `ready-to-work` is what
deep-triage greenlights from and the dispatch loop works off — applying it now sends an
implementer to build a screen whose shape is still an open question, and the variants land on a
half-built feature.

So: 05b verdict `dispatch` or `already-dispatched` → add `prd-ready` **only**. The next
`issue-to-prd` pass, after the owner replies `variant: B`, sees verdict `picked`, folds the variant
into the PRD, and applies `ready-to-work` then.

This withholds a label; it never removes one. If `ready-to-work` is already on the issue, leave it
— label removal is not this skill's business.

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
- `prd-ready` applied; `ready-to-work` applied **unless** variants are pending (see interlock)
- `open-questions` label NOT present (guard: only run when stage 06 is PRD path)
