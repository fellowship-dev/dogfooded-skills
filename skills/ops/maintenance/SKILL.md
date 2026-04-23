---
name: maintenance
description: Infra-only health audit — LaunchAgent health, cron log errors, system health, secrets scan, label sync, stale branches, dependabot, booster-pack sync, memory consolidation, open issues. Never fixes autonomously.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
---

# Maintenance

Infra health audit. Investigate → Flag → Create issues. **Never modify code, configs, or repo contents.**

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/ops/maintenance
```

> **Architecture/doc checks have moved to `/entropy-check`.** This skill covers infrastructure only:
> processes, secrets, labels, branches, dependencies, system health, and memory hygiene.

## When to Use

- Weekly scheduled run (cron) — full infra sweep
- After a system change (new LaunchAgent, new cron job)
- When an automated task seems to have stopped working
- When disk or brew issues are suspected

## Guiding Principle

Maintenance takes 10x more effort than building. This job surfaces problems Max can't see day-to-day. Output: a report + GitHub issues for anything worth tracking.

---

## Instructions

Run ALL checks. Each finding either becomes a GitHub issue in [fellowship-dev/claude-buddy](https://github.com/fellowship-dev/claude-buddy) or is noted as clean.

```bash
# Set GH_TOKEN at the start of every run
export GH_TOKEN=$(grep GH_TOKEN_FELLOWSHIP /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
```

---

### 1. Memory Consolidation (always)

```bash
wc -l /home/ubuntu/projects/fellowship-dev/claude-buddy/memory/MEMORY.md
ls ~/.claude/projects/-Users-maxfindel-Projects-claude-buddy/*.jsonl | wc -l
```

- MEMORY.md >180 lines → compact, run `/save-memory`
- JSONL session files: ignore accumulation — ~5MB each is fine, no action needed

---

### 2. Secrets Scan

```bash
grep -r "ghp_\|ghs_\|sk-\|xoxb-\|AAEi\|AAAA[a-zA-Z0-9]" \
  /home/ubuntu/projects/fellowship-dev/claude-buddy/ \
  --include="*.md" --include="*.sh" --include="*.py" --include="*.mjs" \
  -l 2>/dev/null | grep -v ".git"
```

Flag any file with a live-looking token/key that is git-tracked.

---

### 3. Dependabot Coverage

Read `PROJECTS.md`. For every active repo (Products + Tooling, skip FVL):

```bash
GH_TOKEN=$GH_TOKEN gh api repos/{org}/{repo}/contents/.github/dependabot.yml 2>&1
```

- Missing config → flag as issue
- Config present but silent >30 days → flag

---

### 4. Stale Branches

For active repos, check for branches that are merged but not deleted:

```bash
GH_TOKEN=$GH_TOKEN gh api repos/{org}/{repo}/branches --paginate \
  --jq '.[].name' 2>/dev/null
# Cross-reference against merged PRs
```

Flag repos with >5 stale merged branches.

---

### 5. LaunchAgent Health

```bash
ls ~/Library/LaunchAgents/fry.*.plist | while read f; do
  target=$(grep -o '/[^<]*' "$f" | grep -E '\.sh|\.py|\.mjs' | head -1)
  [ -f "$target" ] || echo "MISSING: $f → $target"
done
launchctl list | grep fry
```

Flag any plist pointing to a missing file, or any fry agent not loaded.

---

### 6. Cron Log Errors (last 7 days)

```bash
ls -t ~/.local/share/fry-bot/cron-logs/*.log | head -20 | xargs grep -l "FAILED\|ERROR\|timeout" 2>/dev/null
```

Recurring failures in the same job = flag as issue with log excerpt.

---

### 7. PROJECTS.md Accuracy

- Check repos listed as active: do they still exist on GitHub?
- Check repos listed as Dormant: any commits in last 30 days?
- Any new repos Max created that aren't in PROJECTS.md?

```bash
GH_TOKEN=$GH_TOKEN gh repo list {org} --json name,isArchived,pushedAt --limit 50
```

Run for: maxfindel, fellowship-dev, Lexgo-cl, CLAPES-UC, Energia-UC.

---

### 8. Spacestation System Health

```bash
brew outdated --quiet | wc -l
df -h / | tail -1
```

- Brew packages outdated >20 → flag
- Disk >85% used → flag

---

### 9. Label Sync

Verify standard labels across active repos.

For each active fellowship-dev repo (farmesa, inbox-angel, booster-pack, mtg-lotr, commander):

```bash
STANDARD="ready-to-work in-progress needs-manual-review reviewed double-checked ready-to-merge groundwork dependencies bug enhancement documentation"
for repo in farmesa inbox-angel booster-pack mtg-lotr commander; do
  existing=$(GH_TOKEN=$GH_TOKEN gh label list --repo fellowship-dev/$repo \
    --json name --jq '.[].name' 2>/dev/null | tr '\n' ' ')
  for label in $STANDARD; do
    echo "$existing" | grep -q "$label" || echo "MISSING: fellowship-dev/$repo → $label"
  done
done
```

- Any missing labels → run `gh label create` to add them (idempotent, safe to do inline)
- Report how many were created vs already present

---

### 10. Booster-Pack Sync

Pull changes into dependent sites.

Find all local repos that have a `booster` git remote:

```bash
for dir in ~/Projects/fellowship-dev/*/; do
  if git -C "$dir" remote | grep -q '^booster$' 2>/dev/null; then
    repo=$(basename "$dir")
    BEHIND=$(git -C "$dir" rev-list HEAD..booster/main --count 2>/dev/null || echo "?")
    echo "fellowship-dev/$repo: $BEHIND commits behind booster-pack"
  fi
done
```

- If any site is >0 commits behind → queue a task in overnight-tasks.md: `pull-booster-{repo-slug}`, type `maintenance`, executor `{project-path}`, prompt `git pull booster main --no-edit && git push`.
- If there are conflicts → flag for Max instead, do not pull autonomously.

---

### 11. Open Issues in fellowship-dev/claude-buddy

List all open issues — no action, just surface in report so Max sees the backlog.

```bash
GH_TOKEN=$GH_TOKEN gh issue list --repo fellowship-dev/claude-buddy --state open \
  --json number,title,labels,createdAt
```

---

## Creating Issues

**Before creating any issue, check for duplicates:**

```bash
# Fetch open + closed issue titles (closed catches older attempts at the same problem)
GH_TOKEN=$GH_TOKEN gh issue list --repo fellowship-dev/claude-buddy \
  --state all --limit 200 --json number,title,state \
  --jq '.[] | "\(.state) #\(.number): \(.title)"'
```

- If a matching open issue already exists → add a comment or just note it in the report. Do NOT create a duplicate.
- If a matching closed issue exists → only re-open or create a new one if the problem has clearly recurred. Note the previous issue number in the body.

For each **new** finding with no existing issue:

```bash
GH_TOKEN=$GH_TOKEN gh issue create \
  --repo fellowship-dev/claude-buddy \
  --title "Maintenance: {finding}" \
  --label "maintenance" \
  --body "..."
```

---

## Output

Save report to `reports/maintenance/YYYY-MM-DD.md`:

```markdown
# Maintenance Report — YYYY-MM-DD

## Checks Run
- [x] Memory consolidation
- [x] Secrets scan
- [x] Dependabot coverage
- [x] Stale branches
- [x] LaunchAgent health
- [x] Cron log errors
- [x] PROJECTS.md accuracy
- [x] Spacestation system health
- [x] Label sync
- [x] Booster-pack sync
- [x] Open issues review

> Note: Architecture/doc drift checks have moved to /entropy-check (separate skill)

## Findings

### Issues Created
- issue [fellowship-dev/claude-buddy#N](url): {title}

### Clean
- {area}: nothing flagged

### Noted (no issue, low severity)
- {finding}

## Memory
- MEMORY.md: {N} lines
- JSONL sessions: {N} files
```

Then output a short Telegram summary:

```
🔧 Maintenance — YYYY-MM-DD

{N} issues created: [list with links]
{N} areas clean
Memory: {N}/200 lines

Full report: reports/maintenance/YYYY-MM-DD.md
```

---

## What Was Removed from This Skill

**Section 11 (Imported lib drift — speckit and toolkit)** was extracted to `/entropy-check`.

**Why:** Checking whether speckit commands match the source of truth is an architecture/doc check — it measures whether the tooling knowledge layer is current. Entropy-check owns all doc/architecture freshness signals. This skill owns infra only.

To check speckit drift: run `/entropy-check` against the target repo.
