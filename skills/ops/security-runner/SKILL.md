---
name: security-runner
description: Use when running the automated security alert fix pipeline — opens fix PRs, creates issues for breaking changes, dismisses false positives.
argument-hint: "org/repo"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# security-runner

Executes the security triage pipeline for a target repo. Classifies open Dependabot alerts,
takes action on each, and reports results.

Run `/security-check` first to understand the classification framework this skill applies.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/skills/ops/security-runner
```

## When to Use

- Weekly cron (Monday 05:00) — automated sweep of all active repos
- After a critical CVE disclosure — targeted triage of affected repos
- After a Snyk PR/alert spike — clear the backlog before sprint starts

## Prerequisites

```bash
# Verify gh auth and repo access
gh repo view "$REPO" --json name -q .name || { echo "ERROR: cannot access $REPO"; exit 1; }

# Dependabot alerts require repo admin scope
gh api repos/"$REPO"/dependabot/alerts --paginate --jq '.[0].number' 2>&1 | head -1
```

If alerts endpoint returns 403, the token lacks `security_events` scope or Dependabot isn't enabled.

---

## Step 0: Setup

```bash
REPO="${1:-$PYLOT_REPO}"
TODAY=$(date +%Y-%m-%d)
REPORT_PATH="/tmp/security-runner-${REPO//\//-}-${TODAY}.md"

# Check merge strategy — read from Pylot control plane, not target repo
# (crew.yml lives in $PYLOT_DIR, not in the repos being scanned)
MERGE_STRATEGY=$(grep -A5 "$(echo "$REPO" | cut -d/ -f2)" "$PYLOT_DIR/crew.yml" 2>/dev/null | \
  grep merge_strategy | head -1 | awk '{print $2}' || echo "restricted")

echo "Repo: $REPO"
echo "Merge strategy: $MERGE_STRATEGY"
echo "Report: $REPORT_PATH"
```

---

## Step 1: Fetch Open Alerts

```bash
# Fetch all open Dependabot alerts
ALERTS=$(gh api repos/"$REPO"/dependabot/alerts \
  --paginate \
  --jq '.[] | select(.state=="open") | {
    number: .number,
    package: .dependency.package.name,
    ecosystem: .dependency.package.ecosystem,
    manifest: .dependency.manifest_path,
    scope: .dependency.scope,
    severity: .security_advisory.severity,
    cvss_score: .security_advisory.cvss.score,
    cve_id: .security_advisory.cve_id,
    summary: .security_advisory.summary,
    patched_versions: (.security_vulnerability.patched_versions // "none"),
    vulnerable_range: .security_vulnerability.vulnerable_version_range,
    current_version: .security_vulnerability.package.ecosystem,
    auto_dismissed: .auto_dismissed_at,
    html_url: .html_url
  }' 2>&1)

ALERT_COUNT=$(echo "$ALERTS" | python3 -c "import sys,json; data=[json.loads(l) for l in sys.stdin if l.strip()]; print(len(data))" 2>/dev/null || echo "0")
echo "Open alerts: $ALERT_COUNT"

if [ "$ALERT_COUNT" = "0" ]; then
  echo "No open alerts — nothing to do."
  echo "# Security Runner: $REPO — $TODAY" > "$REPORT_PATH"
  echo "**No open Dependabot alerts.**" >> "$REPORT_PATH"
  exit 0
fi

# Initialize counters used in Step 5 report
COUNT_P0=0; COUNT_P1=0; COUNT_P2=0; COUNT_BACKLOG=0; COUNT_DISMISS=0
DETAIL_LOG=""
```

---

## Step 2: Classify Each Alert

Apply the security-check decision matrix to each alert:

```bash
classify_alert() {
  local severity="$1"   # critical|high|medium|low
  local scope="$2"      # runtime|development (from Dependabot)
  local manifest="$3"   # path to manifest file

  # Map Dependabot scope to exploitability
  local exploitability="dev-only"
  if [ "$scope" = "runtime" ]; then
    exploitability="network-reachable"
  fi
  # test-only: infer from manifest path — only when not explicitly runtime-scoped
  # (guards against false downgrades on monorepos where test/ dirs contain runtime deps)
  if [ "$scope" != "runtime" ] && echo "$manifest" | grep -qiE 'test|spec|__tests__|cypress'; then
    exploitability="test-only"
  fi

  # Decision matrix
  case "${severity}__${exploitability}" in
    "critical__network-reachable") echo "P0" ;;
    "critical__dev-only"|"high__network-reachable") echo "P1" ;;
    "critical__test-only"|"high__dev-only"|"high__test-only"|"medium__network-reachable") echo "P2" ;;
    "medium__dev-only"|"medium__test-only"|"low__network-reachable") echo "backlog" ;;
    *) echo "dismiss" ;;
  esac
}
```

---

## Step 3: Act on Each Alert

For each alert, take the action prescribed by its classification:

### P0 / P1 — Open fix PR (safe patch) or create issue (breaking change)

```bash
process_p0_p1_alert() {
  local pkg="$1"
  local patched="$2"
  local alert_url="$3"
  local priority="$4"

  # Check if a Dependabot PR already exists for this package
  EXISTING_PR=$(gh pr list --repo "$REPO" --state open --json number,title \
    --jq ".[] | select(.title | test(\"$pkg\"; \"i\")) | .number" 2>/dev/null | head -1)

  if [ -n "$EXISTING_PR" ]; then
    echo "  → Existing PR #$EXISTING_PR for $pkg — labeling $priority"
    gh pr edit "$EXISTING_PR" --repo "$REPO" --add-label "security,$priority" 2>/dev/null || true
    # Apply merge strategy here where $EXISTING_PR is in scope
    if [ "$MERGE_STRATEGY" = "auto-merge" ]; then
      gh pr merge "$EXISTING_PR" --repo "$REPO" --auto --squash 2>/dev/null && \
        echo "  → Auto-merge enabled on PR #$EXISTING_PR"
    else
      gh pr edit "$EXISTING_PR" --repo "$REPO" --add-label "ready-to-merge" 2>/dev/null && \
        echo "  → Labeled PR #$EXISTING_PR as ready-to-merge (restricted repo — human must merge)"
    fi
    return
  fi

  if [ "$patched" = "none" ]; then
    # No patch available — create issue with upgrade path
    gh issue create --repo "$REPO" \
      --title "security: no patch for $pkg ($priority)" \
      --label "security,$priority" \
      --body "## Vulnerability\n\nPackage: \`$pkg\`\nPriority: $priority\nDependabot alert: $alert_url\n\nNo patched version available. Options:\n- [ ] Pin to last non-vulnerable version\n- [ ] Find alternative package\n- [ ] Remove dependency if unused\n\ncc: @maxfindel" 2>/dev/null
  else
    # No public GitHub API endpoint exists to trigger Dependabot PR creation directly.
    # Create a tracking issue and direct the team to bump manually or await Dependabot's schedule.
    echo "  → Patch available ($patched) — creating tracking issue for $pkg"
    gh issue create --repo "$REPO" \
      --title "security: bump $pkg to $patched ($priority)" \
      --label "security,$priority" \
      --body "## Action Required\n\nPackage: \`$pkg\`\nFixed in: \`$patched\`\nPriority: $priority\nDependabot alert: $alert_url\n\nDependabot has not auto-created a PR. Options:\n- [ ] Wait for Dependabot's next scheduled run (Mon 05:00)\n- [ ] Manually bump \`$pkg\` to \`$patched\` and open a PR\n\nMonitor: https://github.com/$REPO/security/dependabot" 2>/dev/null && \
      echo "  → Tracking issue created for $pkg → $patched"
  fi
}
```

### P2 / Backlog — Create issue

```bash
process_p2_backlog_alert() {
  local pkg="$1"
  local severity="$2"
  local summary="$3"
  local alert_url="$4"
  local priority="$5"

  # Check for existing issue before creating
  EXISTING=$(gh issue list --repo "$REPO" --state open --label security \
    --json number,title --jq ".[] | select(.title | test(\"$pkg\"; \"i\")) | .number" 2>/dev/null | head -1)

  if [ -n "$EXISTING" ]; then
    echo "  → Existing issue #$EXISTING for $pkg — skipping duplicate"
    return
  fi

  gh issue create --repo "$REPO" \
    --title "security: upgrade $pkg ($severity — $priority)" \
    --label "security,$priority" \
    --body "## Vulnerability\n\nPackage: \`$pkg\`\nSeverity: $severity\nSummary: $summary\nDependabot alert: $alert_url\n\nBatch in next monthly dependency cycle. Verify no breaking changes before upgrading." 2>/dev/null
}
```

### Dismiss — False positive or irrelevant

```bash
dismiss_alert() {
  local alert_number="$1"
  local reason="$2"  # tolerated_risk | inaccurate | not_used | no_bandwidth

  gh api repos/"$REPO"/dependabot/alerts/"$alert_number" \
    --method PATCH \
    --field state=dismissed \
    --field dismissed_reason="$reason" \
    --field dismissed_comment="Dismissed by security-runner: $reason. Review quarterly." 2>/dev/null
  echo "  → Dismissed alert #$alert_number (reason: $reason)"
}
```

---

## Step 3b: Orchestrate — Iterate Over All Alerts

After defining the functions above, iterate over `$ALERTS` and route each alert:

```bash
# Process substitution keeps the loop in the current shell so counter variables
# (COUNT_P0, DETAIL_LOG, etc.) survive to Step 5. A pipe would run the body in a
# subshell and silently discard every assignment.
while IFS= read -r alert_json; do
  [ -z "$alert_json" ] && continue

  pkg=$(echo "$alert_json"       | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['package'])")
  severity=$(echo "$alert_json"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['severity'])")
  scope=$(echo "$alert_json"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('scope','development'))")
  manifest=$(echo "$alert_json"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['manifest'])")
  patched=$(echo "$alert_json"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['patched_versions'])")
  summary=$(echo "$alert_json"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['summary'])")
  alert_url=$(echo "$alert_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['html_url'])")
  alert_num=$(echo "$alert_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['number'])")

  priority=$(classify_alert "$severity" "$scope" "$manifest")
  echo "[$priority] $pkg ($severity, scope=$scope)"
  DETAIL_LOG="${DETAIL_LOG}\n- [$priority] \`$pkg\` — $severity — $summary"

  case "$priority" in
    P0|P1)
      process_p0_p1_alert "$pkg" "$patched" "$alert_url" "$priority"
      [ "$priority" = "P0" ] && COUNT_P0=$((COUNT_P0 + 1)) || COUNT_P1=$((COUNT_P1 + 1))
      ;;
    P2)
      process_p2_backlog_alert "$pkg" "$severity" "$summary" "$alert_url" "$priority"
      COUNT_P2=$((COUNT_P2 + 1))
      ;;
    backlog)
      process_p2_backlog_alert "$pkg" "$severity" "$summary" "$alert_url" "$priority"
      COUNT_BACKLOG=$((COUNT_BACKLOG + 1))
      ;;
    dismiss)
      dismiss_alert "$alert_num" "tolerated_risk"
      COUNT_DISMISS=$((COUNT_DISMISS + 1))
      ;;
  esac
done < <(echo "$ALERTS")
```

---

## Step 4: Respect Merge Strategy

Merge-strategy enforcement is applied inside `process_p0_p1_alert` (Step 3 above)
where the PR number is already in scope via `$EXISTING_PR`. The strategy is read once
in Step 0 (`$MERGE_STRATEGY`) and is available to the function as a global.

---

## Step 5: Generate Summary Report

```bash
cat > "$REPORT_PATH" << REPORT
# Security Runner: $REPO

**Date:** $TODAY
**Alerts scanned:** $ALERT_COUNT
**Merge strategy:** $MERGE_STRATEGY

## Summary

| Priority | Count | Action |
|---|---|---|
| P0 | $COUNT_P0 | PRs opened / existing PRs labeled |
| P1 | $COUNT_P1 | PRs opened / existing PRs labeled |
| P2 | $COUNT_P2 | Issues created for batch cycle |
| Backlog | $COUNT_BACKLOG | Issues created (no urgency) |
| Dismissed | $COUNT_DISMISS | Dismissed via API |

## Detail

$DETAIL_LOG

## Next Steps

- P0/P1 PRs: review and merge within priority window
- P2 issues: include in next monthly dependency batch (/deps-runner)
- Dismissed alerts: review quarterly for changed risk posture
- Re-run: \`/security-runner $REPO\` after merges to confirm 0 open alerts
REPORT

echo "Report saved: $REPORT_PATH"
cat "$REPORT_PATH"
```

---

## Step 6: Post Report (optional)

If running in Pylot context:

```bash
# Post to Quest
if [ -n "$PYLOT_API" ] && [ -n "$GH_TOKEN" ]; then
  curl -s -X POST "${PYLOT_API}/admin/events" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json, sys
content = open('$REPORT_PATH').read()
print(json.dumps({
  'source': 'security-runner',
  'type': 'security.triage',
  'title': 'Security Triage: $REPO',
  'meta': {'content': content, 'repo': '$REPO', 'alert_count': $ALERT_COUNT}
}))
")" 2>/dev/null || true
fi
```

---

## Full Pipeline (orchestration example)

```bash
#!/bin/bash
# Run security-runner against all active fellowship-dev repos
REPOS="fellowship-dev/booster-pack fellowship-dev/inbox-angel fellowship-dev/pylot fellowship-dev/quest fellowship-dev/spec-kit fellowship-dev/v0-operator fellowship-dev/dogfooded-skills fellowship-dev/flowchad"

for REPO in $REPOS; do
  echo "=== Triaging $REPO ==="
  /security-runner "$REPO" || echo "WARN: runner failed for $REPO"
done
```

---

## Cron Integration

```yaml
# In crew.yml, per team:
cron:
  - schedule: "0 5 * * 1"   # Every Monday at 05:00
    task: "Weekly security triage: process open Dependabot/Snyk alerts, open fix PRs for safe patches"
```

---

## Output: Pylot Outcome Marker

Emit on completion:

```
```

---

## Related Skills

- `/security-check` — the classification framework this skill executes
- `/deps-runner` — non-security dependency updates; same PR pattern
- `/entropy-check` — can incorporate security scores into domain grades
- `/maintenance` — checks whether Dependabot is configured at all
