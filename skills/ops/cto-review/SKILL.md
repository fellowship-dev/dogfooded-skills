---
name: cto-review
description: Strategic CTO checklist for PR review — documentation gaps, external dependencies, downstream/template impact, merge strategy, action items. Posts structured GH review comment, applies label, merges if ready.
argument-hint: "[pr-number] [org/repo]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# cto-review

Strategic CTO-level PR review. Runs a structured checklist (docs, deps, downstream impact, merge strategy, action items), posts a formatted review comment to the PR, applies appropriate label, and merges if everything passes.

## When to Use

- After a PR gets the `double-checked` label (event-triggered)
- Manual CTO sign-off before merging an agent-generated PR
- Any PR that touches docs, adds external dependencies, or has downstream template impact

## Invocation

```
/cto-review PR_NUMBER org/repo
```

**Examples:**
```
/cto-review 742 fellowship-dev/booster-pack
/cto-review 84 Lexgo-cl/rails-backend
```

## Token

```bash
export GH_TOKEN=$(grep 'GH_TOKEN' /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | grep -v '#' | head -1 | cut -d= -f2)
# Or for specific teams, use the team's token_var from crew.yml
```

## Prerequisites

```bash
gh auth status          # GH CLI must be authenticated
gh pr view $PR_NUMBER --repo $REPO   # verify PR exists
```

---

## Runbook

### Step 1: Gather PR Context

```bash
export PR=$1          # first argument
export REPO=$2        # second argument (org/repo)

# Load token — try team-specific first, fall back to fellowship token
export GH_TOKEN=$(grep 'GH_TOKEN_FELLOWSHIP' /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)

# Fetch PR metadata
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

# Fetch linked issue (extract from PR body or branch name)
gh pr view $PR --repo $REPO --json body --jq '.body'

# Check existing labels
gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'

# Get the diff summary (key files changed)
gh pr diff $PR --repo $REPO --name-only
```

**Key intel to extract:**
- PR title, description, branch name
- Files changed (focus: docs, deps, config, templates)
- Linked issue number and title
- Whether `reviewed` and `double-checked` labels are present

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
cat /home/ubuntu/projects/fellowship-dev/pylot/crew.yml
```

For each downstream repo, assess:
- Do they inherit deps/config from this PR's changes?
- Is the change breaking (requires update) or opt-in?
- When do downstream repos need to pull these changes?

#### 2.4 Merge Strategy Decision

Based on findings above, decide one of:
- **✅ Merge immediately** — all docs present, no breaking downstream changes, no required manual steps
- **⏸️ Hold for action items** — code is good, but N documented items must be done first
- **🔄 Send back** — code has issues that need fixing before merge is appropriate

#### 2.5 Action Items

List numbered must-do items. Each item should be specific and actionable:
1. `path/to/file.md` — exact change needed
2. `path/to/other.yml` — exact change needed

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

```bash
# Create labels if they don't exist
gh label create "approved" --repo $REPO --color "0e8a16" --description "CTO approved — ready to merge" 2>/dev/null || true
gh label create "needs-work" --repo $REPO --color "d93f0b" --description "Needs work before merge" 2>/dev/null || true

# Apply appropriate label based on verdict
if [[ "$VERDICT" == "merge" ]]; then
  gh pr edit $PR --repo $REPO --add-label "approved"
elif [[ "$VERDICT" == "hold" || "$VERDICT" == "sendback" ]]; then
  gh pr edit $PR --repo $REPO --add-label "needs-work"
fi
```

### Step 5: Merge or Label (respects merge_strategy)

Check `merge_strategy` from crew.yml for the team that owns this repo:

```bash
# Read merge_strategy from crew.yml
CREW_FILE="/home/ubuntu/projects/fellowship-dev/pylot/crew.yml"
MERGE_STRATEGY=$(python3 -c "
import yaml
with open('$CREW_FILE') as f:
    data = yaml.safe_load(f)
for name, config in data.get('crew', {}).items():
    for repo in config.get('repos', []):
        if repo == '$REPO':
            print(config.get('merge_strategy', 'auto'))
            break
" 2>/dev/null)
```

**If `label-only`:** apply `approved` label only — Max is the merge gatekeeper:
```bash
gh pr edit $PR --repo $REPO --add-label "approved"
# Do NOT merge. Max will merge after reviewing the nightly recap.
```

**If `auto` (or unset):** merge directly after verifying CI and labels:
```bash
# Verify CI is green before merging
gh pr checks $PR --repo $REPO

# Verify required labels
gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'

# Merge
gh pr merge $PR --repo $REPO --merge
```

If CI is failing: set verdict to "hold", note CI failure in comment, do NOT merge.

### Step 6: Report

Write a report to the commander reports directory:

```bash
REPORT_PATH="/home/ubuntu/projects/fellowship-dev/pylot/reports/$(date +%Y-%m-%d)-cto-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
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
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
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

## Verdict Reference

| Verdict | Emoji | Label | Merge? |
|---------|-------|-------|--------|
| Merge immediately | ✅ | `approved` | Only if `merge_strategy: auto`. If `label-only`: label only, Max merges. |
| Hold for action items | ⏸️ | `needs-work` | No |
| Send back | 🔄 | `needs-work` | No |

---

## Notes

- **The CTO review is strategic, not code-level.** Code quality was covered by the `reviewed` and `double-checked` phases. Focus on: docs gaps, ops holes, downstream risk.
- **Documentation gaps are the #1 CTO concern.** If a new feature ships without docs, the next engineer onboarding a new site will miss it.
- **Downstream opt-in vs breaking.** Template changes that are opt-in (env var gate) are fine to merge. Changes that require downstream repos to update their code are "hold" until a migration plan exists.
- **Action items must be specific.** "Update docs" is not actionable. "`docs/vercel-setup.md` — add `NEW_ENV_VAR` to the env var reference table (scope: production, required: yes)" is actionable.
- **Never merge if CI is red.** Even if the CTO review passes, failing CI is a hard blocker.
