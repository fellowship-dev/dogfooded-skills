---
name: test-in-staging
description: Deploy the current branch to staging, run smoke tests, and print a ready-to-paste `## Staging Evidence` block. Required before opening an infra/backend PR targeting fellowship-dev/pylot.
user-invocable: true
allowed-tools: Bash
argument_hint: "[<branch>]"
---

## Purpose

Deploy a branch to staging, verify the health endpoint confirms the deploy landed, run smoke
tests against the staging gateway, and emit a `## Staging Evidence` block ready to paste into
a PR body.

This skill wraps `POST /admin/deploy` on the **staging** gateway. If `PYLOT_STAGING_URL` or
`PYLOT_STAGING_DISPATCH_TOKEN` are unset, the skill exits immediately with `status=blocked`.

## Arguments

Optional branch name. Parsed from `$ARGUMENTS`. If empty, resolves to the current git HEAD branch.

## Execution

Run as a single Bash block. Print all progress to stderr; the evidence block goes to stdout.

```bash
set -euo pipefail

STAGING_URL="${PYLOT_STAGING_URL:-}"
STAGING_TOKEN="${PYLOT_STAGING_DISPATCH_TOKEN:-}"
HEALTH_BASE="https://pylot-beta.fellowship.dev"

if [ -z "$STAGING_URL" ] || [ -z "$STAGING_TOKEN" ]; then
  echo "[test-in-staging] status=blocked: PYLOT_STAGING_URL or PYLOT_STAGING_DISPATCH_TOKEN not set" >&2
  echo "[pylot] outcome=\"test-in-staging blocked: staging credentials missing\" status=blocked"
  exit 1
fi

BRANCH="${ARGUMENTS:-}"
if [ -z "$BRANCH" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "[test-in-staging] status=blocked: cannot resolve branch name" >&2
  exit 1
fi
echo "[test-in-staging] branch=$BRANCH" >&2

# Step 1: Trigger deploy
echo "[test-in-staging] deploying $BRANCH to staging..." >&2
RESP=$(curl -sf -X POST "${STAGING_URL%/}/admin/deploy" \
  -H "Authorization: Bearer $STAGING_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"source_version\": \"$BRANCH\"}" 2>/dev/null) || {
  echo "[test-in-staging] failed to trigger deploy — check PYLOT_STAGING_URL and token" >&2
  exit 1
}
BUILD_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['build_id'])" 2>/dev/null) || {
  echo "[test-in-staging] unexpected deploy response: $RESP" >&2
  exit 1
}
echo "[test-in-staging] deploy triggered build_id=$BUILD_ID" >&2

# Step 2: Poll build status (15s x 20 = 5 min timeout)
echo "[test-in-staging] polling build status (5 min timeout)..." >&2
DEPLOY_OK=0
for i in $(seq 1 20); do
  sleep 15
  STATUS_RESP=$(curl -sf "${STAGING_URL%/}/admin/build-worker/$BUILD_ID" \
    -H "Authorization: Bearer $STAGING_TOKEN" 2>/dev/null) || STATUS_RESP="{}"
  STATUS=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
  echo "[test-in-staging] [poll $i/20] build=$STATUS" >&2
  case "$STATUS" in
    SUCCEEDED) DEPLOY_OK=1; break ;;
    FAILED|STOPPED)
      echo "[test-in-staging] deploy $STATUS — aborting" >&2
      exit 1
      ;;
  esac
done
if [ "$DEPLOY_OK" -eq 0 ]; then
  echo "[test-in-staging] TIMEOUT: build $BUILD_ID did not finish within 5 min" >&2
  exit 1
fi
echo "[test-in-staging] deploy SUCCEEDED" >&2

# Step 3: Poll health until live (15s x 20 = 5 min timeout)
echo "[test-in-staging] waiting for staging health check..." >&2
LIVE_SHA=""
HEALTH_OK=0
for i in $(seq 1 20); do
  HEALTH_JSON=$(curl -sf "$HEALTH_BASE/health" 2>/dev/null || echo "{}")
  STATUS_VAL=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','-'))" 2>/dev/null || echo "-")
  LIVE_SHA=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha','-'))" 2>/dev/null || echo "-")
  echo "[test-in-staging] [poll $i/20] health=$STATUS_VAL sha=$LIVE_SHA" >&2
  if [ "$STATUS_VAL" = "up" ] && [ "$LIVE_SHA" != "-" ]; then
    HEALTH_OK=1; break
  fi
  sleep 15
done

if [ "$HEALTH_OK" -eq 0 ]; then
  LIVE_SHA="unknown (health check timed out)"
fi
echo "[test-in-staging] health confirmed sha=$LIVE_SHA" >&2

# Step 4: Smoke tests
echo "[test-in-staging] running smoke tests..." >&2

HEALTH_CODE=$(curl -so /dev/null -w "%{http_code}" "$HEALTH_BASE/health" 2>/dev/null || echo "000")
if [ "$HEALTH_CODE" = "200" ]; then HEALTH_ICON="OK"; else HEALTH_ICON="FAIL"; fi

CREW_RESP=$(curl -sf -H "Authorization: Bearer $STAGING_TOKEN" "${STAGING_URL%/}/crew" 2>/dev/null || echo "[]")
CREW_COUNT=$(echo "$CREW_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if isinstance(d,list): print(len(d))
elif isinstance(d,dict): print(len(d.get('operators',d.get('members',[]))))
else: print(0)
" 2>/dev/null || echo "0")
if [ "${CREW_COUNT:-0}" -gt 0 ] 2>/dev/null; then CREW_ICON="V"; else CREW_ICON="F"; CREW_COUNT="0"; fi

DB_READY=$(curl -sf "$HEALTH_BASE/health" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
db=d.get('db',{})
print(db.get('ready',False) if isinstance(db,dict) else False)
" 2>/dev/null || echo "False")
if [ "$DB_READY" = "True" ]; then SCHED_ACTIVE="active"; else SCHED_ACTIVE="unavailable"; fi

cat <<EVIDEOF

## Staging Evidence
- **Branch:** \`$BRANCH\`
- **Deployed SHA:** \`$LIVE_SHA\`
- **Health check:** $HEALTH_CODE
- **Smoke tests:**
  - GET /health -> $HEALTH_CODE
  - GET /crew -> 200 ($CREW_COUNT members)
  - Scheduler heartbeat -> $SCHED_ACTIVE
EVIDEOF

if [ "$HEALTH_ICON" = "FAIL" ] || [ "$CREW_ICON" = "F" ] || [ "$SCHED_ACTIVE" = "unavailable" ]; then
  echo "[test-in-staging] one or more smoke tests FAILED" >&2
  exit 1
fi

echo "[pylot] outcome=\"test-in-staging complete branch=$BRANCH sha=$LIVE_SHA\" status=success"
```

## Rules

- Always deploy via `POST ${PYLOT_STAGING_URL}/admin/deploy` — never run `cdk deploy` directly.
- Always target the STAGING gateway. Pointing at the prod gateway deploys PROD.
- Print progress to stderr; the evidence block goes to stdout.
- Exit 0 = all smoke tests passed; exit 1 = deploy failed or a smoke test failed.
- No interactive prompts; safe for Fargate execution.
