---
name: setup-speckit
description: Install Spec-Kit (Specification-Driven Development) into any repository. Copies slash commands, templates, scripts, and optionally creates a project constitution. Use when setting up speckit, initializing SDD, adding spec-driven workflow, or bootstrapping a new repo for speckit.
user-invocable: true
allowed-tools: Bash, Glob, Grep, Read, Write
---

# Setup Spec-Kit

Install Spec-Kit into a target repository, enabling the full Specification-Driven Development (SDD) pipeline: specify → clarify → plan → tasks → implement → analyze → checklist → constitution.

## When to Use

- Bootstrapping a new repo for speckit workflows
- Adding SDD to an existing project

## Source Forks

| Fork | Repo | Notes |
|------|------|-------|
| **fellowship-dev** (default) | [fellowship-dev/spec-kit](https://github.com/fellowship-dev/spec-kit) | Leaner, fewer tokens, opinionated defaults |
| upstream | [github/spec-kit](https://github.com/github/spec-kit) | Original, more verbose, higher token cost |

Default to the fellowship-dev fork. If the user explicitly requests the upstream version, warn that it uses significantly more tokens per invocation due to longer templates and prompts.

## Prerequisites

- Git available in the target repo
- Target repo has a `.claude/` directory (run `setup-harness` first if not)

## What Gets Installed

```
target-repo/
├── .specify/
│   ├── scripts/bash/          # create-new-feature.sh, setup-plan.sh, common.sh, etc.
│   ├── templates/             # spec, plan, tasks, checklist, constitution templates
│   └── memory/
│       └── constitution.md    # Project principles (customized or default)
├── .claude/commands/
│   ├── speckit.specify.md     # /speckit.specify <issue-number>
│   ├── speckit.plan.md        # /speckit.plan
│   ├── speckit.tasks.md       # /speckit.tasks
│   ├── speckit.implement.md   # /speckit.implement
│   ├── speckit.clarify.md     # /speckit.clarify
│   ├── speckit.checklist.md   # /speckit.checklist
│   ├── speckit.analyze.md     # /speckit.analyze
│   └── speckit.constitution.md
└── specs/                     # Created per-feature by /speckit.specify
```

## Installation Steps

### 1. Clone Spec-Kit to a temp directory

```bash
# Default: fellowship-dev fork (leaner, recommended)
SPECKIT_SRC=$(mktemp -d)
git clone --depth 1 https://github.com/fellowship-dev/spec-kit.git "$SPECKIT_SRC"

# Alternative: upstream (more verbose, higher token cost)
# git clone --depth 1 https://github.com/github/spec-kit.git "$SPECKIT_SRC"
```

### 2. Create target directories

```bash
mkdir -p .specify/scripts/bash .specify/templates .specify/memory
mkdir -p .claude/commands
mkdir -p specs
```

### 3. Copy scripts

```bash
cp "$SPECKIT_SRC"/scripts/bash/*.sh .specify/scripts/bash/
chmod +x .specify/scripts/bash/*.sh
```

### 4. Copy templates

```bash
cp "$SPECKIT_SRC"/templates/spec-template.md .specify/templates/
cp "$SPECKIT_SRC"/templates/plan-template.md .specify/templates/
cp "$SPECKIT_SRC"/templates/tasks-template.md .specify/templates/
cp "$SPECKIT_SRC"/templates/checklist-template.md .specify/templates/
cp "$SPECKIT_SRC"/templates/constitution-template.md .specify/templates/
```

### 5. Copy Claude Code slash commands

```bash
cp "$SPECKIT_SRC"/templates/commands/specify.md .claude/commands/speckit.specify.md
cp "$SPECKIT_SRC"/templates/commands/plan.md .claude/commands/speckit.plan.md
cp "$SPECKIT_SRC"/templates/commands/tasks.md .claude/commands/speckit.tasks.md
cp "$SPECKIT_SRC"/templates/commands/implement.md .claude/commands/speckit.implement.md
cp "$SPECKIT_SRC"/templates/commands/clarify.md .claude/commands/speckit.clarify.md
cp "$SPECKIT_SRC"/templates/commands/checklist.md .claude/commands/speckit.checklist.md
cp "$SPECKIT_SRC"/templates/commands/analyze.md .claude/commands/speckit.analyze.md
cp "$SPECKIT_SRC"/templates/commands/constitution.md .claude/commands/speckit.constitution.md
```

### 6. Initialize constitution

If the project doesn't have a constitution yet:

```bash
cp .specify/templates/constitution-template.md .specify/memory/constitution.md
```

Ask the user if they want to customize it now or use the default. Key decisions:
- Test-first vs test-after
- Library-first preference
- Max complexity per feature
- Framework-specific principles

### 7. Clean up

```bash
rm -rf "$SPECKIT_SRC"
```

### 8. Ensure required GitHub labels exist

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

gh label create "in-progress" --repo "$REPO" --color "97f157" --description "Issue is actively being worked on" 2>/dev/null || true
gh label create "ready-to-work" --repo "$REPO" --color "f6a80a" --description "PRD complete, ready for implementation" 2>/dev/null || true
```

### 9. Verify installation

```bash
ls .specify/scripts/bash/*.sh      # Scripts present and executable
ls .specify/templates/*.md         # Templates present
ls .claude/commands/speckit.*.md   # Slash commands present
cat .specify/memory/constitution.md # Constitution initialized
gh label list --repo "$REPO" | grep -E "in-progress|ready-to-work"
```

## Post-Install

- Run `/speckit.constitution` to customize principles for this project
- The repo is now ready for `/speckit.specify <issue-number>` workflows

## SDD Philosophy (Terse)

- Specs ≤50 lines, bullets only
- Plans ≤50 lines, table-driven decisions
- Tasks ≤40 lines, checkboxes, no prose
- Constitution enforces principles (test-first, library-first, simplicity)
- Branch naming: `<issue-number>-<short-name>`
