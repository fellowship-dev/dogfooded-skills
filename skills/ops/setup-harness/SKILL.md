---
name: setup-harness
description: Scaffold the knowledge layer for a repo — ARCHITECTURE.md, QUALITY_SCORE.md, enhanced docs/code-structure.md, docs/code-guidelines.md, and FlowChad flow stubs. Gives agents a map, not a 1,000-page manual.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
---

# Setup Harness

Scaffold the knowledge layer for any repository. Scan, infer, populate.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/ops/setup-harness
```

## When to Use

- First-time setup of a repo that will receive AI agents (claude-code-review, speckit, etc.)
- A repo that has agents but no architectural documentation — the #1585-class bug
- After major restructuring, to refresh stale docs
- Onboarding a repo into the fellowship-dev harness (target: fellowship-dev/booster-pack)

## Design Principle

> "Give the agent a map, not a 1,000-page instruction manual."

CLAUDE.md stays short (~100 lines), acting as a table of contents that points to deeper docs.
Progressive disclosure: agents read the overview, then drill into the specific section they need.
This skill creates that map from what already exists in the repo.

## What It Creates

| File | Purpose |
|------|---------|
| `ARCHITECTURE.md` | Major architectural decisions and critical patterns |
| `QUALITY_SCORE.md` | Domain quality grades — updated by the entropy skill |
| `docs/code-structure.md` | Real discovered patterns ("this is how X works") |
| `docs/code-guidelines.md` | Golden principles, enforced mechanically by hookshot |
| `flowchad/` | Stub flow definitions for critical paths |
| `.claude/CLAUDE.md` | Updated table of contents pointing to all docs |

Files that already exist are updated (merged), never overwritten wholesale.

---

## Instructions

### 0. Identify the Repo

```bash
# Get repo identity
git remote get-url origin
git rev-parse --show-toplevel

# Capture these for the rest of the skill
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename $(git remote get-url origin) .git)
```

Ask (or infer from package.json / Gemfile / pyproject.toml):
- What language/framework is this? (Rails, Next.js, Python, etc.)
- What is the primary domain? (e-commerce, content, auth, etc.)

If the repo has a README, read it. Extract: purpose, key concepts, tech stack.

### 1. Discovery Phase

Scan the repo structure to understand what exists:

```bash
# Top-level structure
ls -la $REPO_ROOT

# Source directories (skip node_modules, .git, vendor, tmp)
find $REPO_ROOT -maxdepth 3 -type d \
  ! -path '*/.git/*' \
  ! -path '*/node_modules/*' \
  ! -path '*/vendor/*' \
  ! -path '*/tmp/*' \
  ! -path '*/.next/*' \
  ! -path '*/dist/*' \
  | sort

# Key files
ls $REPO_ROOT/docs/ 2>/dev/null || echo "No docs/"
ls $REPO_ROOT/.claude/ 2>/dev/null || echo "No .claude/"
ls $REPO_ROOT/flowchad/ 2>/dev/null || echo "No flowchad/"
ls $REPO_ROOT/.github/workflows/ 2>/dev/null || echo "No workflows"

# Detect framework
ls $REPO_ROOT/Gemfile $REPO_ROOT/package.json $REPO_ROOT/pyproject.toml \
   $REPO_ROOT/go.mod $REPO_ROOT/Cargo.toml 2>/dev/null
```

**Infer domains from directory structure.** Examples:
- `app/models/` + `app/controllers/` → Rails MVC domains
- `src/components/` + `src/pages/` → Next.js frontend domains
- `services/` + `workers/` → Service-oriented domains
- `lib/` + `spec/` → Library pattern

Record: list of inferred domains (e.g., Content Model, Auth, API, Frontend Routing, Background Jobs).

### 2. Pattern Discovery

For each inferred domain, grep for critical patterns:

```bash
# Entry points (routes, controllers, resolvers)
grep -r "def " $REPO_ROOT/app/controllers/ --include="*.rb" -l 2>/dev/null | head -10
grep -r "export default" $REPO_ROOT/src/pages/ --include="*.tsx" -l 2>/dev/null | head -10

# Key abstractions (base classes, mixins, concerns)
grep -rl "class.*Base\|module.*Concern\|extends.*Component" \
  $REPO_ROOT/app $REPO_ROOT/lib $REPO_ROOT/src 2>/dev/null | head -10

# Shared utilities (helpers, services)
ls $REPO_ROOT/app/services/ $REPO_ROOT/lib/ $REPO_ROOT/src/lib/ 2>/dev/null

# Critical paths (auth, payment, data mutations)
grep -rl "authenticate\|authorize\|payment\|stripe\|checkout\|redirect" \
  $REPO_ROOT/app $REPO_ROOT/src 2>/dev/null | head -20
```

Read 2-3 key files per domain to understand the actual pattern. Do not rely solely on filenames.

Identify **critical paths** — sequences where a bug causes significant user harm:
- Auth flows (login, token refresh, permission checks)
- Data mutation flows (create/update/delete with side effects)
- Payment flows (if applicable)
- External API integrations (webhooks, third-party calls)

### 3. Write ARCHITECTURE.md

Create or update `$REPO_ROOT/ARCHITECTURE.md`:

```markdown
# Architecture — {REPO_NAME}

> Last updated: {DATE} by setup-harness

## Overview

{1-2 paragraphs: what this system does, its primary responsibility, who uses it}

## Tech Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Runtime | {e.g., Ruby 3.2 / Rails 7} | |
| Frontend | {e.g., Next.js 14 / React} | |
| Database | {e.g., PostgreSQL 15} | |
| Background | {e.g., Sidekiq / Que} | |
| Auth | {e.g., Devise + JWT} | |

## Domains

{For each inferred domain:}

### {Domain Name}

**Files:** `{primary directory path}`

**Pattern:** {1-2 sentences describing how this domain works, with actual file/class names}

**Critical paths:**
- {Path name}: `{entry point}` → `{key step}` → `{outcome}`

**Known gotchas:**
- {Any patterns that are non-obvious or commonly misunderstood}

## Architectural Decisions

{Document any non-obvious decisions found during scan. Leave this section for humans to fill in if nothing is discovered.}

### Decision: {Short name}
- **Context:** {What problem this solves}
- **Decision:** {What was chosen}
- **Consequences:** {Trade-offs}

## Agent Guidance

When modifying code in this repo:
1. Read the relevant domain section above before touching files in that directory
2. Check `docs/code-structure.md` for how the pattern works
3. Check `docs/code-guidelines.md` for rules that must be followed
4. Check `QUALITY_SCORE.md` to understand domain health

> If you are about to write code that looks like it already exists — it probably does. Search first.
```

Populate ALL sections with real discovered content. Do not use `{placeholder}` text in the final file.

### 4. Write docs/code-structure.md

Create or update `$REPO_ROOT/docs/code-structure.md`.

**This must be real pattern documentation, not a directory listing.** For each domain, explain HOW the pattern works, with actual code references.

Template:

```markdown
# Code Structure — {REPO_NAME}

> Last updated: {DATE} by setup-harness. Update this file when patterns change.

## How to Read This Doc

Each section covers a domain. For each domain:
- **The pattern** explains the standard way things work
- **The entry point** is where to start reading
- **Don't repeat** calls out existing utilities to use instead of reimplementing

---

## {Domain 1 Name}

**Directory:** `{path}`

### The Pattern

{Explain the pattern in plain English. Example:}

> Controllers in `app/controllers/` inherit from `ApplicationController`. Auth is handled
> by `before_action :authenticate_user!` — never roll your own. Model validations live
> on the model, not the controller. Service objects in `app/services/` handle business
> logic that doesn't belong on a model.

### Entry Points

| Concern | Where to look |
|---------|--------------|
| Routes | `config/routes.rb` |
| Auth | `app/controllers/application_controller.rb` |
| User model | `app/models/user.rb` |

### Don't Repeat

- **Redirects**: Use `check_redirect` in `lib/redirect_service.rb`, not a new conditional
- **Permissions**: Use `policy` objects in `app/policies/`, not inline `if current_user.admin?`
- **Email**: Use `UserMailer` in `app/mailers/`, not direct `ActionMailer::Base`

---

{Repeat for each domain}

## Cross-Cutting Concerns

### Error Handling

{How errors are handled across the app}

### Logging

{What gets logged, where, and how}

### Testing

{Testing strategy — unit/integration split, key helpers, fixture approach}
```

Read actual source files to populate the "Don't Repeat" section with real utilities. This is the primary fix for the #1585-class bug.

### 5. Write docs/code-guidelines.md

Create or update `$REPO_ROOT/docs/code-guidelines.md`:

```markdown
# Code Guidelines — {REPO_NAME}

> These are enforced by hookshot hooks and checked by entropy scans.
> Adding a new rule here? Run `/hookshot` to generate enforcement hooks.

## Golden Rules

These rules are never negotiated. Violations get flagged in PR review.

1. **Search before you implement.** Before writing a new utility, service, or helper, grep
   for existing implementations. The codebase has patterns — use them.

2. **Domain boundaries are hard.** {e.g., "Controllers do not query the database directly.
   Use service objects. Models do not call external APIs."} 

3. **{Rule 3}** — infer from codebase patterns

4. **{Rule 4}** — infer from codebase patterns

## Per-Domain Rules

### {Domain}

- {Specific rule for this domain, inferred from code patterns}
- {Another rule}

## Patterns That Look Wrong But Are Correct

{Document any patterns that look like bugs but are intentional. Prevents agents from
"fixing" working code.}

## Patterns That Look Right But Are Wrong

{Document common mistakes — especially ones that pass tests but fail in production.}

## When in Doubt

1. Read the relevant section in `docs/code-structure.md`
2. Search for an existing implementation
3. Check `ARCHITECTURE.md` for architectural constraints
4. Ask in a comment rather than guessing
```

Infer rules from the codebase. If you find a base class, document "inherit from X, not raw". If you find a service pattern, document "use services for business logic". Be specific.

### 6. Write QUALITY_SCORE.md

Create `$REPO_ROOT/QUALITY_SCORE.md`:

```markdown
# Quality Score — {REPO_NAME}

> Maintained by the entropy skill. Do not edit manually.
> Grade scale: A=all signals green, B=1 signal missing, C=2 missing, D=3+, F=no docs

Last audit: {DATE} (initial scaffold by setup-harness)

## Domains

| Domain | Grade | Last audit | Notes |
|--------|-------|------------|-------|
{For each inferred domain:}
| {Domain} | C | {DATE} | Initial scaffold — needs human review |

## Grade Signals (per domain)

Each domain is graded on:
- [ ] docs/code-structure.md covers this domain
- [ ] FlowChad flows defined for critical paths
- [ ] Last commit date vs last doc update (staleness ≤30 days)
- [ ] Open issues tagged to domain (≤3 open)
- [ ] Test coverage available (if measurable)

## History

| Date | Action | Result |
|------|--------|--------|
| {DATE} | Initial scaffold by setup-harness | {N} domains discovered |
```

### 7. Install FlowChad and Generate Flows

**Do NOT create flow files freehand.** Use FlowChad's official installer and tools.

#### 7a. Install FlowChad (if not already installed)

```bash
# Check if already installed
if [ ! -d "$REPO_ROOT/.flowchad" ]; then
  cd $REPO_ROOT
  curl -fsSL https://raw.githubusercontent.com/Fellowship-dev/flowchad/main/install.sh | bash
fi
```

This creates `.flowchad/` with config.yml, flows/, templates/, knowledge/, and skills/.

#### 7b. Configure .flowchad/config.yml

Update the config with discovered project info:

```yaml
name: {REPO_NAME}
url: http://localhost:{PORT}  # Prefer localhost > staging > production
type: {saas|website}          # Infer from project type

timing:
  slow: 3
  critical: 10

# Add credentials if test env vars found in .env.example or .env.test
credentials:
  email: $TEST_EMAIL
  password: $TEST_PASSWORD
```

#### 7c. Generate Flows Using /flow-add

For each critical path discovered in the Pattern Discovery phase, use FlowChad's `/flow-add` command
(in `.flowchad/skills/flow-add/`) to generate properly formatted flows. The skill scans the codebase
for real selectors — never guess selectors.

If `/flow-add` cannot be run interactively (e.g., during automated setup), create flows using
FlowChad's actual YAML schema. Reference `.flowchad/knowledge/flow-schema.md` for the canonical format:

```yaml
# Required fields
name: {Descriptive sentence — actor + action + outcome}
url: /{starting-path}
tags: [{domain}, {criticality}]
priority: P0  # P0=critical, P1=important, P2=nice-to-have

# Optional context (preconditions)
context:
  auth: logged_out
  user: new_account

steps:
  - action: navigate
    url: /{path}
    expect: "{What should be visible after this step}"
    timing: 2s

  - action: fill
    selector: "{CSS selector from codebase — mark # VERIFY if guessed}"
    value: $ENV_VAR_OR_STRING

  - action: click
    selector: "{CSS selector}"
    expect: "{Expected outcome}"
    timing: 3s
```

**Flow files go in `.flowchad/flows/{kebab-case-name}.yml`** — NOT in a `flowchad/` directory at repo root.

Mark any guessed selectors with `# VERIFY: selector not found in code`.

### 8. Update CLAUDE.md

Read the existing `CLAUDE.md` (at repo root or `.claude/CLAUDE.md`). Add or update the "Knowledge Layer" section:

```markdown
## Knowledge Layer

Read before modifying code:

| Doc | What it covers |
|-----|---------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Tech stack, domains, architectural decisions |
| [QUALITY_SCORE.md](QUALITY_SCORE.md) | Domain health grades |
| [docs/code-structure.md](docs/code-structure.md) | How patterns work, what NOT to reimplement |
| [docs/code-guidelines.md](docs/code-guidelines.md) | Rules enforced by hooks |
| .flowchad/flows/ | Critical path flow definitions (FlowChad) |

**Rule #1:** Before modifying code in a domain, read its section in `docs/code-structure.md`.
**Rule #2:** Before writing a new utility/service/helper, search for an existing one.
```

Keep the total CLAUDE.md under 150 lines. If it's longer, move content to the appropriate dedicated doc.

### 9. Summary Report

Output:

```
## Setup Harness Complete: {REPO_NAME}

### Discovered
- {N} domains: {list}
- {N} critical paths: {list}
- Tech stack: {stack}

### Created
- ✅ ARCHITECTURE.md ({N} domains documented)
- ✅ QUALITY_SCORE.md ({N} domains graded)
- ✅ docs/code-structure.md (real patterns, not placeholders)
- ✅ docs/code-guidelines.md ({N} golden rules)
- ✅ .flowchad/ installed with {N} flow definitions
- ✅ CLAUDE.md updated (table of contents)

### Grades (initial)
{Grade table from QUALITY_SCORE.md}

### Manual Next Steps
- [ ] Review ARCHITECTURE.md — add architectural decisions the scan missed
- [ ] Review docs/code-structure.md — verify "Don't Repeat" entries are current
- [ ] Verify FlowChad flow selectors: grep for `# VERIFY` in .flowchad/flows/
- [ ] Run `/hookshot` to generate enforcement hooks from docs/
- [ ] Run `/entropy` to re-grade after manual review
```
