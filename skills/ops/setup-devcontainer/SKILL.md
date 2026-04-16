---
name: setup-devcontainer
description: Generate devcontainer config and optionally create a Gitpod/Ona project for any repo. Detects framework (Rails, Next.js, Strapi, Django, Laravel, etc), generates Dockerfile + devcontainer.json + automations. Triggers on "setup devcontainer", "setup ona", "devcontainer config", "gitpod setup".
user-invocable: true
allowed-tools: Read, Write, Glob, Grep, Bash
---

# Devcontainer Setup

Generate devcontainer configuration for any repository. Optionally create a Gitpod/Ona project and verify with a test environment.

## When to Use

- First-time devcontainer setup for a repo
- Migrating from legacy `.gitpod.yml`
- Re-generating config after major stack changes
- Verifying an existing devcontainer setup works

## Phase 1: Config Generation

### 1.1 Detect Framework

Scan the repo directly (no prerequisite files required):
- `Gemfile` / `config/routes.rb` → Rails
- `package.json` with `next` → Next.js
- `package.json` with `strapi` → Strapi
- `manage.py` / `settings.py` → Django
- `composer.json` with `laravel` → Laravel
- `composer.json` with `symfony` → Symfony
- `package.json` with `express` → Express
- `package.json` with `@nestjs` → NestJS
- Multiple `package.json` in subdirs → Monorepo

Also detect:
- **Database**: PostgreSQL, MySQL, MongoDB, SQLite (from config files, Gemfile, package.json)
- **Default branch**: `git symbolic-ref refs/remotes/origin/HEAD` or check `main`/`master`
- **CLAUDE.md**: If missing, suggest running `setup-harness` but do NOT block
- **Speckit**: `.specify/` directory exists → note speckit commands available
- **Legacy config**: `.gitpod.yml` exists → extract ports, tasks, extensions as migration hints

### 1.2 Ask User

Confirm detected stack, then ask:
1. Optional tasks: Fly.io CLI, database backup/restore from S3
2. Additional VS Code extensions
3. Custom port overrides
4. Preserve existing `.devcontainer/` or `.ona/` files?

### 1.3 Generate Files

1. **`.devcontainer/Dockerfile`** — Generic base + detected DB packages
2. **`.devcontainer/devcontainer.json`** — Features, extensions, ports
3. **`.ona/automations.yaml`** (if using Gitpod/Ona) — Services + tasks:
   - Standard tasks: `setup_node`, `setup_git_config`, `setup_gnupg`, `setup_ssh`, `setup_aws`
   - **`install_claude_code`** — `curl -fsSL https://claude.ai/install.sh | sh` (always included)
   - Framework-specific services and dependency install tasks
   - Optional tasks based on user choices

### 1.4 Validate

- No placeholder values remain (`[dbname]`, `[backend-dir]`, etc.)
- Ports match detected frameworks
- Extensions match detected frameworks
- DB service configured if needed

## Phase 2: Gitpod/Ona Project Setup (optional)

Skip this phase if not using Gitpod/Ona.

### 2.1 Prerequisites

```bash
gitpod version && gitpod whoami
```

If not authenticated, user needs `gitpod login --token "<PAT>" --non-interactive`.

### 2.2 Check Existing Project

```bash
gitpod project list --timeout 30s
```

Search output for the repo URL. If project exists, skip to 2.4.

### 2.3 Create Project

```bash
REPO_URL=$(git remote get-url origin)
gitpod project create "$REPO_URL" --timeout 30s
```

Extract the project ID from output.

### 2.4 Configure Secrets

Gitpod has two secret scopes. Both are needed for a fully functional environment.

#### Project secrets (per-project, set via CLI)

Check existing:
```bash
gitpod project secret list <project-id> -o json --timeout 15s
```

Required project secrets:
- `CLAUDE_CODE_OAUTH_TOKEN` — Claude Code authentication
- `GH_TOKEN` — GitHub API access (for `gh` CLI inside pods)
- Project-specific secrets (`ENV_PASS`, `AWS_*`, etc.)

Set missing ones:
```bash
gitpod project secret set <project-id> CLAUDE_CODE_OAUTH_TOKEN "<token>"
gitpod project secret set <project-id> GH_TOKEN "<token>"
```

Never handle token values directly — user provides them.

#### Personal secrets (user-level, set via dashboard)

Set once per account, apply to ALL environments. Configured in the web dashboard under user settings, NOT via CLI.

Required personal secrets:
- `GITCONFIG` — base64-encoded `~/.gitconfig`
- `GPG_1` through `GPG_5` — base64-encoded GPG keyring tar.gz split into 5 chunks
- `SSH_PRIVATE_KEY` — base64-encoded SSH private key
- `SSH_PUBLIC_KEY` — base64-encoded SSH public key
- `SSH_KNOWN_HOSTS` — base64-encoded known_hosts

### 2.5 Output

Report:
- Project ID
- Repo URL
- Pool naming convention: `{project}-{purpose}-runner-{n}`
- Configured secrets

## Phase 3: Test Environment (optional)

### 3.1 Create Test Env

```bash
gitpod environment create <project-id> \
  --name "<project>-setup-test" \
  --class-id 0198bec9-2af2-704f-a4f9-927101d8b844 \
  --set-as-context --dont-wait
```

### 3.2 Poll Until Running

Every 10s, timeout 3min:
```bash
gitpod environment get <env-id> --timeout 15s
```

### 3.3 Verify Checklist

SSH in and run checks:
```bash
gitpod environment ssh <env-id> -- "<command>"
```

- [ ] **Claude Code installed**: `claude --version`
- [ ] **Git identity configured**: `git config --global user.name && git config --global user.email`
- [ ] **No repo-level git overrides**: `git config --local user.name` should return empty/error
- [ ] **Git clean on default branch**: `git status --porcelain` is empty
- [ ] **Services running**: DB responds (`pg_isready` or `mysqladmin ping`)
- [ ] **App server starts**: framework start command runs without immediate crash
- [ ] **Speckit available**: `ls .specify/` if detected in Phase 1

### 3.4 Teardown

```bash
gitpod environment stop <env-id>
gitpod environment delete <env-id>
```

If user passes `--keep-open`, only report the env ID and SSH command.

## Environment Classes

| Class   | ID                                   | Specs           |
| ------- | ------------------------------------ | --------------- |
| Small   | 0198bec9-2af2-7056-b500-a1145383a73c | 2 vCPU / 8 GiB  |
| Regular | 0198bec9-2af2-704f-a4f9-927101d8b844 | 4 vCPU / 16 GiB |
| Large   | 0198bec9-2af2-7049-a4db-caaca7016e9f | 8 vCPU / 32 GiB |

## Key Rules

- **Never hardcode secrets** — tokens go in project secrets
- **Claude Code install**: always use `curl -fsSL https://claude.ai/install.sh | sh` (NOT npm)
- **Default to Regular class** unless user specifies otherwise
- **Always tear down test envs** unless `--keep-open`
- **SSH pattern**: `gitpod environment ssh <env-id> -- "<command>"`
- **This skill sets up projects, not orchestration** — dispatch and scheduling are handled separately
