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

> **Drive the worker in the foreground by polling the worker API — in bounded chunks.** After queueing each phase prompt, run the Poll-to-idle snippet (Step P) with the Bash tool. Step P polls for **at most ~7 min per call** (under the harness's 10-min foreground Bash cap) and then **returns**: if it prints `POLL_RESULT=running` the worker is healthy and still working — **run Step P again immediately**, and repeat until it prints `POLL_RESULT=done`. Never let a single poll call run past ~8 min: the harness auto-backgrounds longer Bash commands, and in a headless `claude -p` runner there is **no background-completion wake-up**, so a backgrounded poll deadlocks the session and emits a bogus `"poll timeout"` while the worker is still healthily running. Do **not** spawn background tasks, use ScheduleWakeup, or "wait for a notification." Each Step P call is synchronous shell you run yourself.

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

---

## Step P: Poll-to-idle snippet (chunked, foreground-safe)

Run this with the Bash tool after queueing a phase prompt. It polls for **at most one chunk (~7 min)** then **returns** with a `POLL_RESULT`:

- `POLL_RESULT=done` → the worker finished this turn; proceed to the next phase.
- `POLL_RESULT=running` → the worker is **healthy and still working** — **run this exact block again** (it resumes the cumulative timer; it does not restart it).
- `POLL_RESULT=timeout` → the overall budget is exhausted; the worker was stopped and a failed outcome emitted.

Each call stays under the 10-min foreground Bash cap, so it never gets backgrounded. The operator must set `WID` and `TURN_SEQ` (from the queue step) at the top of the call — shell state does not persist between Bash calls, so re-inline them.

```bash
# WID and TURN_SEQ must already be set in this call (re-inline them).
CHUNK="${PYLOT_WORKER_POLL_CHUNK:-420}"      # per-call budget (s) — keep < 540 (10-min Bash cap)
POLL_MAX="${PYLOT_WORKER_POLL_MAX:-3600}"    # overall budget (s) across all chunks for this turn
STATE="/tmp/speckit_poll_${PYLOT_JOB_ID}_${WID}_${TURN_SEQ}.el"
TOTAL=$(cat "$STATE" 2>/dev/null || echo 0); [ -z "$TOTAL" ] && TOTAL=0
CHUNK_EL=0; WORKER_EXIT=""; W_STATE=""; W_SEQ=""; ST=""
while [ "$CHUNK_EL" -lt "$CHUNK" ] && [ "$TOTAL" -lt "$POLL_MAX" ]; do
  sleep 15; CHUNK_EL=$((CHUNK_EL + 15)); TOTAL=$((TOTAL + 15))
  ST=$(curl -s --max-time 20 \
    -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}")
  ST_LINE=$(echo "$ST" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except: d = {}
ec = d.get("last_exit_code")
print("%s|%s|%s" % (d.get("turn_state",""), d.get("turn_seq",""), "" if ec is None else ec))
' 2>/dev/null)
  W_STATE="${ST_LINE%%|*}"; W_REST="${ST_LINE#*|}"; W_SEQ="${W_REST%%|*}"; W_EC="${W_REST##*|}"
  if [ "$W_STATE" = "idle" ] && [ "$W_SEQ" = "$TURN_SEQ" ]; then WORKER_EXIT="$W_EC"; break; fi
  if [ $((CHUNK_EL % 120)) -eq 0 ]; then   # heartbeat + recent worker output, so progress is visible
    echo "[poll +${CHUNK_EL}s | total ${TOTAL}s] state=$W_STATE seq=$W_SEQ"
    echo "$ST" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("last_output","") or "")[-500:])' 2>/dev/null
  fi
done
echo "$TOTAL" > "$STATE"
if [ "$W_STATE" = "idle" ] && [ "$W_SEQ" = "$TURN_SEQ" ]; then
  rm -f "$STATE"
  WORKER_OUT=$(echo "$ST" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("last_output",""))' 2>/dev/null)
  echo "[speckit-runner] phase done (exit=$WORKER_EXIT)"; echo "$WORKER_OUT" | tail -12
  echo "POLL_RESULT=done"
elif [ "$TOTAL" -ge "$POLL_MAX" ]; then
  rm -f "$STATE"
  echo "[speckit-runner] poll exceeded overall budget ${POLL_MAX}s"
  curl -s --max-time 30 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
  echo "[pylot] outcome=\"poll timeout waiting for worker\" status=failed"
  echo "POLL_RESULT=timeout"
else
  echo "[speckit-runner] worker still running (total ${TOTAL}s) — RUN STEP P AGAIN"
  echo "POLL_RESULT=running"
fi
```

---

## Step 2: speckit.preflight — Pre-flight + Specify

Queue the prompt, then run the **Poll-to-idle snippet (Step P)** with the Bash tool.

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

Run the **Poll-to-idle snippet (Step P)** with the Bash tool now. **While it prints `POLL_RESULT=running`, run Step P again** (re-inline `WID` and `TURN_SEQ`). When it prints `POLL_RESULT=done`, read the printed worker output for `phase=preflight status=done`. If absent or `status=failed`, stop the worker and emit a failed outcome.

---

## Step 3: speckit.plan — Plan + Tasks

Queue the prompt, then run the **Poll-to-idle snippet (Step P)** with the Bash tool.

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

Run the **Poll-to-idle snippet (Step P)** with the Bash tool now. **While it prints `POLL_RESULT=running`, run Step P again.** When it prints `POLL_RESULT=done`, check the printed worker output for `phase=plan status=done`. If blocked or failed, stop the worker and emit a blocked/failed outcome.

---

## Step 4: speckit.implement — Implement + PR

Queue the prompt, then run the **Poll-to-idle snippet (Step P)** with the Bash tool.

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

Run the **Poll-to-idle snippet (Step P)** with the Bash tool now. **This is the longest phase — expect several `POLL_RESULT=running` chunks; run Step P again after each one** until it prints `POLL_RESULT=done`. Do not abandon the worker between chunks and do not wait for a background notification. When done, the printed output carries `phase=implement status=done pr=<PR_URL>`.

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
- **Poll in the foreground, in chunks** — run Step P after every phase; it returns every ~7 min, so re-run it while it prints `POLL_RESULT=running`. Never let one poll call exceed the 10-min Bash cap (it gets auto-backgrounded → headless deadlock → bogus `"poll timeout"` on a healthy worker). Never background it; never wait for a notification.
- **Stop the worker** — always call /stop when done, even on failure
- **Emit the outcome marker** — `[pylot] outcome=... status=` is mandatory before exiting
- **"already complete" only at the dedup gate** — only emit this when the issue is genuinely CLOSED (Step 0); never for timeouts or missing notifications
- **One task, one PR** — do not scope-creep into adjacent issues
