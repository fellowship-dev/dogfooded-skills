---
name: build-prd
description: Guide collaborative PRD creation from feature requests — 7-step workflow with structured discussion, GitHub integration, and quality gates. Use when creating PRDs, writing requirements, or transforming feature requests into implementation-ready issues.
allowed-tools: Read, Bash, Grep, Glob
---

# build-prd

Create a Product Requirements Document through collaborative discussion with the user, ending with a complete GitHub issue ready for implementation.

## When to Use

- User asks to "create a PRD" or "write requirements"
- Working from a GitHub issue labeled `feature-request` or `enhancement`
- User needs to document requirements before implementation
- Transforming a vague idea into a structured, implementable spec

## When NOT to Use

- Issue already has a complete PRD (check for `[PRD]` prefix in title)
- Pure bug reports — those need reproduction steps, not requirements
- Implementation is already underway — write a spec retroactively instead

## Prerequisites

```bash
gh auth status        # GitHub CLI authenticated
gh repo view          # Inside a valid repo (or org/repo provided)
```

## Workflow

### Step 1: Understand the request

If triggered from a GitHub issue:
```bash
gh issue view ISSUE_NUMBER --repo ORG/REPO
```

Read project context:
```bash
cat project-instructions.md  # or equivalent project instructions file
cat README.md
```

Articulate the core request in 1-2 sentences. If you can't, ask the user to clarify before continuing.

### Step 2: Identify gaps

Check the request against required PRD sections:

| Section | Required? | Source |
|---------|-----------|--------|
| Problem Statement | Yes | Why does this matter? |
| User Stories | Yes | Who needs it and why? |
| Success Metrics | Yes | How do we measure success? |
| Scope (in + out) | Yes | What's included and excluded? |
| Technical Constraints | Yes | Limitations, integrations, patterns? |
| Mockups/Examples | No | Visual references if available |
| Dependencies | No | Related features or systems |
| Timeline | No | Priority or deadline |

Build a list of questions for anything missing.

### Step 3: Ask all questions in one batch

```text
To create a complete PRD, I need some additional information:

Q1: [specific question]
Q2: [specific question]
Q3: [specific question]
Q4 (Optional): [nice-to-have question]
```

> **Warning:** Ask ALL questions at once. Do not drip-feed one question at a time — that wastes the user's time and breaks flow.

If working from a GitHub issue, add the `question` label:
```bash
gh issue edit ISSUE_NUMBER --repo ORG/REPO --add-label "question"
```

Wait for user responses before proceeding.

### Step 4: Draft the PRD

Use this template — replace ALL placeholders with actual content:

```markdown
# [Feature Name]

## Problem Statement
[2-3 sentences: what user problem this solves and why it matters now]

## User Stories
- As a [user type], I want [goal] so that [benefit]
- As a [user type], I want [goal] so that [benefit]

## Success Metrics
- [Metric]: [specific target or measurement approach]
- [Metric]: [specific target or measurement approach]

## Scope

### In Scope
- [Concrete feature or deliverable]
- [Concrete feature or deliverable]

### Out of Scope
- [Explicitly excluded item — prevents scope creep]
- [Explicitly excluded item]

## Technical Requirements
- [Requirement referencing existing codebase patterns]
- [Constraint or integration point]

## Dependencies
- [Related system or feature, if any]

## Open Questions
- [Anything unresolved — do not guess]

## Implementation Notes
[Architectural decisions, patterns to follow, files to reference]
```

### Step 5: Review with user

Present the full PRD draft. Highlight assumptions:

```text
I've drafted a PRD based on our discussion. Please review:

[FULL PRD]

Assumptions I made:
- [Assumption 1]
- [Assumption 2]

Does this capture everything? Anything to change?
```

> **Warning:** NEVER proceed to Step 6 without explicit user approval. "Looks good" or "yes" counts. Silence does not.

### Step 6: Update the GitHub issue

Only after user approval:

```bash
gh issue edit ISSUE_NUMBER --repo ORG/REPO \
  --body "$(cat /tmp/prd-draft.md)" \
  --title "[PRD] Feature Name" \
  --add-label "ready-to-work"

gh issue edit ISSUE_NUMBER --repo ORG/REPO --remove-label "question" 2>/dev/null || true
```

| Label | Action |
|-------|--------|
| `ready-to-work` | Add — signals PRD is complete |
| `question` | Remove if present |
| `feature-request`, `enhancement` | Keep — preserve original labels |

### Step 7: Confirm

```bash
gh issue comment ISSUE_NUMBER --repo ORG/REPO \
  --body "PRD created. Issue updated with complete requirements. Ready for implementation planning."
```

## Error Handling

**User unsure about scope** — propose MVP: include only what's essential for core value, move everything else to "Out of Scope (future)".

**Scope too broad** — suggest splitting into multiple PRDs, each focused on one capability. Start with the foundational one.

**User provides implementation details instead of requirements** — redirect: "Before implementation, let's clarify: what problem does this solve? What should users be able to do that they can't now?"

**Missing success metrics** — suggest based on feature type:

| Feature Type | Suggested Metrics |
|-------------|-------------------|
| User-facing | Adoption rate, usage frequency, satisfaction |
| Performance | Latency reduction, error rate decrease |
| Developer tool | Time saved, code quality improvement |
| Infrastructure | Uptime, cost reduction, incident frequency |

## Critical Rules

- **Never update a GitHub issue without explicit user approval** — the PRD is a contract
- **Never make up technical details** — mark unknowns as Open Questions
- **Batch all questions** — one message, numbered Q1-Qn
- **No placeholder text in final PRD** — every bracket must be replaced
- **Preserve original labels** — only add `ready-to-work`, never remove `feature-request` or `enhancement`
