---
name: speckit-runner
description: Use when implementing a GitHub issue end-to-end — MANDATORY for all dev tasks; spawns a repo worker devbox through speckit phases.
user-invocable: true
argument-hint: "[issue-number] [org/repo]"
allowed-tools: Read, Bash
---

Run the speckit pipeline for issue `$0` in repo `$1`.

You are an **operator** running in-session. You will spawn a worker devbox and drive it
through the speckit phases via the gateway worker API. Read `pylot-workers` for the
full worker API reference.

Gateway: `$PYLOT_API` (or `$PYLOT_GATEWAY_URL`). Token: `$PYLOT_DISPATCH_TOKEN`.
Mission: `$PYLOT_JOB_ID`. Repo: `$1` (or `$PYLOT_REPO`).

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

## Step 2: speckit.preflight — Pre-flight + Specify

Send the pre-flight and specify phase as one prompt. Poll to idle.

```
PROMPT: "You are a worker running inside repo $REPO. Issue: #$0.

Pre-Flight (MANDATORY — do this FIRST):
1. Fetch issue: gh issue view $0 --repo $REPO --json title,body,labels,comments
2. Check if closed: if CLOSED, emit [pylot] outcome=\"already complete\" status=success and exit.
3. Verify required labels exist (create 'in-progress' if missing).
4. Gather real data: read issue comments, fetch referenced URLs, read existing code patterns.

Speckit Specify:
5. Ensure you're on the default branch: git checkout $(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name) && git pull
6. Bootstrap speckit scaffolding if absent: if [ ! -f \".specify/scripts/bash/create-new-feature.sh\" ]; then /setup-speckit; fi
7. Run: /speckit-specify $0
8. Read specs/ output. If there are open questions, answer them from pre-flight data, then run /speckit-clarify.
9. Detect the feature branch created by specify: BRANCH=\$(git branch --show-current)

When done: emit [pylot] phase=preflight status=done branch=\$BRANCH"
```

After prompt is sent, poll until idle (see `pylot-workers` drive loop pattern).
Check `last_output` for phase failure before proceeding.

---

## Step 3: speckit.plan — Plan + Tasks

```
PROMPT: "Continue on the feature branch from the previous phase.
Run: /speckit-plan $0
Read specs/{issue-slug}/plan.md and verify the approach.
Run: /speckit-tasks $0
Read specs/{issue-slug}/tasks.md and verify tasks are concrete.
When done: emit [pylot] phase=plan status=done"
```

Poll to idle. Check for blockers in `last_output`.

---

## Step 4: speckit.implement — Implement + PR

```
PROMPT: "Continue on the feature branch. Run: /speckit-implement $0
After implementation:
- Run the project test suite (fix failures before proceeding).
- If dev server available: verify affected pages/APIs.
- Commit spec files: git add specs/ && git diff --cached --quiet || git commit -m 'docs: add speckit specs for issue #$0'
- Push: git push origin \$(git branch --show-current)
- Create PR: gh pr create --repo $REPO --head \$(git branch --show-current) --base \$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name) --title 'fix/feat: <description> (#$0)' --body '[PR body from /create-compelling-prs template]'
- Run: /speckit-analyze $0 && /speckit-checklist $0
When done: emit [pylot] phase=implement status=done pr=<PR_URL>"
```

Poll to idle.

---

## Step 5: Identify PR + Stop Worker

Extract the PR number from `last_output`:

```bash
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
- **Poll between every phase** — never fire-and-forget; check phase output before sending next prompt
- **Stop the worker** — always call /stop when done, even on failure
- **Emit the outcome marker** — `[pylot] outcome=... status=` is mandatory before exiting
- **One task, one PR** — do not scope-creep into adjacent issues
