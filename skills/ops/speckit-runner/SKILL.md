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

> **Drive the worker in the foreground by polling the worker API — in short chunks you re-run yourself.** After queueing each phase prompt, run the Poll-to-idle snippet (Step P) with the Bash tool, **using the default Bash timeout (do NOT pass a long `timeout`)**. Each call returns in **under 2 minutes** with a `POLL_RESULT`; while it prints `POLL_RESULT=running`, **run Step P again immediately** — repeat until `POLL_RESULT=done`.
>
> **The trap (read this):** the harness **auto-backgrounds any Bash command that runs past its tool `timeout`** (default ~120 s). A backgrounded poll is fatal. You may *see* a completion notification arrive for a background task — **ignore that signal as a reason to wait.** Those notifications only fire **while your session is actively running tool calls**; the instant you end your turn to "wait for it," the headless `claude -p` session exits and the mission is finalized as **failed** — while the worker is still healthy. So: never set a long Bash `timeout` on Step P, never background it, never "wait for a notification," never end your turn while a worker turn is in flight. If Step P ever gets backgrounded, that is a bug — kill it and run it again. Each call is short synchronous shell you run, read, and re-run yourself.

---

## Step 0: Dedup Gate

Before spawning anything, check if the issue is already closed:

```bash
ISSUE_STATE=$(gh issue view $0 --repo $1 --json state --jq '.state' 2>/dev/null || echo "OPEN")
if [ "$ISSUE_STATE" = "CLOSED" ]; then
  exit 0
fi
```

`outcome="already complete"` is **only valid here** — when the issue is genuinely CLOSED. Never emit it because of a timeout or missing notification.

---

## Step 1: Spawn Worker

```bash
REPO="${1:-$PYLOT_REPO}"
SPAWN_RESP=$(curl -s --max-time 90 -X POST \
WID=$(echo "$SPAWN_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))' 2>/dev/null)
if [ -z "$WID" ]; then
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
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
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
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
echo "[speckit-runner] implement prompt queued (turn_seq=$TURN_SEQ)"
```

Poll per **Step P** now — run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"`. **This is the longest phase — expect many `POLL_RESULT=running` returns; just run the same command again after each** until `POLL_RESULT=done`. Do not abandon the worker between calls, do not wait for a notification, do not end your turn. When done, the printed output carries `phase=implement status=done pr=<PR_URL>`.

---

## Step 5: Identify PR + Stop Worker

```bash
# Re-fetch fresh — $ST from Step P does not survive into this separate Bash call.
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
```

---

## Step 6: Emit Outcome

```bash
if [ -n "$PR_NUM" ]; then
else
fi
```

---

## Hard Rules

- **Pre-flight is mandatory** — the worker must gather real data before speckit phases
- **Poll only via the script** — after every phase run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"` (default Bash timeout); it returns in <2 min, so just run it again while it prints `POLL_RESULT=running`. Never hand-roll a poll loop, never pass a long Bash `timeout`, never let it get backgrounded, never wait for a notification, never end your turn while a worker turn is in flight (the session exits → bogus `"poll timeout"` on a healthy worker).
- **Stop the worker** — always call /stop when done, even on failure
- **"already complete" only at the dedup gate** — only emit this when the issue is genuinely CLOSED (Step 0); never for timeouts or missing notifications
- **One task, one PR** — do not scope-creep into adjacent issues
