---
name: double-check
description: Standalone PR double-check — read diff, check comments, fix must-fix issues, run tests, post curated review comment, apply double-checked label. No Pylot/Ona dependency.
argument-hint: "[pr-number] [org/repo]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, Agent
---

# double-check

Active PR review that reads the diff, curates CI findings, fixes must-fix issues locally, re-runs tests, posts a structured review comment, and applies the `double-checked` label. Standalone — no Pylot, Ona, or commander path dependencies.

## When to Use

- A PR gets the `reviewed` label (event-triggered via event-rules.yml)
- Manual review before merging an agent-generated PR
- Any PR where CI left review comments that need curation and resolution

## Invocation

```
/double-check PR_NUMBER org/repo
```

**Examples:**
```
/double-check 742 fellowship-dev/booster-pack
/double-check 84 Lexgo-cl/rails-backend
```

## Token

Set `GH_TOKEN` in the environment before running. For Pylot crews, the team's `token_var` from `crew.yml` is used automatically. For manual runs:

```bash
export GH_TOKEN=$(grep 'GH_TOKEN_FELLOWSHIP' /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
```

## Primary Workflow: Local Checkout

The primary path works WITHOUT Ona/Codespaces — checkout the PR locally, run tests, push fixes.

## Optional: Remote Execution (Ona/Codespaces)

If the repo requires a specific runtime environment (e.g., Rails, Python with system deps), use Ona (`ona-gitpod` skill) or Codespaces (`codespaces` skill). See "Remote Execution" section below.

---

## Runbook

### Step 1: Pre-Flight

```bash
export PR=$1      # first argument: PR number
export REPO=$2    # second argument: org/repo

# Fetch PR metadata
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

# Extract key info
PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')
PR_BRANCH=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')

# Check CI status (best-effort — may fail with PAT)
gh pr checks $PR --repo $REPO 2>/dev/null || echo "CI checks not accessible via token"

# Read ALL existing PR review comments
gh pr view $PR --repo $REPO --json comments --jq '.comments[].body'
gh pr view $PR --repo $REPO --json reviews --jq '.reviews[].body'
```

### Step 2: Read the Diff

```bash
# Get diff (full)
gh pr diff $PR --repo $REPO

# Get changed file names
gh pr diff $PR --repo $REPO --name-only
```

Read the diff carefully. Build a mental model of what changed and why.

### Step 3: Curate CI Findings

For each finding in the PR review comments (from automated CI / Claude GitHub App / bots):

Classify each finding as:
- **MUST FIX** — accurate, important for correctness/security/spec compliance
- **NICE TO HAVE** — accurate but low priority, non-blocking
- **DISCARD** — inaccurate, irrelevant, overly pedantic, or far-fetched

Document your classification for each finding. This is the curation step — a human CTO would read this to understand what the AI reviewers actually caught vs. what was noise.

### Step 4: Checkout and Fix (Local)

```bash
# Clone/fetch the PR branch locally
# If not already in the repo directory:
REPO_NAME=$(echo $REPO | cut -d/ -f2)
REPO_DIR="/tmp/double-check-$REPO_NAME"

if [ ! -d "$REPO_DIR" ]; then
  git clone "https://github.com/$REPO.git" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch origin $PR_BRANCH
git checkout $PR_BRANCH
git pull origin $PR_BRANCH

# Merge base branch to catch conflicts
git fetch origin $BASE_BRANCH
git merge origin/$BASE_BRANCH --no-edit || {
  echo "Merge conflict — resolve manually"
  exit 1
}
```

For each **MUST FIX** item (and NICE TO HAVE items you judge worth doing):
1. Plan the fix
2. Implement the fix
3. Commit: `git add ... && git commit -m "fix: [description] (review finding for #$ISSUE)"`

### Step 5: Run Tests

Run the project's test suite after fixes. The specific command depends on the stack:

```bash
# Node.js / Next.js
npm test 2>/dev/null || npx jest --passWithNoTests 2>/dev/null || echo "No test command found"

# Ruby on Rails
RAILS_ENV=test bundle exec rspec --format progress 2>/dev/null || echo "Not a Rails project"

# Python
pytest 2>/dev/null || python -m pytest 2>/dev/null || echo "No pytest found"

# Go
go test ./... 2>/dev/null || echo "Not a Go project"

# Detect from package.json
if [ -f package.json ]; then
  npm run test 2>/dev/null || npx vitest run 2>/dev/null || true
fi
```

Record: pass/fail, number of tests, any regressions introduced by your fixes.

If tests fail after your fixes: debug and re-fix until green, or explicitly note the failure as pre-existing.

### Step 6: Push Fixes

If you made fix commits:

```bash
cd "$REPO_DIR"
git push origin $PR_BRANCH
```

If you couldn't push (permission denied): note in the review comment that fixes need to be applied by the repo owner.

### Step 7: Post Review Comment

Post the curated review as a PR comment. Use this format:

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'REVIEW_EOF'
## Double-Check Review: PR #$PR — $PR_TITLE

**Reviewer:** Automated double-check
**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`

---

### Intent
[1-2 sentences: does the PR deliver what it's supposed to?]

### Implementation
[2-4 bullets: key approach, files changed grouped by area]

### Curated CI Findings

| # | Finding | Verdict | Fixed? | Reason |
|---|---------|---------|--------|--------|
| 1 | [description] | MUST FIX | Yes/No | [why, what was done] |
| 2 | [description] | NICE TO HAVE | Yes/No | [why] |
| 3 | [description] | DISCARD | — | [why it's irrelevant] |

### New Issues (not caught by CI)
| # | Issue | Fixed? | Details |
|---|-------|--------|---------|
| 1 | [description] | Yes/No | [what was done] |

### Tests After Fixes
- **Suite:** [pass (N/N) / fail — details / not run — reason]
- **Regressions:** [none / list any]

### Verdict
[Ready for CTO review / Needs more work — list remaining items]

REVIEW_EOF
)"
```

**Rules:**
- If no CI findings exist: write "No CI review comments found — reviewed diff directly"
- If tests weren't run: explain why (e.g., "deps-only change, no test suite applicable")
- Verdict must be specific: either "ready for CTO review" or list what still needs work

### Step 8: Apply double-checked Label

```bash
# Create label if it doesn't exist
gh label create "double-checked" --repo $REPO --color "0075ca" --description "Double-checked by agent" 2>/dev/null || true

# Apply the label — signals the review is complete and visible
gh pr edit $PR --repo $REPO --add-label "double-checked"
```

Only apply after the comment posts successfully. This label triggers the `cto-review-on-double-checked` event rule in event-rules.yml.

### Step 9: Write Report

```bash
REPORT_FILE="reports/$(date +%Y-%m-%d)-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

Report format:
```markdown
# Review: $REPO PR #$PR — $PR_TITLE

**Date:** YYYY-MM-DD
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL) — $PR_TITLE
**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`

## Source PR

[PR body verbatim]

## Intent

[What problem this solves]

## Implementation

- [Key approach and decisions]

## Curated CI Findings

[Findings table]

## Tests After Fixes

[Pass/fail results]

## Verdict

[Ready for merge / Needs fixes]
```

Post to Quest DB:
```bash
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
curl -s -X POST "http://127.0.0.1:4242/api/event" \
  -H "Authorization: Bearer $QUEST_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
content = open('$REPORT_FILE').read()
print(json.dumps({
  'source': 'commander',
  'type': 'commander.report',
  'title': 'Review: $REPO PR #$PR',
  'meta': {'content': content, 'report_type': 'double-check'}
}))
")" 2>/dev/null || true
```

---

## Optional: Remote Execution (Ona / Codespaces)

Use remote execution when the project requires a specific runtime not available locally (e.g., Rails, complex system deps). The local checkout path is always tried first.

### Ona (Gitpod)

Use the `ona-gitpod` skill to claim a pod. See that skill for full SSH setup.

Key differences vs. local:
- Clone to `/workspaces/$REPO_DIR` instead of `/tmp/`
- Use `gitpod environment ssh $ENV_ID -- "cd /workspaces/$REPO_DIR && ..."` for all commands
- Stop env after: `gitpod environment stop $ENV_ID`

### GitHub Codespaces

Use the `codespaces` skill for ephemeral compute.

```bash
# Create codespace on the PR branch
gh codespace create --repo $REPO --branch $PR_BRANCH --machine basicLinux32gb

# Run commands
gh codespace ssh --codespace $CODESPACE_NAME -- "cd /workspaces/$REPO_NAME && npm test"

# Delete when done
gh codespace delete --codespace $CODESPACE_NAME --force
```

---

## Notes

- **Fresh eyes are the point.** The double-check has NO implementation history — this prevents confirmation bias.
- **The review is active, not passive.** Fix must-fix items, verify tests, then write the final review with results.
- **double-checked label triggers cto-review.** Applying this label is the handoff signal to the CTO pipeline.
- **For Pylot/crew-based runs**, the report goes to `$(git rev-parse --show-toplevel)/reports/` in commander.
- **For deps-only PRs** (Dependabot, lockfile-only), tests may be skipped — note this explicitly.
- **Reviewer reads CI comments directly via `gh`** — never have the prompt pre-pasted. Curate live.
