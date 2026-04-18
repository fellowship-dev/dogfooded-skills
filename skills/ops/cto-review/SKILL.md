---
name: cto-review
description: Strategic CTO checklist for PR review — documentation gaps, external dependencies, downstream/template impact, merge strategy, action items. Also supports heartbeat mode for full-context repo scanning. Posts structured GH review comment, applies label, merges if ready.
argument-hint: "[pr-number] [org/repo] | heartbeat org/repo [goal-context]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# cto-review

Strategic CTO-level PR review. Runs a structured checklist (docs, deps, downstream impact, merge strategy, action items), posts a formatted review comment to the PR, applies appropriate label, and merges if everything passes.

Supports two modes:
- **PR Review** (`/cto-review PR_NUMBER org/repo`) — deep review of a single PR
- **Heartbeat** (`/cto-review heartbeat org/repo [goal-context]`) — full-context scan of all open PRs and issues

## When to Use

- After a PR gets the `double-checked` label (event-triggered)
- Manual CTO sign-off before merging an agent-generated PR
- Any PR that touches docs, adds external dependencies, or has downstream template impact
- Scheduled heartbeat scans to maintain repo health across a team

## Invocation

**PR Review:**
```
/cto-review PR_NUMBER org/repo
```

**Heartbeat:**
```
/cto-review heartbeat org/repo [goal-context]
```

**Examples:**
```
/cto-review 742 fellowship-dev/booster-pack
/cto-review 84 Lexgo-cl/rails-backend
/cto-review heartbeat fellowship-dev/booster-pack
/cto-review heartbeat fellowship-dev/booster-pack "focus: Vercel deployment pipeline"
```

## Token

```bash
export GH_TOKEN=$(grep 'GH_TOKEN' $HOME/projects/fellowship-dev/claude-buddy/.env | grep -v '#' | head -1 | cut -d= -f2)
# Or for specific teams, use the team's token_var from crew.yml
```

## Prerequisites

```bash
gh auth status          # GH CLI must be authenticated
gh pr view $PR_NUMBER --repo $REPO   # verify PR exists
```

---

## Mode 1: PR Review Runbook

### Step 0: Gather Full Context

Before looking at the PR diff, build architectural awareness:

```bash
export PR=$1
export REPO=$2

export GH_TOKEN=$(grep 'GH_PAT_FELLOWSHIP' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)

# Read repo CLAUDE.md for architectural direction
gh api repos/$REPO/contents/CLAUDE.md --jq '.content' | base64 -d 2>/dev/null || echo "(no CLAUDE.md)"

# Recent commit history
gh api "repos/$REPO/commits?per_page=10" --jq '.[].commit.message'

# Open issues — see what the team is working on
gh api "repos/$REPO/issues?state=open&per_page=10" --jq '.[].title'
```

**Systems thinking prompts — answer these before reviewing the diff:**
- "How does this PR fit into the repo's architectural direction (per CLAUDE.md)?"
- "Does this PR conflict with or duplicate any open issues?"
- "Are there recent commits that this PR should have been aware of?"
- "What is the downstream impact on repos that depend on this one?"

### Step 1: Gather PR Context

```bash
# Fetch PR metadata — INCLUDES state, mergedAt, mergeCommit so we know if it's already merged
gh pr view $PR --repo $REPO --json number,title,body,state,mergedAt,mergedBy,mergeCommit,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

# Capture state for branching downstream
STATE=$(gh pr view $PR --repo $REPO --json state --jq '.state')
MERGED_AT=$(gh pr view $PR --repo $REPO --json mergedAt --jq '.mergedAt')

# Fetch linked issue (extract from PR body or branch name)
gh pr view $PR --repo $REPO --json body --jq '.body'

# Check existing labels
gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'

# Get the diff summary (key files changed)
gh pr diff $PR --repo $REPO --name-only
```

**Key intel to extract:**
- PR title, description, branch name
- **PR state** — `OPEN`, `MERGED`, or `CLOSED`
- Files changed (focus: docs, deps, config, templates)
- Linked issue number and title
- Whether `reviewed` and `double-checked` labels are present

#### 1.1 Pre-flight state check

Before running the checklist, branch on PR state. The checklist still runs for merged PRs — docs gaps, downstream impact, and deps findings are still valuable retrospectively — but the merge/label steps become no-ops.

| State | What to do |
|-------|------------|
| `OPEN` | Normal flow — run Steps 2→6 as written. |
| `MERGED` | **Post-merge review.** Run Steps 2, 3, 6. Prefix the review comment verdict with `[POST-MERGE]`. Skip Step 4 (labels — verdict labels are meaningless after merge) and Step 5 (merge — already merged, `gh pr merge` will error). If action items surface, **open GitHub issues** for each instead of blocking the PR. |
| `CLOSED` (not merged) | PR was abandoned. Post a single comment `CTO review skipped — PR closed without merge (state=CLOSED).` and exit. No checklist, no report. |

Shell guard at the top of Step 2 in scripts/flows:
```bash
if [ "$STATE" = "CLOSED" ] && [ -z "$MERGED_AT" ]; then
  gh pr comment $PR --repo $REPO --body "CTO review skipped — PR closed without merge."
  exit 0
fi
POST_MERGE=""
[ "$STATE" = "MERGED" ] && POST_MERGE="true"
```

### Step 2: Run CTO Checklist

Work through each checklist item. Read the diff and relevant files from the repo.

#### 2.1 Documentation Check

For each documentation file that SHOULD be updated given the PR's changes:

| File | Expected update | Status |
|------|----------------|--------|
| `.env.example` | New env vars added? | ✅ / ❌ |
| `README.md` | New features documented? | ✅ / ❌ |
| `docs/setup.md` or equivalent | Setup steps updated? | ✅ / ❌ |
| `CHANGELOG.md` | Entry added (if maintained)? | ✅ / ❌ |

Check by reading the diff:
```bash
gh pr diff $PR --repo $REPO
```

Look specifically for:
- New env vars that aren't in `.env.example`
- New CLI commands/flags with no docs update
- New setup steps that aren't reflected in setup guides
- New features shipped to templates/blueprints

#### 2.2 External Dependencies

Check for new packages, APIs, or services requiring manual setup:

```bash
# Check package.json, Gemfile, requirements.txt, go.mod, etc. changes
gh pr diff $PR --repo $REPO -- "**/package.json" "**/Gemfile" "**/requirements.txt" "**/go.mod" "**/pyproject.toml"
```

For each new external dependency, ask:
- Does it require a new API key or account?
- Is there a manual registration/setup step?
- Is the setup documented somewhere?

#### 2.3 Downstream Impact

Identify repos that inherit from or depend on this repo:

```bash
# If this is a template/booster repo, which downstream repos are affected?
# Check crew.yml for repos under the same team
cat $PYLOT_DIR/crew.yml
```

For each downstream repo, assess:
- Do they inherit deps/config from this PR's changes?
- Is the change breaking (requires update) or opt-in?
- When do downstream repos need to pull these changes?

#### 2.4 Verdict Decision

| Decision | When | Action |
|----------|------|--------|
| LGTM | All checks pass, no blocking issues | Apply `approved` label, merge (or label ready-to-merge per merge_strategy) |
| REWORK | Code needs specific changes | Apply `needs-work` label, post specific required fixes, optionally dispatch dev mission |
| BLOCKED | External dependency or missing info | Apply `needs-work` label, post what is needed, do NOT dispatch |
| NEW_ISSUE | Review reveals separate work needed | Create new GitHub issue, approve/rework the current PR on its own merits |

#### 2.5 Action Items

List numbered must-do items. Each item should be specific and actionable:
1. `path/to/file.md` — exact change needed
2. `path/to/other.yml` — exact change needed


#### 2.6 Process Verification

Check that the right development process was followed — not the code itself, but the steps taken:

**Was related code searched?**
The #1585 class of bug: implementing something that already existed elsewhere. Verify:
```bash
# Check PR description or commits for evidence of pattern search
gh pr view $PR --repo $REPO --json body --jq '.body' | grep -i "search\|grep\|existing\|pattern\|found"
# If no evidence: note in review — "Was existing code searched before implementing?"
```

**Were docs updated alongside the code?**
Beyond the doc check in 2.1 — check if inline comments, README, and any skill/runbook docs reflect the change:
- New CLI flags → argument-hint in skill updated?
- New config options → .env.example or setup docs updated?
- Changed behavior → CLAUDE.md or runbooks updated?

**Release train or direct merge?**
```bash
# Check if base branch is main/master or a release branch
gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName'
```
- If PR touches shared infrastructure or templates → prefer release train
- If PR is self-contained fix → direct merge is fine

**Are FlowChad flows affected?**
```bash
# Check if any .flowchad/ files changed
gh pr diff $PR --repo $REPO --name-only | grep -i "flowchad\.flow\|flows/"
```
If flows are affected or the PR changes how flows run: note that /flowchad-runner should be run post-merge to verify.

**Production impact?**
For PRs touching executor, dispatcher, or event routing:
- Will this affect running jobs? (executor changes)
- Will this break webhook processing? (event router changes)
- Is there a safe rollback path?

### Step 3: Post Review Comment

Post the CTO review as a PR comment in the exact format below:

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'COMMENT_EOF'
# CTO Review: $REPO PR #$PR — $PR_TITLE

**Date:** $(date +%Y-%m-%d)
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL) — $PR_TITLE
**Branch:** `$HEAD_BRANCH` → `$BASE_BRANCH`
**Labels:** $CURRENT_LABELS

---

## Verdict

**[VERDICT_EMOJI] [VERDICT_TEXT]**

---

## CTO Checklist

### Documentation
| Check | Status |
|-------|--------|
| [check_name] | [✅ description / ❌ what's missing] |

### External Dependencies
- [dep_finding_1]
- [dep_finding_2]
- _None_ (if no external deps)

### Downstream Impact
- **[repo_1], [repo_2]** — [impact description]
- All changes are **opt-in** / **breaking** — [details]

### Merge Strategy
- [VERDICT_EMOJI] [Merge immediately / Hold — pending N items / Send back — reason]

### Process Verification
| Check | Status |
|-------|--------|
| Related code searched | [✅ evidence found / ❌ no evidence / N/A] |
| Docs updated | [✅ / ❌ what is missing] |
| Merge strategy | [Direct merge / Release train — reason] |
| FlowChad flows affected | [✅ none / ⚠️ re-run flowchad-runner post-merge / N/A] |
| Production impact assessed | [✅ low risk / ⚠️ requires careful deploy / N/A] |

---

## Action Items Before Merge

[1. **`path/to/file`** — specific change needed]
[2. **`path/to/file`** — specific change needed]

_None — ready to merge_ (if no items)

COMMENT_EOF
)"
```

**Format rules (match the reference report exactly):**
- Header: `# CTO Review: {REPO} PR #{N} — {TITLE}`
- Verdict section: bold emoji + text
- Documentation: table with Check | Status columns
- Status values: `✅ description` or `❌ what's missing`
- Action items: numbered, `**path**` bold, then dash + description
- No trailing whitespace in table cells

### Step 4: Apply Label

**Skip this step entirely if `POST_MERGE` is set** — labels on a merged PR are noise. For post-merge reviews, action items become follow-up issues (see Step 4.1 below), not labels on the PR.

```bash
if [ -n "$POST_MERGE" ]; then
  echo "Post-merge review — skipping label step."
else
  # Create labels if they don't exist
  gh label create "approved" --repo $REPO --color "0e8a16" --description "CTO approved — ready to merge" 2>/dev/null || true
  gh label create "needs-work" --repo $REPO --color "d93f0b" --description "Needs work before merge" 2>/dev/null || true

  # Apply appropriate label based on verdict
  if [[ "$VERDICT" == "merge" ]]; then
    gh pr edit $PR --repo $REPO --add-label "approved"
  elif [[ "$VERDICT" == "hold" || "$VERDICT" == "sendback" ]]; then
    gh pr edit $PR --repo $REPO --add-label "needs-work"
  fi
fi
```

#### 4.1 Post-merge: open follow-up issues instead

If `POST_MERGE` is set and the checklist surfaced action items (docs gaps, missing deps in `.env.example`, downstream migration steps, etc.), open one GitHub issue per item. The PR is already merged — blocking it via label is useless; issues are how follow-up work gets tracked.

```bash
if [ -n "$POST_MERGE" ] && [ -n "$ACTION_ITEMS" ]; then
  # For each action item, open an issue referencing the merged PR
  while IFS= read -r ITEM_TITLE; do
    gh issue create --repo $REPO \
      --title "[post-merge follow-up] $ITEM_TITLE (from PR #$PR)" \
      --body "Surfaced during CTO post-merge review of #$PR.\n\nMerged commit: $MERGE_COMMIT" \
      --label "post-merge-followup"
  done <<< "$ACTION_ITEMS"
fi
```

### Step 5: Merge or label (based on team merge_strategy)

**Skip this step entirely if `POST_MERGE` is set** — `gh pr merge` on a merged PR errors out and can cause the runbook to loop or hang.

Only proceed if:
1. `POST_MERGE` is unset (PR is still open)
2. Verdict is "merge immediately"
3. All required labels are present (`reviewed`, `double-checked`)
4. CI checks are passing

```bash
if [ -n "$POST_MERGE" ]; then
  echo "Already merged at $MERGED_AT — skipping merge step."
  # fall through to Step 6 (report)
else
  # Verify CI is green
  gh pr checks $PR --repo $REPO

  # Verify required labels
  gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'

  # Check team merge_strategy from crew.yml (default: auto)
  MERGE_STRATEGY=$(python3 -c "
import yaml
with open('$PYLOT_DIR/crew.yml') as f:
    data = yaml.safe_load(f)
for team, cfg in data.get('crew', {}).items():
    if not isinstance(cfg, dict): continue
    for r in cfg.get('repos', []):
        if r.lower() == '$REPO'.lower():
            print(cfg.get('merge_strategy', 'auto'))
            exit()
print('auto')
" 2>/dev/null || echo "auto")

  if [ "$MERGE_STRATEGY" = "label-only" ]; then
    # Team requires human merge — label instead
    gh label create "ready-to-merge" --repo $REPO --color "0e8a16" --description "Agent-verified, Max merges" 2>/dev/null || true
    gh pr edit $PR --repo $REPO --add-label "ready-to-merge"
    echo "Labeled ready-to-merge (merge_strategy: label-only)"
  else
    # Default: auto-merge
    gh pr merge $PR --repo $REPO --merge
  fi
fi
```

If CI is failing: set verdict to "hold", note CI failure in comment, do NOT merge.

### Step 6: Report

Write a report to the commander reports directory:

```bash
REPORT_PATH="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-cto-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

Report format:
```markdown
# CTO Review: $REPO PR #$PR — $PR_TITLE

**Date:** YYYY-MM-DD
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL) — $PR_TITLE
**Branch:** `$HEAD` → `$BASE`
**Labels:** $LABELS

---

## Verdict

[verdict text]

---

## CTO Checklist

[full checklist output]

---

## Action Items Before Merge

[action items or "None"]

---

## Review Comment

Posted at: [comment URL]
```

Post report to Quest DB:
```bash
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
curl -s -X POST "http://127.0.0.1:4242/api/event" \
  -H "Authorization: Bearer $QUEST_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
content = open('$REPORT_PATH').read()
print(json.dumps({
  'source': 'commander',
  'type': 'commander.report',
  'title': 'CTO Review: $REPO PR #$PR — $PR_TITLE',
  'meta': {'content': content, 'report_type': 'cto-review'}
}))
")" 2>/dev/null || true
```

---

## Mode 2: Heartbeat Operating Loop

Invoked as: `/cto-review heartbeat org/repo [goal-context]`

The heartbeat is an **hourly operating loop** — the CTO reads the team's full operational state and decides what to do next. PRs develop naturally through the existing review pipeline (double-check → CTO review). The heartbeat operates at a higher level: mission health, blockers, backlog hygiene, architecture, and prioritization.

### Heartbeat Step 1: Load Operational State

```bash
export REPO=$2   # second argument (primary repo — scan all team repos)
export GOAL_CONTEXT="${@:3}"  # optional remainder

export GH_TOKEN=$(grep 'GH_PAT_FELLOWSHIP' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
source $HOME/projects/fellowship-dev/claude-buddy/.env

# Team repos (booster-pack team)
TEAM_REPOS="fellowship-dev/booster-pack fellowship-dev/farmesa-v2 fellowship-dev/quantic-v2 fellowship-dev/fellowship-dev-homepage-v2 fellowship-dev/tuebingen-v2 fellowship-dev/maxfindel-personal-website"

# Read repo CLAUDE.md for architectural direction
gh api repos/$REPO/contents/CLAUDE.md --jq '.content' | base64 -d 2>/dev/null || echo "(no CLAUDE.md)"
```

### Heartbeat Step 2: Mission Log Review

Read the event log and recent mission results to understand what the team has been doing.

```bash
# Recent missions (last 20) — what ran, what failed, costs
curl -s "https://hooks.fellowship.dev/missions?limit=20" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN"

# Recent events from the ledger
curl -s "https://hooks.fellowship.dev/events?limit=30" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN"
```

Analyze:
- **Failed missions**: What failed and why? Is it a recurring pattern or a one-off?
- **Cost trends**: Are missions getting more expensive? Any runaway sessions?
- **Duration trends**: Are similar tasks taking longer than before?
- **Throughput**: How many missions completed since last heartbeat?

### Heartbeat Step 3: Recent Merges & Regression Check

```bash
for repo in $TEAM_REPOS; do
  echo "=== $repo ==="
  # PRs merged in the last 24h
  gh pr list --repo $repo --state merged --json number,title,mergedAt,labels --limit 10
  # Last 10 commits
  gh api "repos/$repo/commits?per_page=10" --jq '.[].commit.message'
done
```

For each recent merge:
- Was it reviewed by the pipeline (has `double-checked` + `approved` labels)?
- Does the commit message suggest anything risky (migration, breaking change, infra)?
- Any follow-up fixes that suggest a regression was introduced?

### Heartbeat Step 4: Blocker Detection

```bash
for repo in $TEAM_REPOS; do
  echo "=== $repo ==="
  # Open PRs — check pipeline progress, don't duplicate reviews
  gh pr list --repo $repo --state open --json number,title,labels,createdAt,url
  # CI status on default branch
  gh api "repos/$repo/commits?per_page=1" --jq '.[0].sha' | xargs -I{} gh api "repos/$repo/commits/{}/status" --jq '.state' 2>/dev/null || echo "no CI"
done
```

Identify blockers:
- PRs stuck >3 days without progressing through pipeline labels
- PRs with `needs-work` that haven't been updated (rework stalled)
- CI red on default branch — this blocks everything
- Dependencies between PRs across repos

### Heartbeat Step 5: Issue Backlog Hygiene

```bash
for repo in $TEAM_REPOS; do
  echo "=== $repo ==="
  gh issue list --repo $repo --state open --json number,title,labels,createdAt,updatedAt --limit 20
done
```

Actions:
- **Close resolved**: Issues whose work was completed by merged PRs
- **Flag duplicates**: Issues that describe the same problem
- **Prioritize**: Top 3 actionable items across all team repos
- **Age check**: Issues >14 days without activity — still relevant?

### Heartbeat Step 6: Worker & Tooling Gaps

Review failed missions and worker logs for patterns:

```bash
# Recent failures
curl -s "https://hooks.fellowship.dev/missions?status=failed&limit=10" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN"
```

Look for:
- Same error recurring across missions → create issue for tool/skill fix
- Workers unable to complete tasks in their domain → skill gap, needs training data or new capability
- Workers exceeding turn budgets → prompt needs tuning or task needs decomposition

### Heartbeat Step 7: Decide What's Next

Based on all inputs, decide and act:

| Situation | CTO action |
|-----------|------------|
| PR merged, no regressions | Acknowledge in report |
| PR merged, regression detected | Create issue, recommend hotfix dispatch |
| Mission failed repeatedly | Diagnose, create issue with root cause |
| Worker hitting same error | Create issue for new tool/skill |
| Goal stalled (no progress 24h) | Flag in report, recommend reprioritization |
| Architecture drift | Create issue with recommended refactor |
| Cost spike | Flag in report |
| Backlog growing | Recommend scope reduction |
| Issues resolved by merged PRs | Close them directly |
| Duplicate issues | Close the duplicate, link to original |

Create issues for significant findings:
```bash
gh issue create --repo $REPO \
  --title "[cto] [gap description]" \
  --body "[detailed description and recommended approach]" \
  --label "enhancement"
```

### Heartbeat Step 8: Output Report

```bash
REPORT_DIR="$(git rev-parse --show-toplevel)/reports"
REPORT_PATH="$REPORT_DIR/$(date +%Y-%m-%d)-cto-heartbeat-$(echo $REPO | tr '/' '-').md"
```

Report structure:
```markdown
# CTO Heartbeat: $REPO team

**Date:** YYYY-MM-DD HH:MM CLT
**Repos scanned:** [list]
**Goal context:** $GOAL_CONTEXT (or N/A)

## Mission Health
- Completed since last heartbeat: N
- Failed: N (reasons)
- Cost: $X.XX total
- Patterns: [any recurring issues]

## Recent Merges
| Repo | PR# | Title | Reviewed? | Regression risk |
|------|-----|-------|-----------|-----------------|

## Blockers
- [blocker 1 — what's stuck and why]
- [blocker 2]

## Backlog Actions Taken
- Closed #N (resolved by PR #M)
- Closed #N (duplicate of #M)
- Flagged #N as stale

## Worker/Tooling Gaps
- [gap 1 — created issue #N]

## Recommendations
1. [highest priority action for the lead]
2. [second priority]
3. [third priority]
```

Post report to Quest:
```bash
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
curl -s -X POST "https://quest.fellowship.dev/api/event" \
  -H "Authorization: Bearer $QUEST_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
content = open('$REPORT_PATH').read()
print(json.dumps({
  'source': 'commander',
  'type': 'commander.report',
  'title': 'CTO Heartbeat: $REPO',
  'meta': {'content': content, 'report_type': 'cto-heartbeat'}
}))
")" 2>/dev/null || true
```

---

## Verdict Reference

| Verdict | Emoji | Label | Merge? |
|---------|-------|-------|--------|
| LGTM | ✅ | `approved` | Yes (PR mode) / No (heartbeat) |
| REWORK | 🔄 | `needs-work` | No |
| BLOCKED | ⏸️ | `needs-work` | No |
| NEW_ISSUE | 📋 | — | Approve PR on its own merits, create separate issue |
| STALE | ⏰ | `needs-work` | No |

---

## Notes

- **The CTO review is strategic, not code-level.** Code quality was covered by the `reviewed` and `double-checked` phases. Focus on: docs gaps, ops holes, downstream risk.
- **Documentation gaps are the #1 CTO concern.** If a new feature ships without docs, the next engineer onboarding a new site will miss it.
- **Downstream opt-in vs breaking.** Template changes that are opt-in (env var gate) are fine to merge. Changes that require downstream repos to update their code are "hold" until a migration plan exists.
- **Action items must be specific.** "Update docs" is not actionable. "`docs/vercel-setup.md` — add `NEW_ENV_VAR` to the env var reference table (scope: production, required: yes)" is actionable.
- **Never merge if CI is red.** Even if the CTO review passes, failing CI is a hard blocker.
- **Post-merge reviews are valid, not wasteful.** If Max merges a PR before the CTO pipeline catches up, the checklist still runs — docs gaps, deps, and downstream impact are all still worth surfacing. The difference: action items become follow-up issues, not merge blockers. Never attempt `gh pr merge` or verdict labels on a merged PR; they're no-ops at best and loop-inducing errors at worst.
- **Heartbeat is an operating loop, not a scanner.** It reads mission logs, detects blockers, closes resolved issues, and recommends what to build next. PRs flow through the existing review pipeline — the heartbeat does not duplicate reviews.
- **The heartbeat acts on backlog hygiene.** Close issues resolved by merged PRs, flag duplicates, and keep the backlog clean. The lead owns dispatch decisions for new work.
