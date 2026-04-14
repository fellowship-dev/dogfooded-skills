---
name: setup-github
description: Set up GitHub project board, labels, and Actions workflows for a repository. Creates standard workflow/type labels (including reviewed, double-checked, approved, needs-work), installs the claude-code-review workflow, and explains the full double-check → cto-review pipeline.
user-invocable: false
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
---

# GitHub Setup Assistant

Set up a complete GitHub environment for a repository: project board, labels, and Actions workflows. Each phase is idempotent — existing configuration is detected and skipped.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/ops/setup-github
```

**IMPORTANT**: Always verify the Claude GitHub App is installed (https://github.com/apps/claude) BEFORE installing Claude-powered workflows. Without the app, workflows will fail with authentication errors.

## When to Use

- Setting up a new repo's GitHub environment end-to-end
- Adding the automated review pipeline (double-check → cto-review)
- Creating standard labels for workflow tracking
- Installing CI/CD workflows

## The Review Pipeline

This skill sets up the automated 3-stage PR review pipeline:

```
1. PR opened
        ↓
2. GitHub Actions: claude-code-review.yml
   - Claude reviews the diff
   - Applies "reviewed" label
        ↓
3. event-rules.yml: review-pr-on-reviewed
   - /double-check PR_NUMBER org/repo dispatched
   - Curates CI findings, fixes must-fix items
   - Applies "double-checked" label
        ↓
4. event-rules.yml: cto-review-on-double-checked
   - /cto-review PR_NUMBER org/repo dispatched
   - Docs/deps/downstream checklist
   - Applies "approved" or "needs-work" label
   - Merges if approved
```

Skills powering stages 3-4: `double-check` and `cto-review` from `fellowship-dev/dogfooded-skills`.

---

## Prerequisites: Claude GitHub App

Before using Claude-powered workflows, install the Claude GitHub App:

1. **Install**: https://github.com/apps/claude — select your repository or org
2. **Authentication** (choose ONE):

   **Option A: OAuth Token via Claude CLI (Recommended)**
   ```bash
   unset GH_TOKEN
   gh auth login
   claude
   /install-github-app
   # Select repo → "long-lived token" → auto-adds CLAUDE_CODE_OAUTH_TOKEN secret
   ```

   **Option B: API Key**
   - Get key: https://console.anthropic.com/settings/keys
   - Add as secret `ANTHROPIC_API_KEY` at: https://github.com/{owner}/{repo}/settings/secrets/actions

---

## Instructions

### 1. Detection Phase

Analyze the repository:

```bash
# Repo identity
gh repo view --json nameWithOwner

# Existing labels
gh label list --repo $REPO --json name

# Existing workflows
ls .github/workflows/ 2>/dev/null || echo "No workflows"

# Project board
gh project list --owner $ORG --format json 2>/dev/null | head -20
```

Report a status table: what exists vs. what's missing.

### 2. Labels Phase

**Skip labels that already exist** (idempotent). Create via `gh label create`:

**Workflow Labels (for PR pipeline):**
| Label | Color | Description |
|-------|-------|-------------|
| `reviewed` | `#3da46e` | CI/automated review complete |
| `double-checked` | `#0075ca` | Full review + fixes complete |
| `approved` | `#0e8a16` | CTO approved — ready to merge |
| `needs-work` | `#d93f0b` | Needs work before merge |
| `ready-to-work` | `#f6a80a` | Ready for implementation |
| `in-progress` | `#97f157` | Actively being worked on |

**Type Labels:**
| Label | Color | Description |
|-------|-------|-------------|
| `bug` | `#d73a4a` | Something isn't working |
| `enhancement` | `#54d9ee` | New feature or improvement |
| `documentation` | `#0075ca` | Documentation only |
| `groundwork` | `#C5DEF5` | Infra/tooling/refactoring |

```bash
# Create all labels (idempotent — 2>/dev/null suppresses "already exists" errors)
gh label create "reviewed" --repo $REPO --color "3da46e" --description "CI/automated review complete" 2>/dev/null || true
gh label create "double-checked" --repo $REPO --color "0075ca" --description "Full review + fixes complete" 2>/dev/null || true
gh label create "approved" --repo $REPO --color "0e8a16" --description "CTO approved — ready to merge" 2>/dev/null || true
gh label create "needs-work" --repo $REPO --color "d93f0b" --description "Needs work before merge" 2>/dev/null || true
gh label create "ready-to-work" --repo $REPO --color "f6a80a" --description "Ready for implementation" 2>/dev/null || true
gh label create "in-progress" --repo $REPO --color "97f157" --description "Actively being worked on" 2>/dev/null || true
gh label create "bug" --repo $REPO --color "d73a4a" --description "Something isn't working" 2>/dev/null || true
gh label create "enhancement" --repo $REPO --color "54d9ee" --description "New feature or improvement" 2>/dev/null || true
gh label create "documentation" --repo $REPO --color "0075ca" --description "Documentation only" 2>/dev/null || true
gh label create "groundwork" --repo $REPO --color "C5DEF5" --description "Infra/tooling/refactoring" 2>/dev/null || true
```

Report: "Created N labels, skipped N (already existed)."

### 3. Project Board Phase

**Skip if** a GitHub Project already exists for this repo.

```bash
# Create project
gh project create --owner $ORG --title "$REPO_NAME"

# Add Status field with standard columns
# (Use GitHub UI to configure Status options — API support is limited)
# Columns: Backlog → Ready → In Progress → In Review → Done

# Link repo to project
gh project link $PROJECT_NUMBER --owner $ORG --repo $REPO
```

Note: Configure auto-move automations in the GitHub Projects UI:
- Auto-move to "In Review" when PR opened
- Auto-move to "Done" when PR merged or issue closed

### 4. Workflow Installation Phase

**Skip workflows that already exist** in `.github/workflows/`.

Present available workflows and wait for confirmation:

#### AI-Powered Workflows (require Claude GitHub App)
- **claude-code-review.yml** — Automated PR reviews. Adds `reviewed` label. **Recommended — this triggers the full review pipeline.**
- **claude-issue-triage.yml** — Auto-label new issues
- **claude-prd-creation.yml** — Generate PRDs from feature requests

#### Deployment Workflows
- **deploy-fly.yml** — Deploy to Fly.io
- **deploy-ecs-production.yml** — Deploy to AWS ECS (production)
- **deploy-ecs-staging.yml** — Deploy to AWS ECS (staging)
- **deploy-mkdocs.yml** — Build and deploy docs to GitHub Pages

#### Maintenance
- **dependabot.yml** — Automated dependency updates (weekly)
- **sync-api-docs.yml** — Sync docs to separate repository

After confirmation, install selected workflows:
```bash
mkdir -p .github/workflows
# Copy selected templates from this skill's templates/ directory
# Skip if file already exists
```

### 5. Summary Phase

```
## GitHub Setup Complete: $REPO

### Labels
- ✅ Created N labels, skipped N (already existed)

### Project Board
- ✅ Created "$REPO_NAME" project (or "Skipped — already exists")
  ⚠️ Configure automations manually in project settings

### Workflows
- ✅ Installed: claude-code-review.yml
- ⏭️ Skipped: dependabot.yml (already existed)
- ⚠️ Secrets needed: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN

### Review Pipeline (after claude-code-review.yml is installed)
PR opened → reviewed label → double-check → double-checked label → cto-review → approved/needs-work

### Manual Next Steps
- [ ] Install Claude GitHub App: https://github.com/apps/claude
- [ ] Add ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN secret
- [ ] Configure project board automations (link above)
- [ ] Wire event-rules.yml with review-pr-on-reviewed + cto-review-on-double-checked rules
```

---

## Workflow Catalog

All Claude workflows require `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`.

| Workflow | Trigger | Output | Pipeline Role |
|----------|---------|--------|---------------|
| `claude-code-review.yml` | PR opened/reopened | Review comment + `reviewed` label | Stage 1 |
| `claude-issue-triage.yml` | New issue | Labels + priority | Standalone |
| `claude-prd-creation.yml` | Issue label or @claude | PRD document | Standalone |
| `deploy-fly.yml` | Push to main | Fly.io deploy | CD |
| `deploy-ecs-production.yml` | Push to main | ECS deploy (prod) | CD |
| `deploy-ecs-staging.yml` | Push to develop | ECS deploy (staging) | CD |
| `dependabot.yml` | Weekly cron | Dep update PRs | Maintenance |

---

## Required Secrets

| Secret | Where | Notes |
|--------|-------|-------|
| `ANTHROPIC_API_KEY` | https://console.anthropic.com/settings/keys | Recommended. Starts `sk-ant-` |
| `CLAUDE_CODE_OAUTH_TOKEN` | Run `claude /install-github-app` | Alternative to API key |
| `FLY_API_TOKEN` | `flyctl auth token` | For Fly.io deployment |
| `AWS_ACCESS_KEY_ID` | AWS IAM Console | For ECS deployment |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM Console | For ECS deployment |

---

## Supporting Files

- `templates/claude-code-review.yml` — Generic Claude PR review workflow
- `templates/claude-issue-triage.yml` — Issue labeling workflow
- `templates/claude-prd-creation.yml` — PRD generation workflow
- `templates/dependabot.yml` — Dependabot config
- `templates/deploy-fly.yml` — Fly.io deployment
- `templates/deploy-ecs-production.yml` — AWS ECS production
- `templates/deploy-ecs-staging.yml` — AWS ECS staging
- `templates/deploy-mkdocs.yml` — MkDocs documentation
