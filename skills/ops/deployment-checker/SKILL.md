---
name: deployment-checker
description: Deployment health poller — runs a team bash script to poll health endpoint until deployed sha matches, exits with structured result, applies deployed or deploy-failed label. Stage 2 of the post-merge pipeline. Zero token burn during polling.
argument-hint: "pr-number org/repo"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# deployment-checker

Stage 2 of the autonomous deployment pipeline. Polls the team's health endpoint using a cheap bash script until the deployed sha matches the merged PR's sha, or times out. Exits with a structured result and applies `deployed` or `deploy-failed` label.

**Design goal:** zero token burn during polling. The Claude agent runs only to set up the poll and process the result. All polling is done by the bash script.

## When to Use

- Dispatched by `/post-merge` after a PR merges
- Manual: `/deployment-checker PR_NUMBER org/repo`

## Invocation

```
/deployment-checker 42 fellowship-dev/pylot
```

## Arguments

```bash
PR_NUMBER=$1    # PR number
REPO=$2         # org/repo
```

---

## Runbook

### Step 0: Dedup Gate

```bash
PR=$1
REPO=$2

ALREADY_DONE=$(gh pr view $PR --repo $REPO --json labels \
  --jq '[.labels[].name] | (contains(["deployed"]) or contains(["deploy-failed"]))')
if [ "$ALREADY_DONE" = "true" ]; then
  echo "[deployment-checker] outcome=\"already complete — deployed or deploy-failed label present\" status=success"
  exit 0
fi
```

### Step 1: Read Context from Job

Extract parameters from the job context (set by `/post-merge`):

```bash
# These are passed via job context or derived from PR
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')
PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')

# From job context (set by post-merge):
#   EXPECTED_SHA   — merge commit sha to wait for
#   HEALTH_URL     — endpoint to poll
#   TIMEOUT_MINUTES — max wait (default: 5)
#   CHECKER_SCRIPT  — path to team bash polling script
#   POLL_INTERVAL   — seconds between polls (default: 30)

EXPECTED_SHA="${EXPECTED_SHA:-}"
HEALTH_URL="${HEALTH_URL:-}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-5}"
CHECKER_SCRIPT="${CHECKER_SCRIPT:-}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

if [ -z "$HEALTH_URL" ] || [ -z "$CHECKER_SCRIPT" ]; then
  echo "[deployment-checker] ERROR: HEALTH_URL and CHECKER_SCRIPT must be set in job context" >&2
  exit 1
fi
```

### Step 2: Run the Bash Polling Script

The team-specific bash script handles the actual polling. This keeps Claude out of the loop during the wait.

```bash
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"

# Resolve checker script path
if [[ "$CHECKER_SCRIPT" != /* ]]; then
  CHECKER_SCRIPT="$PYLOT_DIR/$CHECKER_SCRIPT"
fi

if [ ! -f "$CHECKER_SCRIPT" ]; then
  echo "[deployment-checker] ERROR: checker script not found: $CHECKER_SCRIPT" >&2
  DEPLOY_STATUS="failed"
  FAILURE_REASON="checker script not found: $CHECKER_SCRIPT"
else
  chmod +x "$CHECKER_SCRIPT"
  # Run the script; it exits 0 on success, non-zero on failure/timeout
  # stdout: "deploy_status=success sha=abc123" or "deploy_status=failed reason=OOM"
  POLL_OUTPUT=$(HEALTH_URL="$HEALTH_URL" \
    EXPECTED_SHA="$EXPECTED_SHA" \
    TIMEOUT_MINUTES="$TIMEOUT_MINUTES" \
    POLL_INTERVAL="$POLL_INTERVAL" \
    bash "$CHECKER_SCRIPT" 2>&1) && POLL_EXIT=0 || POLL_EXIT=$?

  echo "Checker output: $POLL_OUTPUT"

  # Parse structured output (python3 avoids grep -P which is unavailable on macOS/BSD)
  DEPLOY_STATUS=$(echo "$POLL_OUTPUT" | python3 -c "import sys,re; m=re.search(r'deploy_status=(\S+)', sys.stdin.read()); print(m.group(1) if m else 'failed')" 2>/dev/null || echo "failed")
  DEPLOYED_SHA=$(echo "$POLL_OUTPUT" | python3 -c "import sys,re; m=re.search(r'sha=(\S+)', sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null || echo "")
  FAILURE_REASON=$(echo "$POLL_OUTPUT" | python3 -c "import sys,re; m=re.search(r'reason=(.+)', sys.stdin.read()); print(m.group(1).strip() if m else 'unknown')" 2>/dev/null || echo "unknown")
fi
```

### Step 3: Apply Label and Comment

**On success:**

```bash
if [ "$DEPLOY_STATUS" = "success" ]; then
  # Create label if missing
  gh label create "deployed" --repo $REPO --color "0e8a16" \
    --description "Deploy verified — health check passed" 2>/dev/null || true

  gh pr edit $PR --repo $REPO --add-label "deployed"

  gh pr comment $PR --repo $REPO --body "$(cat <<EOF
**Deployment verified** ✅

| Field | Value |
|-------|-------|
| Status | \`success\` |
| Deployed SHA | \`${DEPLOYED_SHA:-confirmed}\` |
| Health URL | \`$HEALTH_URL\` |
| Waited | up to ${TIMEOUT_MINUTES} min |

The \`deployed\` label triggers post-deploy file-match actions.
EOF
)"
fi
```

**On failure or timeout:**

```bash
if [ "$DEPLOY_STATUS" != "success" ]; then
  # Create label if missing
  gh label create "deploy-failed" --repo $REPO --color "d93f0b" \
    --description "Deploy verification failed or timed out" 2>/dev/null || true

  gh pr edit $PR --repo $REPO --add-label "deploy-failed"

  gh pr comment $PR --repo $REPO --body "$(cat <<EOF
**Deployment check failed** ❌

| Field | Value |
|-------|-------|
| Status | \`failed\` |
| Reason | ${FAILURE_REASON} |
| Health URL | \`$HEALTH_URL\` |
| Timeout | ${TIMEOUT_MINUTES} min |
| Expected SHA | \`${EXPECTED_SHA:-unknown}\` |

**Action required:** Check the deployment manually. Remove \`deploy-failed\` and re-add \`deployed\` once confirmed.
EOF
)"
fi
```

### Step 4: Write Report

```bash
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"
REPORT="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-deployment-checker-$(echo $REPO | tr '/' '-')-pr${PR}.md"

cat > "$REPORT" <<EOF
# Deployment Checker: $REPO PR #$PR

**Date**: $(date +%Y-%m-%d)
**PR**: [$REPO#$PR]($PR_URL) — $PR_TITLE
**Status**: $DEPLOY_STATUS
**SHA**: ${DEPLOYED_SHA:-not confirmed}
**Reason**: ${FAILURE_REASON:-n/a}

## Poll Output
\`\`\`
$POLL_OUTPUT
\`\`\`
EOF
```

---

## Team Checker Script Interface

Each team provides a bash script at a path configured in their CLAUDE.md. The script must:

**Inputs (env vars):**

| Variable | Required | Description |
|----------|----------|-------------|
| `HEALTH_URL` | yes | URL to GET for health check |
| `EXPECTED_SHA` | no | Git sha to wait for (compare against health response) |
| `TIMEOUT_MINUTES` | no | Max wait in minutes (default: 5) |
| `POLL_INTERVAL` | no | Seconds between polls (default: 30) |

**Exit codes:**
- `0` — deployment confirmed
- `1` — timeout or failure

**stdout format (last line):**
```
deploy_status=success sha=abc123def456
deploy_status=failed reason=timeout_after_5min
deploy_status=failed reason=health_check_returned_503
```

**Example minimal script:**
```bash
#!/bin/bash
# scripts/deployment-checker-pylot.sh
TIMEOUT=$((${TIMEOUT_MINUTES:-5} * 60))
INTERVAL=${POLL_INTERVAL:-30}
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  RESPONSE=$(curl -sf "$HEALTH_URL" 2>/dev/null || echo "")
  CURRENT_SHA=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null || echo "")

  if [ -n "$EXPECTED_SHA" ] && [ "$CURRENT_SHA" = "$EXPECTED_SHA" ]; then
    echo "deploy_status=success sha=$CURRENT_SHA"
    exit 0
  elif [ -z "$EXPECTED_SHA" ] && [ -n "$RESPONSE" ]; then
    # No sha to compare — just verify health returns 200
    echo "deploy_status=success sha=confirmed"
    exit 0
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "deploy_status=failed reason=timeout_after_${TIMEOUT_MINUTES:-5}min"
exit 1
```

---

## Notes

- **Zero token burn during polling.** Claude only runs before and after the bash script. The bash script does all the waiting.
- **SHA comparison is optional.** If `EXPECTED_SHA` is empty, the checker confirms health endpoint returns 200.
- **Timeout is team-configurable.** 5 min for Pylot (auto-pull), 30 min for Lexgo (GitHub Actions + Fly.io).
- **`deployed` label chains into `/post-deploy`** via event-rules — no manual handoff needed.
- **Monorepo targets:** dispatch one deployment-checker job per target if needed.
