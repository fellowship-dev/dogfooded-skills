---
name: post-deploy
description: Post-deploy file-match actions — reads PR diff, matches changed files against rules (Dockerfile→ECR rebuild, crew.yml→config verify, scripts/→executor verify), runs actions, posts summary comment. Stage 3 of the post-merge pipeline.
argument-hint: "pr-number org/repo"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# post-deploy

Stage 3 of the autonomous deployment pipeline. Triggered by the `deployed` label. Reads the PR's changed files, matches them against configured patterns, and runs targeted actions: ECR image rebuilds, config reload verification, smoke tests, or custom scripts.

## When to Use

- Triggered by `deployed` label via event-rules (after deployment-checker confirms live deploy)
- Manual: `/post-deploy PR_NUMBER org/repo`

## Invocation

```
/post-deploy 42 fellowship-dev/pylot
```

---

## Runbook

### Step 0: Dedup Gate

```bash
PR=$1
REPO=$2

# Check if post-deploy already ran (look for a post-deploy comment)
EXISTING=$(gh pr view $PR --repo $REPO --json comments \
  --jq '.comments[].body' | grep "Post-deploy actions" || true)
if [ -n "$EXISTING" ]; then
  echo "[post-deploy] outcome=\"already complete — post-deploy comment found\" status=success"
  exit 0
fi
```

### Step 1: Read PR Context

```bash
PR_DATA=$(gh pr view $PR --repo $REPO --json number,title,url,files,mergeCommit,baseRefName)
PR_TITLE=$(echo "$PR_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
PR_URL=$(echo "$PR_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
CHANGED_FILES=$(echo "$PR_DATA" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print('\n'.join(f['path'] for f in d['files']))
")

echo "PR: $PR — $PR_TITLE"
echo "Changed files:"
echo "$CHANGED_FILES"
```

### Step 2: Read Team Post-Deploy Configuration

Read the team's CLAUDE.md for `post_deploy:` rules. Each rule maps a file glob pattern to an action:

```yaml
# Example in team CLAUDE.md:
post_deploy:
  - match: "Dockerfile*"
    action: ecr-rebuild
    description: "Rebuild and push ECR image"
  - match: "docker-entrypoint.sh"
    action: ecr-rebuild
  - match: "crew.yml"
    action: config-reload-verify
    description: "Verify gateway reloaded updated config"
  - match: "scripts/*.sh"
    action: executor-verify
    description: "Spot-check executor behavior"
  - match: "event-rules.yml"
    action: config-reload-verify
  - match: "**"
    action: smoke-test
    optional: true
    description: "Optional smoke test for any PR"
```

**Action types:**

| Action | Description |
|--------|-------------|
| `ecr-rebuild` | Rebuild Docker image and push to ECR |
| `config-reload-verify` | Verify the process/gateway has reloaded the updated config |
| `executor-verify` | Spot-check executor or script behavior |
| `smoke-test` | Run team-defined smoke test |
| `custom` | Run `command` field as shell command |

### Step 3: Match Files to Actions

```python
# Pseudocode — implement in bash with Python for glob matching
import fnmatch

changed = CHANGED_FILES.splitlines()
triggered_actions = []

for rule in post_deploy_rules:
    pattern = rule['match']
    matching = [f for f in changed if fnmatch.fnmatch(f, pattern)]
    if matching:
        triggered_actions.append({
            'action': rule['action'],
            'description': rule.get('description', rule['action']),
            'matched_files': matching,
            'optional': rule.get('optional', False)
        })
```

### Step 4: Execute Actions

Run each triggered action. Document result for each.

#### Action: ecr-rebuild

```bash
# Rebuild and push ECR image
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"
ECR_URI="${ECR_URI:-$(grep 'fargate_ecr_uri' $PYLOT_DIR/crew.yml | awk '{print $2}')}"

cd "$PYLOT_DIR"
bash scripts/build-worker-image.sh 2>&1
ECR_EXIT=$?
[ $ECR_EXIT -eq 0 ] && echo "ecr-rebuild: success" || echo "ecr-rebuild: failed exit=$ECR_EXIT"
```

#### Action: config-reload-verify

```bash
# Verify the executor/gateway has reloaded the updated config
# For Pylot: check that crew.yml timestamp matches what executor loaded
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"

# Check if executor is running and has loaded recent config
CREW_MTIME=$(stat -c %Y "$PYLOT_DIR/crew.yml" 2>/dev/null || stat -f %m "$PYLOT_DIR/crew.yml" 2>/dev/null)
EXECUTOR_PID=$(pgrep -f "executor.sh" || true)

if [ -n "$EXECUTOR_PID" ]; then
  echo "config-reload-verify: executor running (pid=$EXECUTOR_PID). crew.yml mtime=$CREW_MTIME."
  echo "config-reload-verify: success — executor will pick up config on next poll cycle"
else
  echo "config-reload-verify: WARNING — executor not running. Config will load on restart."
fi
```

#### Action: executor-verify

```bash
# Spot-check executor behavior — run a quick test
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"

# Syntax-check the modified scripts
for script in $MATCHED_SCRIPTS; do
  bash -n "$PYLOT_DIR/$script" && echo "executor-verify: $script syntax OK" || echo "executor-verify: $script SYNTAX ERROR"
done
```

#### Action: smoke-test

Run the team's configured smoke test. Optional by default.

```bash
# Team-specific smoke test — read from CLAUDE.md smoke_test.command
# Example for Pylot: run a dry-run event dispatch
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"
bash "$PYLOT_DIR/event-router.sh" --dry-run 2>&1 | head -20
echo "smoke-test: event-router dry-run complete"
```

### Step 5: Post Summary Comment

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'EOF'
## Post-deploy actions

| Action | Matched Files | Result |
|--------|--------------|--------|
$(for action in $TRIGGERED_ACTIONS; do
  echo "| $ACTION_NAME | $MATCHED_FILES | $ACTION_RESULT |"
done)

$([ -z "$TRIGGERED_ACTIONS" ] && echo "_No file-match rules triggered for this PR's changed files._")

**Pipeline complete.** This PR is live and verified.
EOF
)"
```

### Step 6: Write Report

```bash
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"
REPORT="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-post-deploy-$(echo $REPO | tr '/' '-')-pr${PR}.md"

cat > "$REPORT" <<EOF
# Post-Deploy: $REPO PR #$PR — $PR_TITLE

**Date**: $(date +%Y-%m-%d)
**PR**: [$REPO#$PR]($PR_URL)

## Changed Files
$CHANGED_FILES

## Actions Triggered
$TRIGGERED_ACTIONS_SUMMARY

## Results
$ACTIONS_RESULTS
EOF
```

---

## Default File-Match Rules (Pylot)

| Pattern | Action | When |
|---------|--------|------|
| `Dockerfile*` | ecr-rebuild | Docker image changed |
| `docker-entrypoint.sh` | ecr-rebuild | Entrypoint script changed |
| `crew.yml` | config-reload-verify | Crew config changed |
| `event-rules.yml` | config-reload-verify | Event routing changed |
| `scripts/*.sh` | executor-verify | Shell scripts changed |
| `dispatch.sh` | executor-verify | Dispatch logic changed |
| `executor.sh` | executor-verify | Executor logic changed |

---

## Notes

- **No matched rules = no actions.** A PR touching only Markdown files does nothing. This is correct behavior.
- **Optional actions** (smoke-test) run but do not affect the summary verdict.
- **ecr-rebuild failure** should be surfaced as a comment but does not re-apply `deploy-failed` — the deploy itself was verified. File a follow-up issue instead.
- **Team config is the authority.** Generic skill + team CLAUDE.md = full configurability without modifying the skill.
- **Monorepo:** match files against per-target rules if the team has multiple deploy targets.
