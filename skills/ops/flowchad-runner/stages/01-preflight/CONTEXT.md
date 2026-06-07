# Stage 01: Deployment-Aware Preflight (subagent)

## Inputs
- None (this is the first stage). The orchestrator passes the parsed `$ARGUMENTS`
  positionally in the Task prompt: `flow-name`, `repo`, `pr-number`, `trigger`.

## Task
Parse arguments, resolve `TARGET_URL` (trigger-driven), wait for any in-progress deploy,
check Navvi availability + persona, and build the `FLOWS_TO_RUN` list. Write all resolved
run context to the handoff so downstream stages need no re-resolution.

## Steps

### 1. Setup
```bash
export GH_TOKEN=$(grep 'GH_TOKEN_FELLOWSHIP' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)

# Parse arguments
FLOW_NAME="$1"
REPO="$2"
PR_NUMBER="${3:-}"
TRIGGER="${4:-manual}"   # pr | merge | cron | manual
REPORT_DATE=$(date +%Y-%m-%d)
FLOW_SLUG=$(echo "$FLOW_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
TRANSCRIPT="reports/${REPORT_DATE}-flowchad-${FLOW_SLUG}.jsonl"
REPORT="reports/${REPORT_DATE}-flowchad-${FLOW_SLUG}.md"
mkdir -p reports
```

### 2. Environment Resolution (trigger-driven)

**PR trigger** — resolve Vercel preview URL from PR deployments API:
```bash
PREVIEW_URL=$(gh api repos/${REPO}/deployments \
  --jq "[.[] | select(.environment | test(\"Preview\"; \"i\"))] | .[0].payload.web_url // empty" 2>/dev/null)

# Fallback: check deployment statuses for a success URL
if [ -z "$PREVIEW_URL" ]; then
  DEPLOY_ID=$(gh api repos/${REPO}/deployments --jq '.[0].id' 2>/dev/null)
  PREVIEW_URL=$(gh api repos/${REPO}/deployments/${DEPLOY_ID}/statuses \
    --jq '.[0].environment_url // empty' 2>/dev/null)
fi

TARGET_URL="$PREVIEW_URL"
```

**Merge to branch trigger** — resolve staging/production URL and wait for deploy:
```bash
TARGET_URL=$(yq '.environments.staging.url // .environments.production.url // ""' .flowchad/config.yml 2>/dev/null)
DEPLOY_CHECK="merge"   # triggers deploy-wait in step 3
```

**Cron trigger** — use production URL from config.yml:
```bash
TARGET_URL=$(yq '.environments.production.url // .url // ""' .flowchad/config.yml 2>/dev/null)
```

**Manual/unknown trigger** — use URL from config.yml or fall back:
```bash
TARGET_URL=$(yq '.url // ""' .flowchad/config.yml 2>/dev/null)
```

If TARGET_URL is still empty after resolution, write handoff with `blocked: true`,
`block_reason: no target URL`, and exit — cannot proceed without a URL.

### 3. Deploy-Wait (merge trigger or deploy in progress)

Skip this step unless TRIGGER=merge or a deploy was detected as in-progress.
```bash
DEPLOY_TIMEOUT=$(yq '.environments.staging.deploy_timeout // .environments.production.deploy_timeout // 300' .flowchad/config.yml 2>/dev/null || echo 300)
POLL_INTERVAL=15
ELAPSED=0

DEPLOY_ID=$(gh api repos/${REPO}/deployments --jq '.[0].id')

while [ $ELAPSED -lt $DEPLOY_TIMEOUT ]; do
  STATE=$(gh api repos/${REPO}/deployments/${DEPLOY_ID}/statuses --jq '.[0].state // "unknown"')

  case "$STATE" in
    success)
      echo "Deploy succeeded — proceeding"
      break
      ;;
    pending|queued|in_progress)
      echo "Deploy ${STATE} — waiting ${POLL_INTERVAL}s (${ELAPSED}/${DEPLOY_TIMEOUT})"
      sleep $POLL_INTERVAL
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
      ;;
    failure|error)
      gh issue create --repo "$REPO" \
        --title "Deploy failed: ${REPO} — flowchad blocked" \
        --label "ready-to-work" \
        --body "FlowChad runner was blocked because the latest deploy failed (state: ${STATE}).\n\nDeploy ID: ${DEPLOY_ID}\nRepo: ${REPO}\nDate: ${REPORT_DATE}"
      echo "Deploy failed — created GitHub issue, exiting"
      # write handoff blocked: true, block_reason: deploy ${STATE}, then exit
      exit 1
      ;;
    *)
      gh issue create --repo "$REPO" \
        --title "Deploy status unknown: ${REPO} — flowchad blocked" \
        --label "ready-to-work" \
        --body "FlowChad runner was blocked because deploy status is unknown (state: ${STATE}).\n\nDeploy ID: ${DEPLOY_ID}\nRepo: ${REPO}\nDate: ${REPORT_DATE}\nElapsed: ${ELAPSED}s / timeout: ${DEPLOY_TIMEOUT}s"
      echo "Deploy status unknown after ${ELAPSED}s — created GitHub issue, exiting"
      # write handoff blocked: true, block_reason: deploy status unknown, then exit
      exit 1
      ;;
  esac
done

# If loop exited by timeout without breaking on success
if [ $ELAPSED -ge $DEPLOY_TIMEOUT ]; then
  gh issue create --repo "$REPO" \
    --title "Deploy status unknown: ${REPO} — flowchad blocked" \
    --label "ready-to-work" \
    --body "FlowChad runner timed out waiting for deploy (${DEPLOY_TIMEOUT}s).\n\nDeploy ID: ${DEPLOY_ID}\nRepo: ${REPO}\nDate: ${REPORT_DATE}"
  echo "Deploy timed out after ${DEPLOY_TIMEOUT}s — created GitHub issue, exiting"
  # write handoff blocked: true, block_reason: deploy timeout, then exit
  exit 1
fi
```

### 4. Navvi Availability & Persona Check

Navvi can run locally (Docker), remotely (Codespaces/Ona), or not at all.
```bash
NAVVI_AVAILABLE="false"
NAVVI_PERSONA=""

# 1. Check if navvi MCP tools are available (navvi_status)
navvi_status_result=$(navvi_status 2>/dev/null) || true

if [ -n "$navvi_status_result" ]; then
  NAVVI_MODE=$(echo "$navvi_status_result" | grep -i "mode:" | awk '{print $2}')

  if [ "$NAVVI_MODE" = "off" ] || [ -z "$NAVVI_MODE" ]; then
    # Try to start Navvi — auto-detects: Docker→local, CODESPACE_NAME→Codespaces, gh cs→Ona
    navvi_start 2>/dev/null && NAVVI_AVAILABLE="true" || true
  else
    NAVVI_AVAILABLE="true"
  fi
fi

# 2. Resolve persona
PERSONA=$(yq '.persona // ""' .flowchad/config.yml 2>/dev/null)

if [ -n "$PERSONA" ] && [ "$NAVVI_AVAILABLE" = "true" ]; then
  PERSONA_EMAIL=$(gopass show navvi/${PERSONA}/email 2>/dev/null || true)
  if [ -n "$PERSONA_EMAIL" ]; then
    echo "Persona found: ${PERSONA} (${PERSONA_EMAIL}) — authenticated flows enabled"
    NAVVI_PERSONA="$PERSONA"
  else
    echo "WARNING: persona '${PERSONA}' not found in gopass — using default persona"
    NAVVI_PERSONA="default"
  fi
elif [ "$NAVVI_AVAILABLE" = "true" ]; then
  echo "No persona configured — Navvi available with default persona for CAPTCHAs"
  NAVVI_PERSONA="default"
fi

echo "NAVVI_AVAILABLE: $NAVVI_AVAILABLE"
echo "NAVVI_PERSONA: ${NAVVI_PERSONA:-<none>}"
```

### 5. Smoketest Config Resolution (build FLOWS_TO_RUN)
```bash
ALL_FLOWS=$(yq '.smoke.flows[]' .flowchad/config.yml 2>/dev/null)
SKIP_PRODUCTION=$(yq '.smoke.skip_production[]' .flowchad/config.yml 2>/dev/null)

if [ "$FLOW_NAME" = "all" ]; then
  FLOWS_TO_RUN="$ALL_FLOWS"
else
  FLOWS_TO_RUN="$FLOW_NAME"
fi

# On cron/production trigger, skip production-excluded flows (unless persona available)
if [ "$TRIGGER" = "cron" ] && [ -z "$NAVVI_PERSONA" ] && [ -n "$SKIP_PRODUCTION" ]; then
  FILTERED=""
  for flow in $FLOWS_TO_RUN; do
    if echo "$SKIP_PRODUCTION" | grep -qx "$flow"; then
      echo "Skipping '${flow}' — in skip_production and no persona available"
    else
      FILTERED="$FILTERED $flow"
    fi
  done
  FLOWS_TO_RUN=$(echo $FILTERED | xargs)
fi

# Fallback: if no flows resolved, use FLOW_NAME arg
if [ -z "$FLOWS_TO_RUN" ]; then
  FLOWS_TO_RUN="$FLOW_NAME"
fi
```

### 6. Write handoff with all resolved context.

## Output: handoff.md

Path: `.procedure-output/flowchad-runner/01-preflight/handoff.md`

```markdown
# Stage 01: Preflight

## Status
blocked: {true|false}
block_reason: {reason or "none"}

## Run context
flow_name: {FLOW_NAME}
repo: {REPO}
pr_number: {PR_NUMBER or "none"}
trigger: {TRIGGER}
report_date: {REPORT_DATE}
flow_slug: {FLOW_SLUG}
transcript_path: {TRANSCRIPT}
report_path: {REPORT}

## Resolved environment
target_url: {TARGET_URL}
navvi_available: {true|false}
navvi_persona: {persona name or "<none>"}
flows_to_run: {space- or newline-separated flow names}

## Deploy-wait
result: {skipped | success | n/a}
```

## Success criteria
- TARGET_URL resolved (non-empty) OR handoff marked `blocked: true` with reason.
- If TRIGGER=merge, deploy-wait completed (success) or blocked with an issue created.
- `flows_to_run` is non-empty.

## Failure
- Empty TARGET_URL → `blocked: true`, `block_reason: no target URL`, exit.
- Deploy failed/unknown/timeout → GitHub issue created, `blocked: true`, exit.
