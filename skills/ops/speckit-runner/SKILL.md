---
name: speckit-runner
description: Use when implementing a GitHub issue end-to-end — MANDATORY for all dev tasks; spawns a repo worker devbox through speckit phases.
user-invocable: true
argument-hint: "[issue-number] [org/repo]"
allowed-tools: Read, Bash
---

Run the speckit pipeline for issue `$0` in repo `$1`.

You are an **operator** running in-session. You will spawn a worker devbox and drive it
through the speckit phases via the gateway worker API.

Gateway: `$PYLOT_API` (or `$PYLOT_GATEWAY_URL`). Token: `$PYLOT_DISPATCH_TOKEN`.
Mission: `$PYLOT_JOB_ID`. Repo: `$1` (or `$PYLOT_REPO`).

> **Drive the worker in the foreground by polling the worker API — in short chunks you re-run yourself.** After queueing each phase prompt, run the Poll-to-idle snippet (Step P) with the Bash tool, **using the default Bash timeout (do NOT pass a long `timeout`)**. Each call returns in **under 2 minutes** with a `POLL_RESULT`; while it prints `POLL_RESULT=running`, **run Step P again immediately** — repeat until `POLL_RESULT=done`.
>
> **The trap (read this):** the harness **auto-backgrounds any Bash command that runs past its tool `timeout`** (default ~120 s). A backgrounded poll is fatal. You may *see* a completion notification arrive for a background task — **ignore that signal as a reason to wait.** Those notifications only fire **while your session is actively running tool calls**; the instant you end your turn to "wait for it," the headless `claude -p` session exits and the mission is finalized as **failed** — while the worker is still healthy. So: never set a long Bash `timeout` on Step P, never background it, never "wait for a notification," never end your turn while a worker turn is in flight. If Step P ever gets backgrounded, that is a bug — kill it and run it again. Each call is short synchronous shell you run, read, and re-run yourself.

---

## Step 0: Dedup Gate

Before spawning anything, check if the issue is already closed:

```bash
ISSUE_STATE=$(gh issue view $0 --repo $1 --json state --jq '.state' 2>/dev/null || echo "OPEN")
if [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo "[pylot] outcome=\"already complete — issue $0 is CLOSED\" status=success"
  exit 0
fi
```

`outcome="already complete"` is **only valid here** — when the issue is genuinely CLOSED. Never emit it because of a timeout or missing notification.

---

## Step 1: Spawn Worker

```bash
REPO="${1:-$PYLOT_REPO}"
SPAWN_RESP=$(curl -s --max-time 90 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"repo\": \"$REPO\"}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers")
WID=$(echo "$SPAWN_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))' 2>/dev/null)
if [ -z "$WID" ]; then
  echo "[pylot] outcome=\"worker spawn failed: $(echo $SPAWN_RESP | head -c 200)\" status=failed"
  exit 1
fi
echo "[speckit-runner] worker spawned: $WID"
```

This skill ships a **`poll-worker.sh`** helper next to this file — the boot-sync copies the whole skill dir, so it lands at **`~/.claude/skills/speckit-runner/poll-worker.sh`** on the operator. It is the **only** way you poll a worker (see Step P) — never hand-roll a poll loop inline, never wait for a notification.

---

## Step P: Poll-to-idle (run the helper, loop while RUNNING)

After queueing a phase prompt, poll **only** by running the bundled helper with the Bash tool (**default timeout — do not pass a long one**):

```bash
bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"
```

Read its last line:
- `POLL_RESULT=done` (exit 0) → worker finished this turn; the printed output carries the phase marker. Proceed.
- `POLL_RESULT=running` (exit 10) → worker is **healthy and still working** — **run the exact same command again** (re-inline `WID`/`TURN_SEQ`; the script resumes its cumulative timer via a state file). The implement phase needs many of these — keep going.
- `POLL_RESULT=timeout` (exit 1) → budget hit; worker already stopped. Emit a failed outcome.

Each call returns in <2 min by design, so it never gets backgrounded. **Never** hand-roll a poll loop, set a long Bash `timeout`, background the call, wait for a notification, or end your turn while a worker turn is in flight — any of those abandons a healthy worker and fails the mission.

---

## Step 2: speckit.preflight — Pre-flight + Specify

Queue the prompt, then poll per **Step P**: run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"`, re-running it while `POLL_RESULT=running`.

```bash
PROMPT=$(python3 -c "import json,sys; print(json.dumps('You are a worker running inside repo $REPO. Issue: #$0.\n\nPre-Flight (MANDATORY — do this FIRST):\n1. Fetch issue: gh issue view $0 --repo $REPO --json title,body,labels,comments\n2. Check if closed: if CLOSED, emit [pylot] outcome=\"already complete\" status=success and exit.\n3. Verify required labels exist (create '\''in-progress'\'' if missing).\n4. Gather real data: read issue comments, fetch referenced URLs, read existing code patterns.\n\nSpeckit Specify:\n5. Ensure you'\''re on the default branch: git checkout \$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name) && git pull\n6. Bootstrap speckit scaffolding if absent: if [ ! -f \".specify/scripts/bash/create-new-feature.sh\" ]; then /setup-speckit; fi\n7. Run: /speckit-specify $0\n8. Read specs/ output. If there are open questions, answer them from pre-flight data, then run /speckit-clarify.\n9. Detect the feature branch created by specify: BRANCH=\$(git branch --show-current)\n\nWhen done: emit [pylot] phase=preflight status=done branch=\$BRANCH'))")
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
echo "[speckit-runner] preflight prompt queued (turn_seq=$TURN_SEQ)"
```

Poll per **Step P** now — run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"` and **re-run it while `POLL_RESULT=running`**. When it prints `POLL_RESULT=done`, read the printed worker output for `phase=preflight status=done`. If absent or `status=failed`, stop the worker and emit a failed outcome.

---

## Step 3: speckit.plan — Plan + Tasks

Queue the prompt, then poll per **Step P**: run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"`, re-running it while `POLL_RESULT=running`.

```bash
PROMPT=$(python3 -c "import json; print(json.dumps('Continue on the feature branch from the previous phase.\nRun: /speckit-plan $0\nRead specs/{issue-slug}/plan.md and verify the approach.\nRun: /speckit-tasks $0\nRead specs/{issue-slug}/tasks.md and verify tasks are concrete.\nWhen done: emit [pylot] phase=plan status=done'))")
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
echo "[speckit-runner] plan prompt queued (turn_seq=$TURN_SEQ)"
```

Poll per **Step P** now — run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"` and **re-run it while `POLL_RESULT=running`**. When it prints `POLL_RESULT=done`, check the printed worker output for `phase=plan status=done`. If blocked or failed, stop the worker and emit a blocked/failed outcome.

---

## Step 4: speckit.implement — Implement + PR

Queue the prompt, then poll per **Step P**: run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"`, re-running it while `POLL_RESULT=running`.

```bash
PROMPT=$(python3 -c "import json; print(json.dumps('Continue on the feature branch. Run: /speckit-implement $0\nAfter implementation:\n- Run the project test suite (fix failures before proceeding).\n- If dev server available: verify affected pages/APIs.\n- Commit spec files: git add specs/ && git diff --cached --quiet || git commit -m '\''docs: add speckit specs for issue #$0'\''\n- Push: git push origin \$(git branch --show-current)\n- Create PR: gh pr create --repo $REPO --head \$(git branch --show-current) --base \$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name) --title '\''fix/feat: <description> (#$0)'\'' --body '\''[PR body from /create-compelling-prs template]'\''\n- Run: /speckit-analyze $0 && /speckit-checklist $0\nWhen done: emit [pylot] phase=implement status=done pr=<PR_URL>'))")
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
echo "[speckit-runner] implement prompt queued (turn_seq=$TURN_SEQ)"
```

Poll per **Step P** now — run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"`. **This is the longest phase — expect many `POLL_RESULT=running` returns; just run the same command again after each** until `POLL_RESULT=done`. Do not abandon the worker between calls, do not wait for a notification, do not end your turn. When done, the printed output carries `phase=implement status=done pr=<PR_URL>`.

---

## Step 4.5: staging-validation — Deploy Branch to Staging + Post Evidence

After Step 4's poll-to-idle returns `POLL_RESULT=done`, re-fetch the worker output to extract the PR number, then queue the staging-validation worker prompt and poll to idle. This phase can take 15–30 minutes — expect many `POLL_RESULT=running` returns.

```bash
# Re-fetch worker output to extract PR number
ST=$(curl -s --max-time 20 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}")
WORKER_OUT=$(echo "$ST" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("last_output",""))' 2>/dev/null)
PR_NUM_45=$(echo "$WORKER_OUT" | python3 -c '
import sys, re, collections
wo = sys.stdin.read()
repo = "'$REPO'"
nums = re.findall(r"github\.com/%s/pull/(\d+)" % re.escape(repo), wo) if repo else []
if not nums: nums = re.findall(r"/pull/(\d+)", wo)
if not nums: raise SystemExit
cnt = collections.Counter(nums); last = {n: i for i, n in enumerate(nums)}
print(max(set(nums), key=lambda n: (cnt[n], last[n])))
' 2>/dev/null)

if [ -z "$PR_NUM_45" ]; then
  echo "[speckit-runner] Phase 4.5 skipped — no PR number found in implement output"
else
  PROMPT=$(PR_NUM="$PR_NUM_45" REPO="$REPO" python3 << 'PYEOF'
import json, os

pr = os.environ['PR_NUM']
repo = os.environ['REPO']

# Use str.replace() substitution so bash ${VAR} and {} are not escaped
prompt = """You are continuing on the feature branch after opening PR #PLACEHOLDER_PR in PLACEHOLDER_REPO.

Phase 4.5 — Staging Validation:

Run the following steps. Execute each bash block. When all steps complete, emit the final phase marker.

Step 1 — Credential guard:
```bash
STAGING_URL="${PYLOT_STAGING_URL:-}"
STAGING_TOKEN="${PYLOT_STAGING_DISPATCH_TOKEN:-}"
if [ -z "$STAGING_URL" ] || [ -z "$STAGING_TOKEN" ]; then
  echo "[pylot] phase=staging-validation status=blocked reason=\\"staging credentials missing\\""
  exit 0
fi
STAGING_URL="${STAGING_URL%/}"
PR_NUM="PLACEHOLDER_PR"
REPO="PLACEHOLDER_REPO"
```

Step 2 — Resolve branch and PR HEAD sha:
```bash
BRANCH=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || git rev-parse --abbrev-ref HEAD)
HEAD_SHA=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefSha --jq '.headRefSha' 2>/dev/null || echo "")
HEAD_SHORT=$(printf '%s' "$HEAD_SHA" | cut -c1-8)
echo "[staging-validation] branch=$BRANCH expected_sha=$HEAD_SHORT"
```

Step 3 — Check deployable surface (N/A path for docs-only PRs):
```bash
CHANGED_FILES=$(gh pr diff "$PR_NUM" --repo "$REPO" --name-only 2>/dev/null || echo "")
NEEDS_DEPLOY=false
while IFS= read -r f; do
  case "$f" in infra/*|gateway/*|crew.mjs|*/migrations/*.sql|src/*) NEEDS_DEPLOY=true; break ;; esac
done <<< "$CHANGED_FILES"

if [ "$NEEDS_DEPLOY" = "false" ]; then
  PR_BODY=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  { printf '%s\n\n' "$PR_BODY"; printf '## Staging Evidence\n> N/A — no deployable surface changed\n'; } > /tmp/pr_body_$$.md
  gh pr edit "$PR_NUM" --repo "$REPO" --body-file /tmp/pr_body_$$.md 2>/dev/null || true
  rm -f /tmp/pr_body_$$.md
  echo "[pylot] phase=staging-validation status=done evidence=na"
  exit 0
fi
```

Step 4 — Deploy branch to staging:
```bash
echo "[staging-validation] deploying $BRANCH to staging..."
RESP=$(curl -sf -X POST "${STAGING_URL}/admin/deploy" \
  -H "Authorization: Bearer $STAGING_TOKEN" -H "Content-Type: application/json" \
  -d "{\\"source_version\\": \\"$BRANCH\\"}" 2>/dev/null || echo "")

if [ -z "$RESP" ]; then
  PR_BODY=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  PR_BODY=$(printf '%s' "$PR_BODY" | sed '/^## Staging Evidence/,$d')
  { printf '%s\n\n' "$PR_BODY"
    printf '## Staging Evidence\n'
    printf '- **Branch:** `%s`\n' "$BRANCH"
    printf '- **Result:** FAILED (deploy trigger unreachable)\n'
    printf '- **deployed_sha:** (unavailable)\n'; } > /tmp/pr_body_$$.md
  gh pr edit "$PR_NUM" --repo "$REPO" --body-file /tmp/pr_body_$$.md 2>/dev/null || true
  rm -f /tmp/pr_body_$$.md
  # Restore staging
  curl -sf -X POST "${STAGING_URL}/admin/deploy" -H "Authorization: Bearer $STAGING_TOKEN" \
    -H "Content-Type: application/json" -d '{"source_version":"develop"}' >/dev/null 2>&1 || true
  echo "[pylot] phase=staging-validation status=done evidence=failed"
  exit 0
fi
BUILD_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('build_id',''))" 2>/dev/null || echo "")
echo "[staging-validation] build_id=$BUILD_ID"
```

Step 5 — Poll build status (up to 30x30s = 15 min):
```bash
DEPLOY_OK=0
for i in $(seq 1 30); do
  sleep 30
  SRESP=$(curl -sf "${STAGING_URL}/admin/build-worker/$BUILD_ID" -H "Authorization: Bearer $STAGING_TOKEN" 2>/dev/null || echo "{}")
  BSTAT=$(echo "$SRESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
  echo "[staging-validation] [build $i/30] $BSTAT"
  case "$BSTAT" in
    SUCCEEDED) DEPLOY_OK=1; break ;;
    FAILED|STOPPED)
      PR_BODY=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
      PR_BODY=$(printf '%s' "$PR_BODY" | sed '/^## Staging Evidence/,$d')
      { printf '%s\n\n' "$PR_BODY"
        printf '## Staging Evidence\n'
        printf '- **Branch:** `%s`\n' "$BRANCH"
        printf '- **Build ID:** `%s`\n' "$BUILD_ID"
        printf '- **Result:** BUILD %s\n' "$BSTAT"
        printf '- **deployed_sha:** (build did not succeed)\n'; } > /tmp/pr_body_$$.md
      gh pr edit "$PR_NUM" --repo "$REPO" --body-file /tmp/pr_body_$$.md 2>/dev/null || true
      rm -f /tmp/pr_body_$$.md
      curl -sf -X POST "${STAGING_URL}/admin/deploy" -H "Authorization: Bearer $STAGING_TOKEN" \
        -H "Content-Type: application/json" -d '{"source_version":"develop"}' >/dev/null 2>&1 || true
      echo "[pylot] phase=staging-validation status=done evidence=failed"
      exit 0 ;;
  esac
done
if [ "$DEPLOY_OK" -eq 0 ]; then
  PR_BODY=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  PR_BODY=$(printf '%s' "$PR_BODY" | sed '/^## Staging Evidence/,$d')
  { printf '%s\n\n' "$PR_BODY"
    printf '## Staging Evidence\n'
    printf '- **Branch:** `%s`\n' "$BRANCH"
    printf '- **Build ID:** `%s`\n' "$BUILD_ID"
    printf '- **Result:** BUILD TIMEOUT\n'
    printf '- **deployed_sha:** (build timed out after 15 min)\n'; } > /tmp/pr_body_$$.md
  gh pr edit "$PR_NUM" --repo "$REPO" --body-file /tmp/pr_body_$$.md 2>/dev/null || true
  rm -f /tmp/pr_body_$$.md
  curl -sf -X POST "${STAGING_URL}/admin/deploy" -H "Authorization: Bearer $STAGING_TOKEN" \
    -H "Content-Type: application/json" -d '{"source_version":"develop"}' >/dev/null 2>&1 || true
  echo "[pylot] phase=staging-validation status=done evidence=failed"
  exit 0
fi
```

Step 6 — Poll gateway health until sha is confirmed (up to 30x30s = 15 min):
```bash
HEALTH_TMP="/tmp/tis_health_$$.json"
trap 'rm -f "$HEALTH_TMP"' EXIT
LIVE_SHA="-"
HEALTH_CODE="000"
HEALTH_OK=0
for i in $(seq 1 30); do
  HEALTH_CODE=$(curl -so "$HEALTH_TMP" -w "%{http_code}" "${STAGING_URL}/health" 2>/dev/null || echo "000")
  LIVE_SHA=$(cat "$HEALTH_TMP" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha','-'))" 2>/dev/null || echo "-")
  LIVE_SHORT=$(printf '%s' "$LIVE_SHA" | cut -c1-8)
  echo "[staging-validation] [health $i/30] code=$HEALTH_CODE sha=$LIVE_SHORT"
  [ "$HEALTH_CODE" = "200" ] && [ "$LIVE_SHA" != "-" ] && { HEALTH_OK=1; break; }
  sleep 30
done

if [ "$HEALTH_OK" -eq 0 ]; then
  PR_BODY=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  PR_BODY=$(printf '%s' "$PR_BODY" | sed '/^## Staging Evidence/,$d')
  { printf '%s\n\n' "$PR_BODY"
    printf '## Staging Evidence\n'
    printf '- **Branch:** `%s`\n' "$BRANCH"
    printf '- **Build ID:** `%s`\n' "$BUILD_ID"
    printf '- **Result:** HEALTH GATE FAILED (code=%s)\n' "$HEALTH_CODE"
    printf '- **deployed_sha:** (health timeout; sha never confirmed)\n'; } > /tmp/pr_body_$$.md
  gh pr edit "$PR_NUM" --repo "$REPO" --body-file /tmp/pr_body_$$.md 2>/dev/null || true
  rm -f /tmp/pr_body_$$.md
  curl -sf -X POST "${STAGING_URL}/admin/deploy" -H "Authorization: Bearer $STAGING_TOKEN" \
    -H "Content-Type: application/json" -d '{"source_version":"develop"}' >/dev/null 2>&1 || true
  echo "[pylot] phase=staging-validation status=done evidence=failed"
  exit 0
fi
```

Step 7 — Compare live sha to PR HEAD sha (first 8 chars):
```bash
LIVE_SHORT=$(printf '%s' "$LIVE_SHA" | cut -c1-8)
EVIDENCE_TYPE="real"
SHA_NOTE=""
if [ -z "$HEAD_SHORT" ]; then
  EVIDENCE_TYPE="stale"
  SHA_NOTE=" (SHA unverifiable — could not fetch PR HEAD)"
elif [ "$LIVE_SHORT" != "$HEAD_SHORT" ]; then
  EVIDENCE_TYPE="stale"
  SHA_NOTE=" (SHA MISMATCH: expected $HEAD_SHORT, got $LIVE_SHORT)"
fi
```

Step 8 — Run smoke tests:
```bash
CREW_TMP="/tmp/tis_crew_$$.json"
CREW_CODE=$(curl -so "$CREW_TMP" -w "%{http_code}" -H "Authorization: Bearer $STAGING_TOKEN" \
  "${STAGING_URL}/crew" 2>/dev/null || echo "000")
CREW_COUNT=$(cat "$CREW_TMP" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
if isinstance(d,list): print(len(d))
elif isinstance(d,dict): print(len(d.get('operators',d.get('members',[]))))
else: print(0)
" 2>/dev/null || echo "0")
rm -f "$CREW_TMP"
```

Step 9 — Append evidence block to PR body (strip prior evidence section first to avoid accumulation):
```bash
PR_BODY=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
PR_BODY=$(printf '%s' "$PR_BODY" | sed '/^## Staging Evidence/,$d')
{ printf '%s\n\n' "$PR_BODY"
  printf '## Staging Evidence\n'
  printf '- **Branch:** `%s`\n' "$BRANCH"
  printf '- **deployed_sha:** `%s`%s\n' "$LIVE_SHA" "$SHA_NOTE"
  printf '- **Health check:** %s (gateway: `%s`)\n' "$HEALTH_CODE" "$STAGING_URL"
  printf '- **Smoke tests:**\n'
  printf '  - GET /health -> %s (sha=%s)\n' "$HEALTH_CODE" "$LIVE_SHORT"
  printf '  - GET /crew -> %s (%s members)\n' "$CREW_CODE" "$CREW_COUNT"; } > /tmp/pr_body_$$.md
gh pr edit "$PR_NUM" --repo "$REPO" --body-file /tmp/pr_body_$$.md 2>/dev/null && \
  echo "[staging-validation] evidence posted to PR #$PR_NUM" || \
  echo "[staging-validation] WARNING: failed to post evidence to PR"
rm -f /tmp/pr_body_$$.md
```

Step 10 — Restore staging to develop (always, success or failure):
```bash
echo "[staging-validation] restoring staging to develop..."
RRESP=$(curl -sf -X POST "${STAGING_URL}/admin/deploy" \
  -H "Authorization: Bearer $STAGING_TOKEN" -H "Content-Type: application/json" \
  -d '{"source_version":"develop"}' 2>/dev/null || echo "")
RBID=$(echo "$RRESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('build_id',''))" 2>/dev/null || echo "")
if [ -n "$RBID" ]; then
  for i in $(seq 1 20); do
    sleep 30
    RS=$(curl -sf "${STAGING_URL}/admin/build-worker/$RBID" -H "Authorization: Bearer $STAGING_TOKEN" 2>/dev/null || echo "{}")
    RS_ST=$(echo "$RS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
    echo "[staging-validation] [restore $i/20] $RS_ST"
    case "$RS_ST" in SUCCEEDED|FAILED|STOPPED) break ;; esac
  done
  echo "[staging-validation] restore=$RS_ST"
fi
```

Final — emit phase marker:
```bash
echo "[pylot] phase=staging-validation status=done evidence=$EVIDENCE_TYPE"
```
""".replace("PLACEHOLDER_PR", pr).replace("PLACEHOLDER_REPO", repo)
print(json.dumps(prompt))
PYEOF
  )
  PROMPT_RESP=$(curl -s --max-time 30 -X POST \
    -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": $PROMPT}" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
  TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
  echo "[speckit-runner] staging-validation prompt queued (turn_seq=$TURN_SEQ)"
fi
```

Poll per **Step P** now — run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"` and **re-run it while `POLL_RESULT=running`**. The deploy + health gate takes up to 30 minutes. When done, check the `phase=staging-validation` marker:

- `status=blocked` → credentials missing; proceed to Step 5 (PR will be gated; file a separate issue to provision creds).
- `status=done evidence=real` → evidence posted, sha matched; cto-review gate will pass.
- `status=done evidence=failed` → failure evidence posted; PR blocked at gate (correct — mission is still `status=success`).
- `status=done evidence=stale` → SHA mismatch posted; cto-review gate will short-circuit.
- `status=done evidence=na` → docs-only PR; N/A posted; gate will not fire.

---

## Step 5: Identify PR + Stop Worker

```bash
# Re-fetch fresh — $ST from Step P does not survive into this separate Bash call.
ST=$(curl -s --max-time 20 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}")
WORKER_OUT=$(echo "$ST" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("last_output",""))' 2>/dev/null)
PR_NUM=$(echo "$WORKER_OUT" | python3 -c '
import sys, re, collections
wo = sys.stdin.read()
repo = "'$REPO'"
nums = re.findall(r"github\.com/%s/pull/(\d+)" % re.escape(repo), wo) if repo else []
if not nums: nums = re.findall(r"/pull/(\d+)", wo)
if not nums: raise SystemExit
cnt = collections.Counter(nums); last = {n: i for i, n in enumerate(nums)}
print(max(set(nums), key=lambda n: (cnt[n], last[n])))
' 2>/dev/null)

# Stop the worker
curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
```

---

## Step 6: Emit Outcome

```bash
if [ -n "$PR_NUM" ]; then
  echo "[pylot] outcome=\"speckit complete: PR #$PR_NUM opened for issue #$0\" status=success"
else
  echo "[pylot] outcome=\"speckit complete but no PR URL found — check worker logs\" status=partial"
fi
```

---

## Hard Rules

- **Pre-flight is mandatory** — the worker must gather real data before speckit phases
- **Poll only via the script** — after every phase run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"` (default Bash timeout); it returns in <2 min, so just run it again while it prints `POLL_RESULT=running`. Never hand-roll a poll loop, never pass a long Bash `timeout`, never let it get backgrounded, never wait for a notification, never end your turn while a worker turn is in flight (the session exits → bogus `"poll timeout"` on a healthy worker).
- **Stop the worker** — always call /stop when done, even on failure
- **Emit the outcome marker** — `[pylot] outcome=... status=` is mandatory before exiting
- **"already complete" only at the dedup gate** — only emit this when the issue is genuinely CLOSED (Step 0); never for timeouts or missing notifications
- **One task, one PR** — do not scope-creep into adjacent issues
