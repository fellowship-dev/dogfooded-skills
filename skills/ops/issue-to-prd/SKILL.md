---
name: issue-to-prd
description: ICM procedure — convert a new GitHub issue into a structured PRD, or post clarifying questions when the issue is underspecified. Triggered by the challenge-new-issue event rule.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, Task
---

# issue-to-prd

ICM procedure: convert a new GitHub issue into a structured PRD or post clarifying questions.

## Invocation
```
/issue-to-prd {repo} {issue_number}
```
Example: `/issue-to-prd fellowship-dev/pylot 123`

## When to use
- A new issue arrives and needs structuring (triggered by `challenge-new-issue` event rule)
- A human answered `open-questions` and re-challenge fires (triggered by `rechallenge-after-answers`)
- Manual invocation to structure a specific issue

## What it does
7-stage ICM procedure:
1. **01-read-issue** — fetch issue data (title, body, labels, comments)
2. **02-context-completeness** — audit implicit context gaps a fresh agent would miss
3. **03-assess-clarity** — check against 8-section gap checklist → `clear` or `needs-questions`
4. **04-failure-modes** — predict how an agent can go astray → guardrails for PRD
5. **05-test-plan** — test strategy + prerequisites (pre-merge and post-merge)
6. **06-ask-or-structure** — decision: post questions (exit) OR draft PRD
7. **07-publish** — rewrite issue body with PRD, apply labels

## Exit paths
- **Questions path** (stage 06): posts GH comment, adds `open-questions` label, stops
- **PRD path** (stage 07): rewrites issue body, adds `ready-to-work` + `challenged` labels

## Stage handoffs
Each stage writes to its `output/handoff.md`. Downstream stages read upstream handoffs.
All output directories at `stages/{stage}/output/`.

## Execution
Run stages sequentially. Read the CONTEXT.md for each stage before executing it.
After stage 06, skip stage 07 if questions were posted.

## Reference files
- `shared/prd-template.md` — PRD structure (used by stage 06)
- `shared/failure-modes.md` — common agent pitfall catalog (used by stage 04)
- `stages/03-assess-clarity/references/gap-checklist.md` — 8-section checklist
