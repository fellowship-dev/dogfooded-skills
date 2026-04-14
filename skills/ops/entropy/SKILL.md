---
name: entropy
description: Sensor — checks doc freshness and computes domain quality grades. Never fixes. Detects staleness, missing coverage, and FlowChad gaps. Updates QUALITY_SCORE.md.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Entropy

Sensor. Detect, grade, report. **Never fix.**

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/ops/entropy
```

## When to Use

- **Event-driven (PR merge):** Triggered after a PR merges. Scans affected domains for doc staleness.
- **Weekly cron (full sweep):** Runs against each product repo, updates QUALITY_SCORE.md with fresh grades.
- **Manual:** When you suspect docs have drifted or want a current health snapshot before a refactor.

## What It Does

Entropy is a read-only sensor. It computes domain quality grades from mechanical signals:

| Signal | What it measures | Weight |
|--------|-----------------|--------|
| Doc coverage | Does `docs/code-structure.md` cover this domain? | Binary |
| Flow coverage | FlowChad flow defined for critical paths? | Binary |
| Staleness delta | Days since last code commit vs. last doc update | >30d = stale |
| Open issues | Issues tagged to domain in GitHub | >3 open = signal |
| Test coverage | From coverage report if available | <60% = signal |

**Grade scale:**
- **A** — All 5 signals green
- **B** — 1 signal missing or yellow
- **C** — 2 signals missing
- **D** — 3+ signals missing
- **F** — No docs at all for this domain

---

## Instructions

### 0. Identify Target Repo

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename $(git remote get-url origin) .git)
ORG=$(git remote get-url origin | sed 's/.*github.com[:/]\([^/]*\).*/\1/')
FULL_REPO="$ORG/$REPO_NAME"
TODAY=$(date +%Y-%m-%d)
```

Read `QUALITY_SCORE.md` if it exists — this is the baseline to update.
Read `ARCHITECTURE.md` if it exists — extract domain list.
If neither exists, infer domains from directory structure (same logic as setup-harness).

### 1. Determine Scope

**PR-triggered mode:** Given a PR number, identify which files changed:
```bash
# Get changed files from PR
GH_TOKEN=$GH_TOKEN gh api repos/$FULL_REPO/pulls/{PR_NUMBER}/files \
  --jq '.[].filename'
```
Map each changed file to its domain using directory prefixes. Only grade domains with changes.

**Full sweep mode:** Grade all domains. Read domain list from `ARCHITECTURE.md` or infer.

### 2. Per-Domain Grading

For each domain in scope:

#### Signal 1: Doc Coverage

```bash
# Is this domain mentioned in docs/code-structure.md?
grep -i "{domain_name}" $REPO_ROOT/docs/code-structure.md 2>/dev/null && echo "COVERED" || echo "MISSING"
```

Score: ✅ covered / ❌ missing

#### Signal 2: FlowChad Coverage

```bash
# Is there a flowchad flow for this domain's critical path?
ls $REPO_ROOT/flowchad/ 2>/dev/null | grep -i "{domain_slug}" && echo "COVERED" || echo "MISSING"
```

Score: ✅ has flow / ❌ no flow

#### Signal 3: Staleness Delta

Find the most recent code commit date for files in this domain:
```bash
# Last commit touching domain files
git -C $REPO_ROOT log -1 --format="%ci" -- "{domain_directory_glob}" 2>/dev/null
```

Find the last update date for the domain's doc section:
```bash
# Last commit touching docs/code-structure.md
git -C $REPO_ROOT log -1 --format="%ci" -- docs/code-structure.md 2>/dev/null
```

Delta = days between last code commit and last doc update.
Score: ✅ delta ≤30 days / ⚠️ delta 31-60 days (yellow) / ❌ delta >60 days

#### Signal 4: Open Issues

```bash
# Open issues tagged to this domain (use domain name as label or search term)
GH_TOKEN=$GH_TOKEN gh issue list --repo $FULL_REPO \
  --state open --search "{domain_name}" \
  --json number,title | jq length 2>/dev/null || echo "0"
```

Score: ✅ 0-3 open / ⚠️ 4-6 open (yellow) / ❌ >6 open

#### Signal 5: Test Coverage

```bash
# Look for coverage reports
ls $REPO_ROOT/coverage/ $REPO_ROOT/.nyc_output/ $REPO_ROOT/tmp/coverage/ 2>/dev/null
cat $REPO_ROOT/coverage/index.html 2>/dev/null | grep -o '[0-9.]*%' | head -1
# Rails: simplecov
cat $REPO_ROOT/coverage/.last_run.json 2>/dev/null | jq '.result.covered_percent'
```

If no coverage report is available → skip this signal (treat as neutral, not ❌).
Score: ✅ ≥80% / ⚠️ 60-79% / ❌ <60% (only when coverage data is available)

#### Compute Grade

Count failing signals (❌):
- 0 failing → **A**
- 1 failing → **B**
- 2 failing → **C**
- 3 failing → **D**
- No docs at all → **F**

Yellow signals (⚠️) count as 0.5 each toward the failing count. Round up for grade cutoffs.

### 3. Update QUALITY_SCORE.md

Read the existing file. Update each graded domain's row. Add new domains if discovered.
Preserve existing rows for domains not in scope (only update what was re-scanned).

```markdown
## Domains

| Domain | Grade | Last audit | Notes |
|--------|-------|------------|-------|
| {domain} | {grade} | {TODAY} | {brief note on what's missing, or "All signals green"} |
```

Write the updated file. Then append to the History section:
```markdown
| {TODAY} | {trigger: PR #{N} / weekly sweep / manual} | {N} domains scanned, {N} regressions, {N} improvements |
```

### 4. Staleness Report

For any domain graded C, D, or F — or where grade regressed from previous — output a finding:

```
## Entropy Findings — {TODAY}

### Regressions (grade dropped)
- {Domain}: {old grade} → {new grade}
  Missing: {list of failing signals}
  Last doc update: {date}
  Last code commit: {date}
  Delta: {N} days

### Stable issues (same low grade)
- {Domain}: {grade} (unchanged since {date})
  Missing: {list}

### Improvements (grade improved)
- {Domain}: {old grade} → {new grade}

### Clean (A or B)
- {Domain}: {grade}
```

### 5. Imported Lib Drift (Architecture Check)

**This check moved here from maintenance.** It is an architecture signal, not an infra check.

Compare installed speckit commands against the source of truth (`fellowship-dev/spec-kit`):

```bash
# Source of truth: fellowship-dev/spec-kit templates/commands/
GH_TOKEN=$GH_TOKEN gh api repos/fellowship-dev/spec-kit/contents/templates/commands \
  --jq '.[].name' 2>/dev/null

# For each active repo with speckit installed:
for repo in Lexgo-cl/rails-backend fellowship-dev/booster-pack fellowship-dev/farmesa \
            fellowship-dev/mtg-lotr fellowship-dev/inbox-angel fellowship-dev/inbox-angel-worker; do
  echo "=== $repo ==="
  for cmd in specify plan tasks implement analyze checklist clarify; do
    SOURCE=$(GH_TOKEN=$GH_TOKEN gh api repos/fellowship-dev/spec-kit/contents/templates/commands/${cmd}.md \
      --jq '.sha' 2>/dev/null)
    INSTALLED=$(GH_TOKEN=$GH_TOKEN gh api repos/${repo}/contents/.claude/commands/speckit.${cmd}.md \
      --jq '.sha' 2>/dev/null)
    if [ "$SOURCE" != "$INSTALLED" ]; then
      echo "  DRIFT: speckit.${cmd}.md (source: $SOURCE, installed: $INSTALLED)"
    fi
  done
done
```

SHA mismatch = drift. Add drifted repos/commands to the staleness report.
Note: repos may have intentional customizations — flag for review, don't auto-fix.
**inbox-angel-worker exception**: speckit is installed locally and gitignored. Drift sync must be done locally on Spacestation.

Include drift findings in QUALITY_SCORE.md under a `## Tooling` section if any drift is found.

### 6. PR-Triggered Output

When triggered by a PR merge event, output a comment-ready summary:

```
## Entropy Scan — PR #{N} merged

Domains affected: {list}

| Domain | Grade | Change | Notes |
|--------|-------|--------|-------|
| {domain} | {grade} | {→ or unchanged or ↑ or ↓} | {note} |

{If any regressions:}
⚠️ Doc staleness detected in: {domain list}
Recommended: update docs/code-structure.md for these domains before the next PR in this area.
```

### 7. Full Sweep Output (weekly cron)

```
## Entropy Weekly Sweep — {DATE}

{N} domains across {REPO_NAME}

### Grades
{Full grade table}

### Action Items
{Domains graded D or F → create a GitHub issue if one doesn't already exist}
```

For D/F domains, create a GitHub issue in the repo:
```bash
GH_TOKEN=$GH_TOKEN gh issue create \
  --repo $FULL_REPO \
  --title "Entropy: {domain} docs critically stale (grade {grade})" \
  --label "documentation" \
  --body "Domain **{domain}** scored **{grade}** in the weekly entropy scan.

**Missing signals:**
{list}

**Last code commit to this domain:** {date}
**Last doc update:** {date}

Fix: update \`docs/code-structure.md\` and run \`/hookshot\` to regenerate hooks."
```

Check for existing open issues before creating (dedup by title prefix).
