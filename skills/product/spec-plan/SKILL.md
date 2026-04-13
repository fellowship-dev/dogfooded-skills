---
name: spec-plan
description: Interview the user relentlessly about a plan or design until reaching shared understanding — walk each branch of the decision tree, resolve dependencies one by one. Use when stress-testing a plan, getting grilled on a design, or before writing a PRD.
allowed-tools: Read, Bash, Grep, Glob
---

<!-- Original "grill me" concept by Matt Pocock (https://x.com/maaboroshi) -->

# spec-plan

Interview the user relentlessly about every aspect of a plan until reaching shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one by one.

## When to Use

- User wants to stress-test a plan or design
- User says "grill me" or "poke holes in this"
- Before running `build-prd` — spec-plan resolves ambiguity, build-prd structures the output
- Complex feature with many interacting decisions that need to be resolved sequentially

## When NOT to Use

- Requirements are already clear and documented — go straight to `build-prd`
- User just wants a quick opinion, not a deep interview
- Implementation is already underway

## Workflow

### 1. Read existing context

If the plan originates from a GitHub issue:
```bash
gh issue view ISSUE_NUMBER --repo ORG/REPO --json body,title,comments
```

Read all comments too — treat existing questions and answers as already-resolved branches. Do not re-ask anything already answered.

If no issue, read project context:
```bash
cat project-instructions.md  # or equivalent project instructions file
cat README.md
```

### 2. Interview — one question at a time

For each branch of the design tree:
- Ask one question
- Provide your recommended answer with reasoning
- Wait for the user's response
- Incorporate the answer and move to the next branch

> **Warning:** ONE question at a time. This is not build-prd's batched Q1-Qn format. Go deep on each branch before moving to the next.

If a question can be answered by exploring the codebase, explore the codebase instead of asking.

### 3. Resolve dependencies

When decisions depend on each other, resolve the dependency first:
- Identify which decision blocks others
- Ask about the blocker first
- Then proceed to the dependent decisions

### 4. Handoff to build-prd (optional)

When all branches are resolved, offer:

```text
All branches resolved. Want me to run /build-prd to structure this into a PRD?
```

If yes, the shared understanding from this interview becomes the input — build-prd can skip its discussion phase (Steps 1-3) and go straight to drafting.

## Critical Rules

- **One question at a time** — depth over breadth
- **Always provide your recommended answer** — don't just ask, propose
- **Never re-ask resolved questions** — read issue comments first
- **Explore code before asking** — if the codebase has the answer, use it
- **Start from where the conversation left off** — respect prior discussion
