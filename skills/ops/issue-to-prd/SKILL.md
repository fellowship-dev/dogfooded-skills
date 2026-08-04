---
name: issue-to-prd
description: Use when converting a new GitHub issue into a structured PRD, or posting clarifying questions when the issue is underspecified.
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
10-stage ICM procedure:

0. **00-automation-guard** — refuse `no-automation` / `epic` / closed issues, before reading anything
1. **01-read-issue** — fetch issue data (title, body, labels, comments)
2. **02-context-completeness** — audit implicit context gaps a fresh agent would miss
3. **03-assess-clarity** — check against 8-section gap checklist → `clear` or `needs-questions`
4. **04-failure-modes** — predict how an agent can go astray → guardrails for PRD
5. **05-test-plan** — test strategy + prerequisites (pre-merge and post-merge)
6. **05b-prototype-gate** — is this UI exploration? → `skip` / `ask` / `dispatch` / `picked`
7. **05c-outcomes-baseline** — fetch `GET /outcomes/summary` for real metric baselines (fail-open)
8. **06-ask-or-structure** — decision: post questions (exit) OR draft PRD (includes Measurable Impact)
9. **07-publish** — rewrite issue body with PRD, apply labels

## Exit paths
- **Guard path** (stage 00): no reads, no writes, `status=success`, stops
- **Questions path** (stage 06): posts GH comment, adds `open-questions` label, stops
- **PRD path** (stage 07): rewrites issue body, adds `prd-ready` (+ `ready-to-work` unless
  prototype variants are pending)

## Prototype variants
Stage 05b can dispatch a mission that pushes `proto/<issue>-a|b|c` branches and posts one options
comment with screenshots and boot instructions, for the owner to pick from. It is gated hard:
**auto-detection can only ever ask a question; only an explicit owner signal** (the
`prototype-options` label, or a "build the prototype" answer) **dispatches.** See
`stages/05b-prototype-gate/CONTEXT.md`.

## Stage handoffs
Each stage writes to its `output/handoff.md`. Downstream stages read upstream handoffs.
All output directories at `stages/{stage}/output/`.

## Execution
Run stages sequentially. Read the CONTEXT.md for each stage before executing it.
Stage 00 is a hard gate — if it aborts, run nothing else.
Stage 05c always runs (fail-open) — it never gates stage 06.
After stage 06, skip stage 07 if questions were posted.

## Reference files
- `shared/prd-template.md` — PRD structure (used by stage 06); includes `## Measurable Impact` section
- `shared/failure-modes.md` — common agent pitfall catalog (used by stage 04)
- `shared/prototype-mission-brief.md` — self-contained brief for the variant mission (stage 05b)
- `stages/03-assess-clarity/references/gap-checklist.md` — 8-section checklist
- `stages/05b-prototype-gate/references/gate-checklist.md` — prototype gate + worked classifications
- `stages/05c-outcomes-baseline/CONTEXT.md` — outcomes API call + fail-open baseline formatting
