---
name: cto-heartbeat
description: Flow optimizer operating loop — WIP scan, active epic focus, triage unlabeled issues, dispatch one task, report. Implements "stop starting, start finishing" via persistent label-driven state.
argument-hint: "org/repo [goal-context]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# cto-heartbeat

Flow optimizer operating loop for a repo. Unblocks WIP first, triages unlabeled issues, and dispatches exactly one task per run.

This skill implements the operating principles defined in the `cto` role skill.

## Invocation

```
/cto-heartbeat org/repo [goal-context]
```

**Examples:**
```
/cto-heartbeat fellowship-dev/booster-pack
/cto-heartbeat fellowship-dev/booster-pack "focus: Vercel deployment pipeline"
```

## Token

```bash
export GH_TOKEN=$(grep "GH_PAT_FELLOWSHIP" $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
# Or for specific teams, use the team's token_var from crew.yml
```

---

## Step 0: Bootstrap Labels (idempotent)

Create labels in the target repo if they do not exist. Run every time — `gh label create` is idempotent (errors silently if label exists).

```bash
export REPO=$1
export GOAL_CONTEXT="${@:2}"
export GH_TOKEN=$(grep "GH_PAT_FELLOWSHIP" $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)

# Priority labels
gh label create "P0" --repo $REPO --color "b60205" --description "Production broken, revenue impact, security — fix now" 2>/dev/null || true
gh label create "P1" --repo $REPO --color "d93f0b" --description "Important but not urgent — fix this week" 2>/dev/null || true
gh label create "P2" --repo $REPO --color "fbca04" --description "Nice to have — fix when convenient" 2>/dev/null || true

# Status labels
gh label create "dispatched" --repo $REPO --color "5319e7" --description "Work sent to a crew member" 2>/dev/null || true
gh label create "blocked" --repo $REPO --color "c5def5" --description "Waiting on external input or another issue" 2>/dev/null || true
```

## Step 1: WIP Scan (unblock before new work)

Check the current state of in-flight work before doing anything else. The principle: **stop starting, start finishing.**

```bash
# Open PRs across the repo
gh pr list --repo $REPO --state open --json number,title,labels,createdAt,url

# Issues with dispatched label (work in progress)
gh issue list --repo $REPO --label "dispatched" --state open --json number,title,labels,assignees,url

# Issues with blocked label
gh issue list --repo $REPO --label "blocked" --state open --json number,title,labels,url

# Check if any dispatched issues have associated merged PRs (work completed but label not cleaned up)
# For each dispatched issue, check if there is a recently merged PR that references it
```

Actions:
- **Dispatched issue has a merged PR?** → Close the issue or remove `dispatched` label, acknowledge completion
- **Dispatched issue has an open PR stuck >2 days?** → Flag as blocker, investigate
- **Dispatched issue has no PR at all and was dispatched >3 days ago?** → Flag as stale dispatch
- **Blocked issue** → Check if the blocker is resolved; if so, remove `blocked` label and re-prioritize
- **PR stuck without progressing through review pipeline** → Flag

**Output**: List of WIP items and their status. Any actions taken (labels removed, issues closed).

## Step 2: Active Epic Focus

Determine which epic is currently in progress. An "active epic" is one that has at least one open issue with the `dispatched` label.

```bash
# Find which epic labels have dispatched issues
gh issue list --repo $REPO --label "dispatched" --state open --json labels --jq ".[].labels[].name" | sort -u
```

Filter out metadata labels (P0, P1, P2, dispatched, blocked, bug, enhancement, documentation, etc.) — whatever remains is an epic label.

Rules:
- If exactly one epic has dispatched work → that is the **active epic**. Focus all subsequent steps on it.
- If multiple epics have dispatched work → the one with the most dispatched issues is active. Flag the split as a concern.
- If no epic has dispatched work (WIP=0) → no active epic. Step 4 will pick from highest-priority across all epics.

**Output**: Active epic name (or "none — WIP is clear").

## Step 3: Triage New Issues (max 5)

Find issues that lack priority labels and triage them.

```bash
# All open issues
gh issue list --repo $REPO --state open --json number,title,labels,body,createdAt --limit 50

# Filter: issues without P0, P1, or P2 labels (done in code/logic, not pure CLI)
```

For each unlabeled issue (up to 5):
1. Read the issue title and body
2. Assign a priority label: P0, P1, or P2
3. Assign an epic label if it fits an existing epic, or create a new epic label if the issue represents a new workstream
4. Apply the labels:
```bash
gh issue edit $ISSUE_NUM --repo $REPO --add-label "P1,epic-name"
```

**Skip** issues that already have a priority label (P0/P1/P2). The heartbeat does not re-triage.

**Output**: Table of triaged issues with assigned priority and epic.

## Step 4: Dispatch One Task

Pick exactly one issue to dispatch. Dispatch means: add the `dispatched` label so the crew lead knows to assign it.

Priority order:
1. **Active epic, highest priority first**: P0 > P1 > P2, within the active epic
2. **If no active epic**: highest priority issue across all epics
3. **If nothing to dispatch**: report "backlog clear" or "all dispatched"

```bash
# Find undispatched issues in the active epic, sorted by priority
gh issue list --repo $REPO --label "$ACTIVE_EPIC" --state open --json number,title,labels --limit 20
# Filter out issues that already have "dispatched" label
# Pick the highest priority one

# Add dispatched label
gh issue edit $ISSUE_NUM --repo $REPO --add-label "dispatched"
```

### Build-train suggestion

If 2+ undispatched issues exist on the same repo (after filtering out `dispatched` and `blocked`), consider dispatching `/build-train org/repo --issues N,M,...` instead of a single issue. This bundles work into one build branch and runs the review pipeline once instead of per-PR. Use your judgement — build-train makes sense when the issues are independent and can be worked in parallel. Skip it for tightly coupled issues that need sequential implementation.

Rules:
- **Never dispatch if WIP > 3** — too much in flight. Focus on unblocking instead.
- **One dispatch per heartbeat** — do not batch (unless using build-train, which counts as one dispatch).

**Output**: Issue number, title, priority, epic — or reason nothing was dispatched. If suggesting build-train, list the bundled issues.

## Step 5: Report

```bash
REPORT_DIR="$(git rev-parse --show-toplevel)/reports"
REPORT_PATH="$REPORT_DIR/$(date +%Y-%m-%d)-cto-heartbeat-$(echo $REPO | tr "/" "-").md"
```

Report structure:
```markdown
# CTO Heartbeat: [repo name]

**Date:** YYYY-MM-DD HH:MM
**Repo:** $REPO
**Active epic:** [epic name or "none"]
**Goal context:** $GOAL_CONTEXT (or "N/A")

## WIP Status
| Issue | Title | Status | Epic | Priority |
|-------|-------|--------|------|----------|
| #N | ... | dispatched / blocked / stale | epic-name | P1 |

## Actions Taken
- Closed #N (resolved by PR #M)
- Removed dispatched from #N (stale >3 days)
- Unblocked #N (blocker resolved)

## Triage
| Issue | Title | Priority | Epic |
|-------|-------|----------|------|
| #N | ... | P1 | epic-name |

## Dispatched
- **#N — [title]** (P1, epic: [name]) — dispatched for crew execution

## Blockers
- [blocker description — what is stuck and why]

## Recommendations
1. [highest priority action]
2. [second priority]
```

Post report to Quest:
```bash
QUEST_TOKEN=$(grep "^QUEST_TOKEN=" $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
curl -s -X POST "http://127.0.0.1:4242/api/event" \
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
| LGTM | ✅ | `approved` | No (heartbeat dispatches issues, not PRs) |
| REWORK | 🔄 | `needs-work` | No |
| BLOCKED | ⏸️ | `needs-work` | No |
| NEW_ISSUE | 📋 | — | Create separate issue |
| STALE | ⏰ | `needs-work` | No |

---

## Notes

- **Heartbeat is a flow optimizer, not a scanner.** It unblocks WIP first (stop starting, start finishing), triages unlabeled issues with P0/P1/P2 and epic labels, and dispatches exactly one task per run. One-at-a-time dispatch keeps the team focused and prevents WIP sprawl.
- **The heartbeat acts on backlog hygiene.** Close issues resolved by merged PRs, flag duplicates, and keep the backlog clean. The lead owns dispatch decisions for new work.
- **Never dispatch if WIP > 3** — too much in flight. The heartbeat's job in that case is to unblock, not to add more.
- For PR review functionality, see `/cto-review`. For CTO role principles, see the `cto` role skill.
