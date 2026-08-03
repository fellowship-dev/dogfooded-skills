# Stage 01: Environment-Aware Preflight (subagent)

## Inputs

- Parsed `$ARGUMENTS`: `flow-name`, `repo`, `pr-number`, `trigger`
- `{WORKDIR}` — absolute path to the resolved repo checkout (from the orchestrator's
  Workspace resolution). `cd` there first; `.flowchad/config.yml` and `.flowchad/flows/`
  are read relative to it. Never assume the mission's starting directory is the repo.

## Task

Validate the repository/target contract, return `N/A` before deployment for irrelevant PRs,
resolve or provision one selective target, verify browser capabilities, and write the complete
run context. Never certify an interactive run from curl or static HTML.

## Steps

### 1. Setup and contract validation

```bash
cd "$WORKDIR"   # absolute checkout path from the orchestrator prompt
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/flowchad-runner}"

FLOW_NAME="$1"
REPO="$2"
PR_NUMBER="${3:-}"
[ "$PR_NUMBER" = none ] && PR_NUMBER=""
TRIGGER="${4:-manual}"
REPORT_DATE=$(date +%Y-%m-%d)
FLOW_SLUG=$(printf %s "$FLOW_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
TRANSCRIPT="reports/${REPORT_DATE}-flowchad-${FLOW_SLUG}.jsonl"
REPORT="reports/${REPORT_DATE}-flowchad-${FLOW_SLUG}.md"
mkdir -p reports .procedure-output/flowchad-runner

gh auth status >/dev/null
python3 -c 'import yaml' || { echo "BLOCKED: PyYAML unavailable"; exit 1; }

MODE="$TRIGGER"
[ "$MODE" = merge ] && MODE=production
[ "$MODE" = pr ] && MODE=preview
[ "$MODE" = manual ] && MODE=local
python3 "$SKILL_DIR/scripts/validate_contract.py" \
  --mode "$MODE" --repo "$REPO" --format json \
  > .procedure-output/flowchad-runner/contract.json
```

For production, preview, and cron, any validation error is `BLOCKED`. Never fall back to legacy
`.url`, a localhost target, or template identity. For local mode, report validation errors and
block any affected control rather than guessing.

If `environments.production.captcha.site_key_env` is configured, validate its runtime value
without printing it:

```bash
SITE_KEY_ENV=$(yq '.environments.production.captcha.site_key_env // ""' .flowchad/config.yml)
if [ -n "$SITE_KEY_ENV" ]; then
  SITE_KEY=$(printenv "$SITE_KEY_ENV")
  [ -n "$SITE_KEY" ] || { echo "BLOCKED: CAPTCHA site key is empty"; exit 1; }
  TRIMMED=$(printf %s "$SITE_KEY" | awk '{$1=$1};1')
  [ "$SITE_KEY" = "$TRIMMED" ] || { echo "BLOCKED: CAPTCHA site key has surrounding whitespace"; exit 1; }
fi
unset SITE_KEY TRIMMED
```

### 2. Select relevant PR work before preview resolution

For `TRIGGER=pr`, inspect the exact PR:

```bash
PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json author,headRefOid,files,state)
PR_AUTHOR=$(printf %s "$PR_JSON" | jq -r '.author.login // ""')
HEAD_SHA=$(printf %s "$PR_JSON" | jq -r '.headRefOid')
CHANGED_FILES=$(printf %s "$PR_JSON" | jq -r '.files[].path')
CHANGED_FILES_PATH=.procedure-output/flowchad-runner/changed-files.txt
printf '%s\n' "$CHANGED_FILES" > "$CHANGED_FILES_PATH"

if printf %s "$PR_AUTHOR" | grep -Eqi 'dependabot|renovate'; then
  RESULT_STATE="N/A"; BLOCK_REASON="automated dependency PR"
elif [ -n "$CHANGED_FILES" ] && ! printf '%s\n' "$CHANGED_FILES" | grep -Evq \
  '(^docs/|\.md$|^\.github/|^LICENSE$)'; then
  RESULT_STATE="N/A"; BLOCK_REASON="docs-only PR"
fi
```

If `RESULT_STATE=N/A`, write the handoff and stop. Do not call a deployment provider. For other
PRs, select flows through their checked-in `affects` globs:

```bash
python3 .claude/skills/flowchad-runner/scripts/validate_contract.py \
  --mode preview --repo "$REPO" --changed-files "$CHANGED_FILES_PATH" --format json \
  > .procedure-output/flowchad-runner/contract.json
AFFECTED_FLOWS=$(jq -r '.affected_flows[]' .procedure-output/flowchad-runner/contract.json)
if [ -z "$AFFECTED_FLOWS" ]; then
  RESULT_STATE="N/A"; BLOCK_REASON="no declared flow affected"
fi
```

`AFFECTED_FLOWS` feeds step 6. If a **specific named** flow was requested, intersect it with
`AFFECTED_FLOWS` and return `N/A` on an empty intersection, without creating a preview. The
selectors `affected` and `all` are not flow names and must never be intersected as if they were
— see step 6. Declare `affects` globs in every PR-verifiable flow; never guess impact from
filenames outside the contract.

### 3. Resolve the target

#### PR trigger

Prefer configured staging. Otherwise resolve a successful preview for the exact HEAD SHA:

```bash
TARGET_URL=$(yq '.environments.staging.url // ""' .flowchad/config.yml)
TARGET_KIND=staging
PREVIEW_CREATED=false
PREVIEW_MODE=$(yq '.environments.preview.mode' .flowchad/config.yml)

if [ -z "$TARGET_URL" ]; then
  TARGET_KIND=preview
  DEPLOY_ID=$(gh api "repos/${REPO}/deployments?ref=${HEAD_SHA}" \
    --jq '[.[] | select(.environment | test("Preview"; "i"))][0].id // empty')
  if [ -n "$DEPLOY_ID" ]; then
    TARGET_URL=$(gh api "repos/${REPO}/deployments/${DEPLOY_ID}/statuses" \
      --jq '[.[] | select(.state == "success")][0].environment_url // empty')
  fi
fi
```

If still absent and `preview.mode: on-demand`, provision exactly one Vercel preview for this
explicitly dispatched HEAD. The org/project IDs are non-secret target configuration; the token
comes from the runtime secret store:

```bash
if [ -z "$TARGET_URL" ] && [ "$PREVIEW_MODE" = on-demand ]; then
  [ "$(yq '.environments.preview.provider' .flowchad/config.yml)" = vercel ] || {
    echo "BLOCKED: unsupported on-demand preview provider"; exit 1;
  }
  : "${VERCEL_TOKEN:?BLOCKED: VERCEL_TOKEN unavailable for on-demand preview}"
  VERCEL_ORG_ID=$(yq '.environments.preview.vercel.org_id' .flowchad/config.yml)
  VERCEL_PROJECT_ID=$(yq '.environments.preview.vercel.project_id' .flowchad/config.yml)

  EXISTING=$(curl -fsS -H "Authorization: Bearer $VERCEL_TOKEN" \
    "https://api.vercel.com/v6/deployments?projectId=${VERCEL_PROJECT_ID}&teamId=${VERCEL_ORG_ID}&target=preview&limit=20" \
    | jq -r --arg sha "$HEAD_SHA" \
      '[.deployments[] | select(.meta.githubCommitSha == $sha and .state == "READY")][0].url // empty')
  if [ -n "$EXISTING" ]; then
    TARGET_URL="https://${EXISTING}"
  else
    mkdir -p .vercel
    printf '{"orgId":"%s","projectId":"%s"}\n' "$VERCEL_ORG_ID" "$VERCEL_PROJECT_ID" \
      > .vercel/project.json
    DEPLOY_OUTPUT=$(npx vercel deploy --yes --token="$VERCEL_TOKEN" \
      --meta githubCommitSha="$HEAD_SHA" --meta githubPrId="$PR_NUMBER" 2>&1)
    TARGET_URL=$(printf '%s\n' "$DEPLOY_OUTPUT" | grep -E '^https://' | tail -1)
    PREVIEW_CREATED=true
  fi
fi

[ -n "$TARGET_URL" ] || {
  echo "BLOCKED: no staging or preview target; preview mode is ${PREVIEW_MODE}"; exit 1;
}
```

This never connects the Git repository to Vercel or enables automatic previews.

#### Merge, cron, and manual triggers

```bash
case "$TRIGGER" in
  merge|cron)
    TARGET_URL=$(yq '.environments.production.url // ""' .flowchad/config.yml)
    TARGET_KIND=production
    ;;
  manual|*)
    TARGET_URL=$(yq '.environments.local.url // ""' .flowchad/config.yml)
    TARGET_KIND=local
    ;;
esac
[ -n "$TARGET_URL" ] || { echo "BLOCKED: no explicit target URL"; exit 1; }
```

### 4. Wait for an identified deployment

For a merge or newly created preview, poll only the deployment associated with the target SHA.
Use the configured timeout (default 300 seconds). `failure`, `error`, `inactive`, unknown terminal
state, and timeout are `BLOCKED`; create a deployment issue with the deploy ID and SHA.

```bash
DEPLOY_TIMEOUT=$(yq ".environments.${TARGET_KIND}.deploy_timeout // 300" .flowchad/config.yml)
POLL_INTERVAL=15
ELAPSED=0
while [ -n "${DEPLOY_ID:-}" ] && [ "$ELAPSED" -lt "$DEPLOY_TIMEOUT" ]; do
  STATE=$(gh api "repos/${REPO}/deployments/${DEPLOY_ID}/statuses" --jq '.[0].state // "unknown"')
  case "$STATE" in
    success) break ;;
    pending|queued|in_progress) sleep "$POLL_INTERVAL"; ELAPSED=$((ELAPSED + POLL_INTERVAL)) ;;
    *) echo "BLOCKED: deploy ${DEPLOY_ID} is ${STATE}"; exit 1 ;;
  esac
done
[ "$ELAPSED" -lt "$DEPLOY_TIMEOUT" ] || { echo "BLOCKED: deploy timeout"; exit 1; }
```

### 5. Resolve browser and persona capability

**Do not probe for Playwright in this turn.** The operator image
(`Dockerfile.operator`) ships no browser system libraries, so a local probe either fails
or — worse — finds the `headless_shell` binary and reports "available" for a browser that
cannot actually launch. That false positive is what produced the `BLOCKED` result with zero
screenshots on
[fellowship-dev/pylot#2802](https://github.com/fellowship-dev/pylot/pull/2802): *"headless_shell
binary is present but cannot launch — missing libnspr4.so, libnss3.so, libatk-1.0.so.0,
libgbm.so.1 … no sudo/apt-get available."*

Playwright capture happens on a **worker devbox**, which stage 03 spawns. The repo devbox image
(`.devcontainer/Dockerfile`) carries exactly those libs. So the capability question here is
*"can this mission spawn a worker for this repo?"*, not *"is chromium on my PATH?"*.

```bash
# Playwright capture is hosted on a worker devbox (stage 03 spawns it).
# The operator only needs to be able to reach the worker API.
PLAYWRIGHT_HOST=worker
CAPTURE_HOST=worker
PERSONA=$(yq '.persona // ""' .flowchad/config.yml)
```

Use the available Navvi MCP status/start tools to set `NAVVI_AVAILABLE` and load `PERSONA` when
configured. Do not emulate MCP calls as shell commands. Navvi runs in the **operator** turn (it
is an MCP tool bound to this session and is not reachable from a worker); when Navvi is
available and a flow needs it, set `CAPTURE_HOST=navvi` for that flow.

CAPTCHA, bot-detection, or authenticated flows that require Navvi are `BLOCKED` when it is
unavailable. Other interactive flows are `BLOCKED` when neither a worker devbox nor Navvi can
drive a browser — stage 03 reports the actual spawn result. Curl/static diagnostics may be
attached to the blocked result but cannot change it to `PASSED`.

### 6. Build the flow set

`affected` and `all` are **selectors**, not flow names. Resolve them before anything treats
`$FLOW_NAME` as a file basename:

```bash
ALL_FLOWS=$(yq '.smoke.flows[]' .flowchad/config.yml 2>/dev/null)
CRITICAL_FLOWS=$(yq '.smoke.critical[]' .flowchad/config.yml 2>/dev/null)
# Fall back to the critical set, then to the flow files on disk, when smoke.flows is absent.
if [ -z "$ALL_FLOWS" ]; then
  ALL_FLOWS="$CRITICAL_FLOWS"
fi
if [ -z "$ALL_FLOWS" ] && [ -d .flowchad/flows ]; then
  ALL_FLOWS=$(ls .flowchad/flows/*.yml 2>/dev/null | xargs -n1 basename | sed 's/\.yml$//')
fi

if [ "$TRIGGER" = cron ]; then
  FLOWS_TO_RUN="$CRITICAL_FLOWS"
elif [ "$FLOW_NAME" = affected ]; then
  FLOWS_TO_RUN="$AFFECTED_FLOWS"      # computed in step 2 from the changed-files contract
elif [ "$FLOW_NAME" = all ]; then
  FLOWS_TO_RUN="$ALL_FLOWS"
else
  # A named flow: intersect with what this PR actually affects (step 2).
  FLOWS_TO_RUN=$(printf '%s\n' "$AFFECTED_FLOWS" | grep -Fx "$FLOW_NAME" || true)
fi
[ -n "$FLOWS_TO_RUN" ] || { echo "BLOCKED: no flows selected"; exit 1; }
```

> **`affected` is the production selector.** The `flowchad-on-double-checked` automation
> dispatches `/flowchad-runner affected {repo} {number}` on every fire (1990+ to date) — it is
> by far the most common invocation. Treating it as a literal flow name intersects
> `{"affected"}` against the real flow names, yields the empty set, and returns `N/A` on a PR
> that genuinely affects a flow. Resolve the selector; never look for
> `.flowchad/flows/affected.yml`.
>
> For `TRIGGER=cron`, `$AFFECTED_FLOWS` is not computed (there is no PR) — cron always uses
> `smoke.critical` and must not be filtered by it.

Cron never filters `smoke.critical` because a persona or browser is missing. Missing capability
is `BLOCKED`, not a skip.

## Output: handoff.md

Path: `.procedure-output/flowchad-runner/01-preflight/handoff.md`

```markdown
# Stage 01: Preflight

## Status
blocked: {true|false}
block_reason: {reason or "none"}
result_state: {pending|BLOCKED|N/A}

## Run context
flow_name: {FLOW_NAME}
repo: {REPO}
pr_number: {PR_NUMBER or "none"}
trigger: {TRIGGER}
report_date: {REPORT_DATE}
flow_slug: {FLOW_SLUG}
transcript_path: {TRANSCRIPT}
report_path: {REPORT}
flows_to_run: {ordered flow names}

## Resolved environment
target_url: {TARGET_URL}
target_kind: {local|staging|preview|production}
target_sha: {HEAD_SHA or "n/a"}
preview_created: {true|false}
capture_host: {worker|navvi|none}
playwright_host: worker   # never the operator turn — Dockerfile.operator has no browser
navvi_available: {true|false}
navvi_persona: {persona or "none"}
contract_result: {.procedure-output/flowchad-runner/contract.json}
```

## Success Criteria

- Identity, environments, critical set, and flow contracts validate.
- An exact target and flow set are resolved.
- Interactive work has the required real-browser capability.
- An irrelevant PR returns `N/A` before any deployment provider call.

## Failure

- Invalid contract, missing target/deploy/browser/persona capability: `BLOCKED`.
- Dependabot, docs-only, or unaffected PR: `N/A`, not failure.
- Never downgrade these states to a static/curl pass.
