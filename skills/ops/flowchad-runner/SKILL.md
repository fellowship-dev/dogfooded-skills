---
name: flowchad-runner
description: FlowChad flow automation — walks named flows using Playwright, captures screenshots/video evidence, posts results to GitHub, writes report + JSONL transcript. Auto-switches to Navvi for CAPTCHAs.
user-invocable: true
argument-hint: "[flow-name|all] [org/repo] (pr-number)"
allowed-tools: Read, Write, Bash, Glob, Grep, Agent
---

Run FlowChad flow automation: `$ARGUMENTS`

Parse arguments:
- FLOW_NAME — flow name or "all" (required)
- REPO — org/repo (required)
- PR_NUMBER — optional, post results to this PR

## Phase 0: Deployment-Aware Preflight

Sets up TARGET_URL, NAVVI_PERSONA, NAVVI_AVAILABLE, and FLOWS_TO_RUN for later phases. Logic is trigger-driven.

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

### 0a. Environment Resolution (trigger-driven)

**PR trigger** — resolve Vercel preview URL from PR deployments API:
```bash
# Get Vercel preview URL for this PR
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
# Read URL from config.yml environments block
TARGET_URL=$(yq '.environments.staging.url // .environments.production.url // ""' .flowchad/config.yml 2>/dev/null)
DEPLOY_CHECK="merge"   # triggers deploy-wait in 0b
```

**Cron trigger** — use production URL from config.yml:
```bash
TARGET_URL=$(yq '.environments.production.url // .url // ""' .flowchad/config.yml 2>/dev/null)
```

**Manual/unknown trigger** — use URL from config.yml or fall back:
```bash
TARGET_URL=$(yq '.url // ""' .flowchad/config.yml 2>/dev/null)
```

If TARGET_URL is still empty after resolution, log error and exit — cannot proceed without a URL.

### 0b. Deploy-Wait (merge trigger or deploy in progress)

Skip this step unless TRIGGER=merge or a deploy was detected as in-progress.

```bash
# Read timeout from config.yml (default 300s, Lexgo-style 900s, Vercel 120s)
DEPLOY_TIMEOUT=$(yq '.environments.staging.deploy_timeout // .environments.production.deploy_timeout // 300' .flowchad/config.yml 2>/dev/null || echo 300)
POLL_INTERVAL=15
ELAPSED=0

# Get latest deployment
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
      exit 1
      ;;
    *)
      gh issue create --repo "$REPO" \
        --title "Deploy status unknown: ${REPO} — flowchad blocked" \
        --label "ready-to-work" \
        --body "FlowChad runner was blocked because deploy status is unknown (state: ${STATE}).\n\nDeploy ID: ${DEPLOY_ID}\nRepo: ${REPO}\nDate: ${REPORT_DATE}\nElapsed: ${ELAPSED}s / timeout: ${DEPLOY_TIMEOUT}s"
      echo "Deploy status unknown after ${ELAPSED}s — created GitHub issue, exiting"
      exit 1
      ;;
  esac
done

# If loop exited by timeout (ELAPSED >= DEPLOY_TIMEOUT) without breaking on success
if [ $ELAPSED -ge $DEPLOY_TIMEOUT ]; then
  gh issue create --repo "$REPO" \
    --title "Deploy status unknown: ${REPO} — flowchad blocked" \
    --label "ready-to-work" \
    --body "FlowChad runner timed out waiting for deploy (${DEPLOY_TIMEOUT}s).\n\nDeploy ID: ${DEPLOY_ID}\nRepo: ${REPO}\nDate: ${REPORT_DATE}"
  echo "Deploy timed out after ${DEPLOY_TIMEOUT}s — created GitHub issue, exiting"
  exit 1
fi
```

### 0c. Navvi Availability & Persona Check

Check if Navvi is available in this environment. Navvi can run locally (Docker), remotely (Codespaces/Ona), or not at all.

```bash
NAVVI_AVAILABLE="false"
NAVVI_PERSONA=""

# 1. Check if navvi MCP tools are available (navvi_status)
#    If the MCP server is loaded, navvi_status returns mode: local|remote|off
navvi_status_result=$(navvi_status 2>/dev/null) || true

if [ -n "$navvi_status_result" ]; then
  # Navvi MCP is loaded — check if it's running or can be started
  NAVVI_MODE=$(echo "$navvi_status_result" | grep -i "mode:" | awk '{print $2}')

  if [ "$NAVVI_MODE" = "off" ] || [ -z "$NAVVI_MODE" ]; then
    # Try to start Navvi — it auto-detects environment:
    #   - Docker present → local mode
    #   - CODESPACE_NAME set → Codespaces remote mode
    #   - gh cs available → Ona remote mode
    navvi_start 2>/dev/null && NAVVI_AVAILABLE="true" || true
  else
    NAVVI_AVAILABLE="true"
  fi
fi

# 2. Resolve persona
PERSONA=$(yq '.persona // ""' .flowchad/config.yml 2>/dev/null)

if [ -n "$PERSONA" ] && [ "$NAVVI_AVAILABLE" = "true" ]; then
  # Check gopass for credentials
  PERSONA_EMAIL=$(gopass show navvi/${PERSONA}/email 2>/dev/null || true)
  if [ -n "$PERSONA_EMAIL" ]; then
    echo "Persona found: ${PERSONA} (${PERSONA_EMAIL}) — authenticated flows enabled"
    NAVVI_PERSONA="$PERSONA"
  else
    echo "WARNING: persona '${PERSONA}' not found in gopass — using default persona"
    NAVVI_PERSONA="default"
  fi
elif [ "$NAVVI_AVAILABLE" = "true" ]; then
  # No persona configured but Navvi is available — use default for CAPTCHA solving
  echo "No persona configured — Navvi available with default persona for CAPTCHAs"
  NAVVI_PERSONA="default"
fi

echo "NAVVI_AVAILABLE: $NAVVI_AVAILABLE"
echo "NAVVI_PERSONA: ${NAVVI_PERSONA:-<none>}"
```

### 0d. Smoketest Config Resolution

```bash
# Read flows to run from config.yml
ALL_FLOWS=$(yq '.smoke.flows[]' .flowchad/config.yml 2>/dev/null)
SKIP_PRODUCTION=$(yq '.smoke.skip_production[]' .flowchad/config.yml 2>/dev/null)

# If FLOW_NAME=all, use smoke.flows; otherwise use the single flow
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

### 0e. Export env vars for downstream phases

```bash
export TARGET_URL="$TARGET_URL"
export NAVVI_AVAILABLE="$NAVVI_AVAILABLE"
export NAVVI_PERSONA="$NAVVI_PERSONA"
export FLOWS_TO_RUN="$FLOWS_TO_RUN"

echo "=== Phase 0 complete ==="
echo "TARGET_URL: $TARGET_URL"
echo "NAVVI_AVAILABLE: $NAVVI_AVAILABLE"
echo "NAVVI_PERSONA: ${NAVVI_PERSONA:-<none>}"
echo "FLOWS_TO_RUN: $FLOWS_TO_RUN"
```

## Phase 1: Load Flow Config

```bash
# In the Ona pod / Codespaces:
# Read FlowChad config
cat .flowchad/config.yml

# List available flows
ls .flowchad/flows/

# Load the specific flow (or all flows if FLOW_NAME=all)
cat .flowchad/flows/${FLOW_NAME}.yml
```

If the flow file does not exist:
1. Post a comment to the PR (if PR_NUMBER set): "flowchad-runner: flow `${FLOW_NAME}` not found in .flowchad/flows/"
2. Create a GitHub issue with label `ready-to-work`: "Missing FlowChad flow: ${FLOW_NAME}"
3. Write a failure report and exit

## Phase 2: Execute Flow Walk

**FlowChad is a set of skills, not a CLI.** The flow walk is driven by reading the flow YAML and executing each step.

Follow the **flow-walk** skill pattern. For each flow:

### 2a. Choose browser & connect

**Decision logic — per flow:**

1. Scan the flow YAML for `captcha: true` on any step, or `headed: true` on the flow
2. If captcha/headed found AND `NAVVI_AVAILABLE=true` → use Navvi
3. Otherwise → use headless Playwright (fast path)

**Headless Playwright (default):**
```javascript
import { chromium } from 'playwright-core';

let browser;
try {
  browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
} catch {
  browser = await chromium.launch({ headless: true });
}

const snapshotDir = `.flowchad/snapshots/${date}-${flowName}`;
const context = await browser.newContext({
  recordVideo: { dir: snapshotDir, size: { width: 1280, height: 720 } }
});
const page = await context.newPage();
```

**Navvi (for CAPTCHAs, bot detection, or authenticated flows):**
```
# Use Navvi MCP tools — connects to Camoufox headed browser
# Navvi handles fingerprinting, anti-detection, and CAPTCHA solving

# If persona is set (not "default"), load it
navvi_persona(name=NAVVI_PERSONA)   # if NAVVI_PERSONA != "default"

# Open the target URL
navvi_open(url=TARGET_URL)

# Use navvi_click, navvi_fill, navvi_scroll, navvi_screenshot for steps
# Use navvi_record_start / navvi_record_stop for video evidence
```

When using Navvi, map flow YAML actions to Navvi MCP tools:
- `navigate` → `navvi_open(url)`
- `click` → `navvi_click(selector)`
- `fill` → `navvi_fill(selector, value)`
- `scroll` → `navvi_scroll(direction)` or `navvi_scroll(selector)`
- `wait` → `navvi_find(selector)` with timeout
- `hover` → `navvi_mousemove(selector)`
- screenshot → `navvi_screenshot()`

### 2b. Execute each step from the flow YAML

For each step in the flow definition:

1. **Perform the action** — using Playwright or Navvi tools depending on the browser chosen in 2a

2. **Measure timing** — record before/after timestamps

3. **Take screenshot** — Playwright `page.screenshot()` or `navvi_screenshot()`

4. **Evaluate expect** — read the `expect` string from YAML (natural language), look at the screenshot and page state, determine if expectation is met

5. **Check timing threshold** — if `timing` is specified and actual > threshold, flag as `slow`

### 2c. Handle errors & auto-switch to Navvi

**A broken step is a finding, not a failure.** If a step throws:
- Catch the error, take a screenshot of current state
- Log error, record status as `error`
- **Continue to next step** — collect full evidence before stopping

If step has `optional: true` and fails, record but don't flag as critical.

**CAPTCHA auto-detection and Navvi escalation:**

If a step fails and the error or screenshot indicates a CAPTCHA challenge (Cloudflare Turnstile, reCAPTCHA, Arkose, or similar bot detection):

1. If `NAVVI_AVAILABLE=true` and currently using headless Playwright:
   - Log: "CAPTCHA detected at step N — switching to Navvi"
   - Close the headless browser
   - Start Navvi: `navvi_start()` if not already running
   - Load persona: `navvi_persona(name=NAVVI_PERSONA)` (or default)
   - Navigate to the current page URL via `navvi_open(url)`
   - **Retry the failed step** using Navvi tools
   - **Continue remaining steps** with Navvi (don't switch back mid-flow)
2. If `NAVVI_AVAILABLE=false`:
   - Record status as `skipped` with note "CAPTCHA detected — Navvi not available"
   - Continue to next step

CAPTCHA detection patterns (check error message AND screenshot):
- Cloudflare Turnstile: `cf-turnstile`, "Verify you are human", "Please complete the verification"
- reCAPTCHA: `g-recaptcha`, "I'm not a robot"
- Arkose: `arkoselabs`, "Verify your identity"
- Generic: any visible challenge iframe or "bot detection" text

### 2d. Stop recording, smart trim, GIF conversion

Close page to finalize video. Use ffmpeg for smart trim (cut dead frames using action log) and palette-optimized GIF conversion. See flow-walk skill for the full ffmpeg pipeline.

If using Navvi: `navvi_record_stop()` to finalize, then process the output file.

**Output files per flow:**
- `step-{N}-{action}.png` — per-step screenshots
- `{flow-name}-full.webm` — raw recording
- `{flow-name}-trimmed.mp4` — action-only cut (if trim saves >20%)
- `{flow-name}.gif` — palette-optimized GIF
- `results.json` — structured results (steps, timing, pass/fail, evidence URLs)

### 2e. Log to JSONL transcript

Log every operation to the transcript file:
```json
{"ts":"ISO8601","elapsed_ms":N,"phase":"walk","flow":"flow-name","step":"step-name","status":"pass|fail|skip","browser":"playwright|navvi","screenshot":null,"error":null}
```

## Phase 3: Upload Evidence

Follow the **evidence-upload** skill pattern. Read evidence backend from `.flowchad/config.yml` (default: `git` orphan branch).

```bash
# Git backend (default): push screenshots + GIF to evidence branch
# Use GitHub Contents API — no local git operations needed
for screenshot in ${SNAPSHOT_DIR}/step-*.png; do
  # Upload via gh api or git push to evidence branch
done
```

Note evidence URLs for embedding in the report and GitHub comments.

If evidence upload fails, log warning and continue — evidence is best-effort, never blocks the walk.

## Phase 4: Post Results to GitHub

If PR_NUMBER is set, post a comment with results table and embedded GIF:
```bash
gh pr comment $PR_NUMBER --repo $REPO --body "## FlowChad Results: ${FLOW_NAME}
**Status**: PASSED / FAILED
**Date**: ${REPORT_DATE}
**Browser**: Playwright headless / Navvi (auto-switched)

### Step Results
| Step | Status | Timing | Browser | Notes |
|------|--------|--------|---------|-------|
| step-1 | pass | 1.2s | playwright | |
| step-2 | pass | 3.1s | navvi | CAPTCHA auto-switch |

[GIF embedded if available]

_Run by flowchad-runner_"
```

On FAILURE — create a GitHub issue in the repo:
```bash
gh issue create --repo $REPO \
  --title "FlowChad failure: ${FLOW_NAME} — ${REPORT_DATE}" \
  --label "ready-to-work" \
  --body "Flow ${FLOW_NAME} failed during automated walk on ${REPORT_DATE}.

**Failed steps:**
{list of failed steps with error messages}

**Evidence:**
{GIF and screenshot links}

This issue was auto-created by flowchad-runner. Fix the flow or the code, then re-run to verify."
```

This is the **closed-loop trigger** — the `ready-to-work` label + issue body gives speckit enough context to investigate and fix.

## Phase 5: Write Report

Write mission report to `reports/${REPORT_DATE}-flowchad-${FLOW_SLUG}.md`:

```markdown
# FlowChad Run: ${FLOW_NAME} in ${REPO}
**Status**: PASSED / FAILED
**Date**: ${REPORT_DATE}
**Browser**: Playwright / Navvi (auto-switched at step N)
**Transcript**: ${TRANSCRIPT}

## Steps
| Step | Status | Timing | Browser | Screenshot |
|------|--------|--------|---------|-----------|
| ... | pass/fail | Ns | playwright/navvi | [link] |

## Failures
[details if any]

## Evidence
Snapshot dir: .flowchad/snapshots/${REPORT_DATE}-${FLOW_SLUG}/
GIF: [link if uploaded]
```
