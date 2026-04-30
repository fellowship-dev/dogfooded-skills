---
name: post-merge
description: Post-merge deployment trigger — reads PR diff, determines deploy method (auto vs manual), dispatches deployment-checker job. Stage 1 of the post-merge → deployment-checker → post-deploy pipeline.
argument-hint: "pr-number org/repo"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# post-merge

Stage 1 of the autonomous deployment pipeline. Runs after a PR merges: reads the diff, determines whether the deploy is automatic or manual, optionally performs the manual deploy, then dispatches a `deployment-checker` job to poll until live.

## When to Use

- Triggered automatically by event-rules when a PR merges to the default branch
- Manual: `/post-merge PR_NUMBER org/repo`

## Invocation

```
/post-merge 42 fellowship-dev/pylot
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

# Check if deployment-checker job already dispatched for this PR
EXISTING=$(ls ${PYLOT_DISPATCH_DIR:-$HOME/.local/share/pylot/missions}/pending/ \
  ${PYLOT_DISPATCH_DIR:-$HOME/.local/share/pylot/missions}/running/ 2>/dev/null \
  | grep "deploy-check-${PR}-" || true)
if [ -n "$EXISTING" ]; then
  echo "[post-merge] outcome=\"already dispatched — deploy-checker job exists\" status=success"
  exit 0
fi
```

### Step 1: Gather PR Context

```bash
# Fetch PR metadata
PR_DATA=$(gh pr view $PR --repo $REPO --json number,title,mergedAt,baseRefName,headRefName,files,url,mergeCommit)
PR_TITLE=$(echo "$PR_DATA" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['title'])")
PR_SHA=$(echo "$PR_DATA" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergeCommit',{}).get('oid','') or '')" 2>/dev/null || true)
CHANGED_FILES=$(echo "$PR_DATA" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(f['path'] for f in d['files']))")
BASE_BRANCH=$(echo "$PR_DATA" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['baseRefName'])")

echo "PR: $PR — $PR_TITLE"
echo "SHA: $PR_SHA"
echo "Base: $BASE_BRANCH"
echo "Files changed:"
echo "$CHANGED_FILES"
```

### Step 2: Read Team Deploy Configuration

Read the team's CLAUDE.md to determine the deploy method configured for this repo. Look for a `deploy:` section:

```yaml
# Example in crew/infra/CLAUDE.md or team CLAUDE.md:
deploy:
  method: auto-pull          # auto-pull | github-actions | manual
  health_url: "http://localhost:1337/_health"
  timeout_minutes: 5
  checker_script: "scripts/deployment-checker-pylot.sh"
  expected_sha_field: "sha"  # JSON field in health response containing deployed sha
```

**Deploy method decision tree:**

| Method | Action |
|--------|--------|
| `auto-pull` | Deploy is automatic. Skip Step 3 and Step 4 (auto-deploy.sh handles deploy-check). |
| `github-actions` | Deploy triggered by merge. Wait ~2 min, then Step 4. |
| `manual` | CTO runs deploy command now (Step 3), then Step 4. |

If no deploy config found, emit a warning and exit — do not guess.

### Step 3: Manual Deploy (if method = manual)

Only execute when `method: manual`. Read the deploy command from team config:

```bash
# Example: manual deploy for a Fly.io app
cd /path/to/repo && fly deploy --remote-only

# Example: manual ECR push
aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_URI
docker build -t $IMAGE . && docker push $IMAGE
```

Document the command executed and its output.

### Step 4: Dispatch deployment-checker Job

**Skip this step if `method: auto-pull`.** Auto-pull repos have their deploy-check dispatched by `auto-deploy.sh` after the executor restarts — dispatching here would create a chicken-and-egg deadlock (deploy-checker blocks the queue, which blocks the deploy it's waiting for).

For other deploy methods (`github-actions`, `manual`), dispatch a new job:

```bash
if [ "$DEPLOY_METHOD" != "auto-pull" ]; then
  PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"
  curl -sS -X POST \
    -H "Authorization: Bearer $(grep '^PYLOT_DISPATCH_TOKEN=' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'agent':'${TEAM}.intern','task':'Check deployment for $REPO#$PR — $PR_TITLE','repo':'$REPO','context':'SHA: $PR_SHA. Health URL: $HEALTH_URL. Timeout: ${TIMEOUT_MINUTES:-5} minutes. Checker script: ${CHECKER_SCRIPT}. Run /deployment-checker $PR $REPO.'}))")" \
    "http://127.0.0.1:3000/dispatch"
else
  echo "[post-merge] Skipping deploy-check dispatch — auto-pull deploys are checked by auto-deploy.sh"
fi
```

### Step 5: Post Comment on PR

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'EOF'
**Post-merge pipeline started** 🚀

| Field | Value |
|-------|-------|
| Deploy method | \`$DEPLOY_METHOD\` |
| Health endpoint | \`$HEALTH_URL\` |
| Timeout | ${TIMEOUT_MINUTES:-5} min |
| Expected SHA | \`${PR_SHA:-unknown}\` |

Deployment checker dispatched. Will apply \`deployed\` or \`deploy-failed\` label when complete.
EOF
)"
```

### Step 6: Write Report

```bash
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"
REPORT="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-post-merge-$(echo $REPO | tr '/' '-')-pr${PR}.md"
cat > "$REPORT" <<EOF
# Post-Merge: $REPO PR #$PR — $PR_TITLE

**Date**: $(date +%Y-%m-%d)
**PR**: [$REPO#$PR]($PR_URL)
**SHA**: $PR_SHA
**Deploy method**: $DEPLOY_METHOD
**Deploy-checker job**: dispatched

## Changed Files
$CHANGED_FILES

## Outcome
Deploy-checker dispatched. Awaiting health confirmation.
EOF
```

---

## Team Configuration Reference

Each team's CLAUDE.md should contain a `deploy:` section. Generic examples:

### Pylot (auto-pull)
```yaml
deploy:
  method: auto-pull
  health_url: "http://localhost:1337/_health"
  timeout_minutes: 5
  checker_script: "scripts/deployment-checker-pylot.sh"
  expected_sha_field: "sha"
```

### Lexgo (GitHub Actions → Fly.io)
```yaml
deploy:
  method: github-actions
  health_url: "https://api.lexgo.cl/_health"
  timeout_minutes: 30
  checker_script: "scripts/deployment-checker-lexgo.sh"
```

### Booster-pack (branch-push → Fly + Vercel)
```yaml
deploy:
  method: auto-pull
  health_url: "https://api.booster-pack.dev/health"
  timeout_minutes: 10
```

---

## Notes

- **No team config = no action.** Don't guess deploy methods — missing config is a signal to configure.
- **SHA comparison is best-effort.** If health endpoint doesn't expose a sha field, fall back to timestamp comparison.
- **Post-merge fires per-PR.** Each merged PR gets its own deploy-checker job.
- **Monorepo:** if the repo has multiple deploy targets (e.g., backend + frontend), dispatch one checker per target. The checker_script determines which target to poll.
