---
name: speckit-runner
description: Use when implementing a GitHub issue end-to-end — runs speckit with an independent advisory review before creating one PR.
user-invocable: true
argument-hint: "[issue-number] [org/repo]"
allowed-tools: Read, Bash
---

Run the speckit pipeline for issue `$0` in repo `$1`.

You are an **operator** running in-session. Drive a producer through the speckit
phases, then give its pushed checkpoint to a separate review worker before PR creation.

Gateway: `$PYLOT_API` (or `$PYLOT_GATEWAY_URL`). Token: `$PYLOT_DISPATCH_TOKEN`.
Mission: `$PYLOT_JOB_ID`. Repo: `$1` (or `$PYLOT_REPO`).

Define this cleanup once at session start. The EXIT trap makes detached supervisor
checkout removal executable on every terminal path, including an early failure.

```bash
cleanup_supervisor_checkout() {
  if [ -n "${SUPERVISOR_CHECKOUT:-}" ] && [ -d "$SUPERVISOR_CHECKOUT" ]; then
    git worktree remove --force "$SUPERVISOR_CHECKOUT" >/dev/null 2>&1 || true
  fi
}
trap cleanup_supervisor_checkout EXIT
```

> **Drive the worker in the foreground by polling the worker API — in short chunks you re-run yourself.** After queueing each phase prompt, run the Poll-to-idle snippet (Step P) with the Bash tool, **using the default Bash timeout (do NOT pass a long `timeout`)**. Each call returns in **under 2 minutes** with a `POLL_RESULT`; while it prints `POLL_RESULT=running`, **run Step P again immediately**. Every ~30 min it prints `POLL_RESULT=block_elapsed` with a decision packet (heartbeat age, output-changed flag, log tail) — review it and, if the worker is healthy, **run Step P again to grant another block**. Repeat until `POLL_RESULT=done`.
>
> **The trap (read this):** the harness **auto-backgrounds any Bash command that runs past its tool `timeout`** (default ~120 s). A backgrounded poll is fatal. You may *see* a completion notification arrive for a background task — **ignore that signal as a reason to wait.** Those notifications only fire **while your session is actively running tool calls**; the instant you end your turn to "wait for it," the headless `claude -p` session exits and the mission is finalized as **failed** — while the worker is still healthy. So: never set a long Bash `timeout` on Step P, never background it, never "wait for a notification," never end your turn while a worker turn is in flight. If Step P ever gets backgrounded, that is a bug — kill it and run it again. Each call is short synchronous shell you run, read, and re-run yourself.

---

## Step 0: Reconcile Before Starting

Before spawning anything, check both terminal issue state and an already-open PR.
This is the resume boundary: a rerun must report the existing PR instead of
creating another one.

```bash
REPO="${1:-$PYLOT_REPO}"
ISSUE_STATE=$(gh issue view $0 --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "OPEN")
if [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo "[pylot] outcome=\"already complete — issue $0 is CLOSED\" status=success"
  exit 0
fi

OPEN_PRS=$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,url,headRefName,closingIssuesReferences 2>/dev/null || echo '[]')
EXISTING_PR=$(printf '%s' "$OPEN_PRS" | jq -c --argjson issue "$0" --arg repo "$REPO" '
  [.[] | select(any(.closingIssuesReferences[]?;
    .number == $issue and .repository.nameWithOwner == $repo))][0] // empty')

# A pushed checkpoint may not have a PR yet. If exactly one remote branch has
# an issue-number segment, also reconcile an open PR by its exact head ref.
BRANCH_CANDIDATES=$(gh api "repos/$REPO/branches" --paginate --jq '.[].name' 2>/dev/null \
  | awk -v n="$0" '$0 ~ ("(^|[-_/])" n "($|[-_/])")')
if [ "$(printf '%s\n' "$BRANCH_CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ]; then
  RESUME_BRANCH=$(printf '%s\n' "$BRANCH_CANDIDATES" | sed '/^$/d')
  HEAD_PR=$(printf '%s' "$OPEN_PRS" | jq -c --arg head "$RESUME_BRANCH" \
    '[.[] | select(.headRefName == $head)][0] // empty')
  [ -n "$EXISTING_PR" ] || EXISTING_PR="$HEAD_PR"
fi
if [ -n "$EXISTING_PR" ]; then
  PR_URL=$(printf '%s' "$EXISTING_PR" | jq -r '.url')
  echo "[pylot] outcome=\"resume reconciliation found existing PR: $PR_URL\" status=success"
  exit 0
fi
```

`outcome="already complete"` is **only valid here** — when the issue is genuinely CLOSED. Never emit it because of a timeout or missing notification.
An open PR is also terminal for this run, but report it as a reconciled existing
PR, not as "already complete." Exact closing linkage is preferred; exact head
matching is the fallback for a unique checkpoint branch. If no PR exists, pass
that unique `RESUME_BRANCH` to the worker and resume it only when its checkpoint
matches the issue. Ambiguous matches are advisory context: start from the default
branch rather than guessing.

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
- `POLL_RESULT=block_elapsed` (exit 20) → a poll block (default 30 min) elapsed; the worker is **NOT stopped** and is very likely still working. The script printed a **decision packet**: `heartbeat_age`, `output_changed`, and a tail of the worker's output. Decide — **heartbeat_age is the primary signal**:
  - **heartbeat fresh (< ~5 min) → run the exact same command again.** That grants another block. This is the DEFAULT for a healthy worker — long implement turns legitimately take multiple blocks; never fail a healthy worker just because time passed. `output_changed=empty` mid-turn is NORMAL (worker output only lands at turn end) and is not a stuck signal.
  - **heartbeat stale (> ~10 min, W_STATE still running) → the worker is wedged.** Run Step C and emit a failed outcome quoting the packet. `output_changed=no` across consecutive blocks is corroborating evidence only, never sufficient by itself.
- `POLL_RESULT=ceiling_timeout` (exit 1) → the hard ceiling (default 4 h per turn) was hit; the current worker has already been stopped by the script. Run Step C, then emit a failed outcome.

Each call returns in <2 min by design, so it never gets backgrounded. **Never** hand-roll a poll loop, set a long Bash `timeout`, background the call, wait for a notification, or end your turn while a worker turn is in flight — any of those abandons a healthy worker and fails the mission.

---

## Step C: Always-Run Cleanup + Resume Receipt

Run this before every terminal outcome — success, partial, blocked, or failed.
It stops every spawned worker while preserving pushed Git checkpoints. It also
prints the exact remote head the next invocation can reconcile.

```bash
for WORKER_ID in "${WID:-}" "${RWID:-}"; do
  [ -z "$WORKER_ID" ] || curl -s --max-time 30 -X POST \
    -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WORKER_ID}/stop" >/dev/null 2>&1 || true
done

if [ -n "${BRANCH:-}" ]; then
  SAVED_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha' 2>/dev/null || true)
  [ -z "$SAVED_HEAD" ] || echo "[speckit-runner] resume branch=$BRANCH head=$SAVED_HEAD"
fi
```

Producer failures keep their normal failed/blocked outcome, but only **after**
Step C. Reviewer failures are different: stop only the reviewer, record review
as unavailable, and continue with the producer checkpoint.

---

## Step 2: speckit.preflight — Pre-flight + Specify

Queue the prompt, then poll per **Step P**: run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"`, re-running it while `POLL_RESULT=running`.

```bash
PROMPT=$(python3 -c "import json,sys; print(json.dumps('You are a worker running inside repo $REPO. Issue: #$0.\n\nPre-Flight (MANDATORY — do this FIRST):\n1. Fetch issue: gh issue view $0 --repo $REPO --json title,body,labels,comments\n2. Check if closed: if CLOSED, emit [pylot] outcome=\"already complete\" status=success and exit.\n3. Verify required labels exist (create '\''in-progress'\'' if missing).\n4. Gather real data: read issue comments, fetch referenced URLs, read existing code patterns.\n\nResume or Specify:\n5. Fetch origin and inspect remote branches whose names identify issue $0. Resume only when exactly one candidate has an existing checkpoint/spec matching this issue; otherwise update the default branch and start clean. Never create or duplicate a PR in this phase.\n6. Bootstrap speckit scaffolding if absent: if [ ! -f \".specify/scripts/bash/create-new-feature.sh\" ]; then /setup-speckit; fi\n7. If the resumed branch already has a valid specification for this issue, continue it. Otherwise run: /speckit-specify $0\n8. Read the generated specification. If there are open questions, answer them from pre-flight data, then run /speckit-clarify.\n9. Set BRANCH=\$(git branch --show-current), commit any completed specification checkpoint, and push the branch.\n\nWhen done: emit [pylot] phase=preflight status=done branch=\$BRANCH head=\$(git rev-parse HEAD)'))")
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
echo "[speckit-runner] preflight prompt queued (turn_seq=$TURN_SEQ)"
```

Poll per **Step P** now — run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"` and **re-run it while `POLL_RESULT=running`**. When it prints `POLL_RESULT=done`, read the printed worker output for `phase=preflight status=done`. If absent or `status=failed`, run Step C and emit a failed outcome.

After a successful preflight, fetch `last_output`, set `BRANCH` from its marker,
and verify the emitted head matches the remote head. Keep `BRANCH` for every later
Step C receipt.

---

## Step 3: speckit.plan — Plan + Tasks

Queue the prompt, then poll per **Step P**: run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"`, re-running it while `POLL_RESULT=running`.

```bash
PROMPT=$(python3 -c "import json; print(json.dumps('Continue on the feature branch from the previous phase.\nRun: /speckit-plan $0\nRead the generated plan and verify the approach.\nRun: /speckit-tasks $0\nRead the generated tasks and verify they are concrete.\nCommit and push the completed planning checkpoint so a later invocation can resume it.\nWhen done: emit [pylot] phase=plan status=done branch=\$(git branch --show-current) head=\$(git rev-parse HEAD)'))")
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
echo "[speckit-runner] plan prompt queued (turn_seq=$TURN_SEQ)"
```

Poll per **Step P** now — run `bash ~/.claude/skills/speckit-runner/poll-worker.sh "$WID" "$TURN_SEQ"` and **re-run it while `POLL_RESULT=running`**. When it prints `POLL_RESULT=done`, check the printed worker output for `phase=plan status=done`. If blocked or failed, run Step C before emitting the blocked/failed outcome.

After success, verify the plan marker's branch and head against the same remote
branch. This proves the resume checkpoint advanced before implementation begins.

---

## Step 4: speckit.implement — Implement + Verify + Checkpoint

The producer implements and pushes a reviewable checkpoint, but **does not open a
PR yet**. Queue this prompt and poll per **Step P**.

```bash
PROMPT=$(python3 -c "import json; print(json.dumps('Continue on the feature branch. Run: /speckit-implement $0\nAfter implementation:\n- Run the repository-defined verification for the affected behavior and fix failures.\n- Exercise the changed behavior through the strongest practical interface available in this repository.\n- Run: /speckit-analyze $0 && /speckit-checklist $0; resolve concrete gaps they find.\n- Commit every intended implementation and specification change, then push the current branch.\n- Do NOT create a PR. This pushed head is the independent-review checkpoint.\nWhen done, emit one marker line: [pylot] phase=implement status=done branch=\$(git branch --show-current) head=\$(git rev-parse HEAD). Then provide a concise CHECKPOINT EVIDENCE block containing the exact verification commands, pass/fail results, behavior exercised, and evidence asset ids or receipts (or explicit N/A).'))")
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "{\"prompt\": $PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
echo "[speckit-runner] implement prompt queued (turn_seq=$TURN_SEQ)"
```

Poll to `done`, then re-fetch the worker output and extract the emitted branch.
Confirm that the remote branch points at the emitted head before continuing.

```bash
PRODUCER_STATE=$(curl -s --max-time 20 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}")
PRODUCER_OUT=$(printf '%s' "$PRODUCER_STATE" | jq -r '.last_output // ""')
BRANCH=$(printf '%s' "$PRODUCER_OUT" | sed -n 's/.*phase=implement status=done branch=\([^ ]*\).*/\1/p' | tail -1)
HEAD_SHA=$(printf '%s' "$PRODUCER_OUT" | sed -n 's/.*phase=implement status=done.* head=\([0-9a-f]*\).*/\1/p' | tail -1)
REMOTE_SHA=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
test -n "$BRANCH" && test "$HEAD_SHA" = "$REMOTE_SHA"
```

If the marker or remote head match is absent, run Step C and report a producer
failure. `CHECKPOINT EVIDENCE` is useful context but is **never** a verification
receipt: a producer may report it, but it cannot establish a passing check.

---

## Step 4.5: Supervisor-Owned Verification Receipts

The operator, not the producer, discovers and executes the expected checks at
the immutable pushed `HEAD_SHA`. Source the bundled helper:

```bash
# The boot sync copies this with the skill. Keep receipts outside the producer
# worktree: the producer must not edit, generate, or attest to this file.
source ~/.claude/skills/speckit-runner/shared/verification-receipts.sh || {
  echo '[speckit-runner] fatal: verification-receipts.sh not found — boot sync may be incomplete' >&2
  exit 1
}
RECEIPT_DIR="${TMPDIR:-/tmp}/speckit-verification-$PYLOT_JOB_ID-$BRANCH"
VR_RECEIPT_FILE="$RECEIPT_DIR/receipts.tsv"
SUPERVISOR_CHECKOUT=$(mktemp -d)
git fetch origin "$BRANCH"
git worktree add --detach "$SUPERVISOR_CHECKOUT" "$REMOTE_SHA"
vr_init "$VR_RECEIPT_FILE" "$REPO" "$REMOTE_SHA"
```

Perform **repository-owned verification discovery** in that detached checkout.
Read the task/spec and the repository's own contributor, agent, build, CI, and
test instructions. Identify every check those sources require for this change.
Do not hardcode a language, framework, conventional filename, or command set in
this shared skill; do not manufacture checks from a producer's `tests pass`
claim. For each expected check, execute the exact discovered command from the
supervisor checkout, not by prompting the producer:

```bash
cd "$SUPERVISOR_CHECKOUT"
# Set these from the repository-owned instructions just read. CHECK_ID is a
# stable check identity; CHECK_COMMAND is the verbatim command from that repo.
CHECK_ID='repository-defined check identity'
CHECK_COMMAND='repository-defined command'
if vr_run "$CHECK_ID" "$CHECK_COMMAND"; then :; fi
```

For a check that cannot be started because its runtime, service, or credential
is unavailable, record the actual limitation rather than guessing a pass:

`vr_record unavailable "$CHECK_ID" "$CHECK_COMMAND" "<specific missing runtime/credential>"`

For a deliberately skipped expected check, use `vr_record not-run ...` with the
reason. A nonzero `vr_run` already writes `failed` with its real exit status;
continue to collect every remaining expected check. Add any evidence URL, log,
or artifact identifier as the third `vr_run` argument or fifth `vr_record`
argument. Before reusing a local receipt during resume, bind it to the live
remote head; a mismatch is visibly stale and must be rerun:

```bash
LIVE_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
if ! vr_bind_current_head "$LIVE_HEAD"; then
  vr_mark_stale "$LIVE_HEAD"
  echo '[speckit-runner] prior verification receipts are stale; rediscovering checks'
  # Create a new receipt set and run the repository-owned checks at LIVE_HEAD.
fi
vr_disclosure >"$RECEIPT_DIR/pr-verification.md"
SUPERVISOR_RECEIPTS=$(cat "$VR_RECEIPT_FILE")
SUPERVISOR_DISCLOSURE=$(cat "$RECEIPT_DIR/pr-verification.md")
```

`passed` is legal only when `vr_run` observed exit status 0. Valid normalized
states are `passed`, `failed`, `not-run`, and `unavailable`; freshness is a
separate current/stale field so stale receipts cannot silently become current.
Keep the receipt and disclosure available to the review, correction, and PR
steps. The session EXIT trap removes the detached worktree on every terminal path.

---

## Step 5: Independent Advisory Review

Spawn a **second LLM worker** in the same repo. It receives the issue, branch,
diff, supervisor receipts, and proposed PR claims — never the producer's
rationale. It starts from a clean checkout; its findings are advisory.

```bash
FIRST_REVIEW_STATUS="unavailable"
REVIEW_OUT="Independent review unavailable: reviewer did not start."
REVIEW_SPAWN=$(curl -s --max-time 90 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "{\"repo\": \"$REPO\"}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers")
RWID=$(printf '%s' "$REVIEW_SPAWN" | jq -r '.worker_id // empty')
if [ -n "$RWID" ]; then
REVIEW_PROMPT=$(BRANCH="$BRANCH" SUPERVISOR_RECEIPTS="$SUPERVISOR_RECEIPTS" SUPERVISOR_DISCLOSURE="$SUPERVISOR_DISCLOSURE" python3 -c "import json,os; print(json.dumps('Independently review issue #$0 in $REPO and the pushed branch ' + os.environ['BRANCH'] + '. Start from a clean checkout. Read the issue and repository guidance, compare the branch with its merge base, inspect the changed behavior, and assess the proposed PR claims below. Do not edit, commit, push, or create a PR.\n\nLook for correctness gaps, incomplete requirements, weak or misleading verification, security or data-integrity risks, maintainability regressions, and user-facing or operational consequences. Apply repository evidence and engineering judgment; do not assume any language, framework, file layout, or test command. Supervisor receipts are observed evidence; cross-check their commands and HEAD binding against the branch.\n\nSUPERVISOR RECEIPTS:\n' + os.environ['SUPERVISOR_RECEIPTS'] + '\n\nPROPOSED PR VERIFICATION DISCLOSURE:\n' + os.environ['SUPERVISOR_DISCLOSURE'] + '\n\nReturn concise suggestions with: priority, concern, concrete evidence, and suggested action. Separate high-value corrections from optional polish. Findings are advisory: never block or fail the mission solely because you found them. End with [pylot] phase=independent-review status=done actionable=yes|no.'))")
REVIEW_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "{\"prompt\": $REVIEW_PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}/prompt")
REVIEW_SEQ=$(printf '%s' "$REVIEW_RESP" | jq -r '.turn_seq // empty')
if [ -z "$REVIEW_SEQ" ]; then
  REVIEW_OUT="Independent review unavailable: reviewer prompt was not accepted."
  curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}/stop" >/dev/null 2>&1 || true
  RWID=""
fi
fi
```

When `RWID` exists, poll with the dedicated bounded helper — **not Step P**:

```bash
bash ~/.claude/skills/speckit-runner/poll-reviewer.sh "$RWID" "$REVIEW_SEQ"
```

Re-run only while its last line is `REVIEW_POLL_RESULT=running`. Each call is
short and the cumulative review ceiling is 15 minutes. `done` permits the output
check below. `unavailable` means the helper already stopped the reviewer: set
`REVIEW_OUT` to an unavailable reason, keep `FIRST_REVIEW_STATUS=unavailable`,
set `RWID=""` because the helper stopped it, and continue to Step 6. Never route a reviewer result through Step P's producer
failure/mission-stop behavior.

```bash
if [ -n "$RWID" ]; then
  REVIEW_STATE=$(curl -s --max-time 20 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}")
  REVIEW_OUT=$(printf '%s' "$REVIEW_STATE" | jq -r '.last_output // ""')
  if printf '%s' "$REVIEW_OUT" | grep -q 'phase=independent-review status=done'; then
    FIRST_REVIEW_STATUS="available"
  else
    FIRST_REVIEW_STATUS="unavailable"
    REVIEW_OUT="Independent review unavailable: reviewer returned no valid completion marker."
    curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
      "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}/stop" >/dev/null 2>&1 || true
    RWID=""
  fi
fi
```

---

## Step 6: One Producer Correction Pass

Send the independent suggestions to the producer exactly once. The producer must
record what it changed and why it declined anything; it must not loop indefinitely.

```bash
CORRECTION_PROMPT=$(REVIEW_OUT="$REVIEW_OUT" python3 -c "import json,os; print(json.dumps('''This is the one bounded correction pass before PR creation. Independently assess the review suggestions below against the issue and repository. Implement the high-value valid corrections; decline inapplicable or disproportionate suggestions with a concrete reason. Re-run the repository-defined verification plus /speckit-analyze $0 and /speckit-checklist $0, commit any changes, and push the branch. Do not create a PR yet. Emit [pylot] phase=correction status=done branch=\$(git branch --show-current) head=\$(git rev-parse HEAD), followed by a concise CORRECTION SUMMARY that lists each suggestion as resolved or declined with rationale and records the latest verification results.

INDEPENDENT REVIEW:
''' + (os.environ.get('REVIEW_OUT') or 'Review unavailable; verify the checkpoint yourself and report that independent review evidence was unavailable.'))) ")
CORRECTION_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "{\"prompt\": $CORRECTION_PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(printf '%s' "$CORRECTION_RESP" | jq -r '.turn_seq // empty')
```

Poll the producer to `done`. This is the only correction pass even if suggestions
remain. Capture and validate its receipt:

```bash
CORRECTION_STATE=$(curl -s --max-time 20 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}")
CORRECTION_OUT=$(printf '%s' "$CORRECTION_STATE" | jq -r '.last_output // ""')
if ! printf '%s' "$CORRECTION_OUT" | grep -q 'phase=correction status=done' \
  || ! printf '%s' "$CORRECTION_OUT" | grep -q 'CORRECTION SUMMARY'; then
  CORRECTION_VALID="no"
else
  CORRECTION_HEAD=$(printf '%s' "$CORRECTION_OUT" | sed -n 's/.*phase=correction status=done.* head=\([0-9a-f]*\).*/\1/p' | tail -1)
  CORRECTION_REMOTE_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha' 2>/dev/null || true)
  if [ -n "$CORRECTION_HEAD" ] && [ "$CORRECTION_HEAD" = "$CORRECTION_REMOTE_HEAD" ]; then
    CORRECTION_VALID="yes"
  else
    CORRECTION_VALID="no"
  fi
fi
```

If `CORRECTION_VALID=no`, run Step C, then emit the producer failure with the
saved branch receipt. Do not proceed to review or PR creation.

---

## Step 6.5: Rebind Verification After Correction

The correction may have pushed a new HEAD. Never carry a `passed` result across
that boundary. Compare the supervisor receipt to the current remote head; on a
mismatch, retain a visibly stale copy for disclosure and create a fresh receipt
set by repeating Step 4.5's repository-owned discovery and supervisor execution
at `CORRECTION_HEAD`.

```bash
if ! vr_bind_current_head "$CORRECTION_HEAD"; then
  vr_mark_stale "$CORRECTION_HEAD"
  STALE_RECEIPT_FILE="$RECEIPT_DIR/stale-${VR_HEAD_SHA}.tsv"
  STALE_DISCLOSURE_FILE="$RECEIPT_DIR/stale-${VR_HEAD_SHA}.md"
  cp "$VR_RECEIPT_FILE" "$STALE_RECEIPT_FILE"
  vr_disclosure >"$STALE_DISCLOSURE_FILE"
  STALE_SUPERVISOR_RECEIPTS=$(cat "$STALE_RECEIPT_FILE")
  STALE_SUPERVISOR_DISCLOSURE=$(cat "$STALE_DISCLOSURE_FILE")
  echo '[speckit-runner] correction moved HEAD; earlier supervisor receipts are stale'
  cleanup_supervisor_checkout
  SUPERVISOR_CHECKOUT=$(mktemp -d)
  FRESH_RECEIPT_DIR="$RECEIPT_DIR/head-$CORRECTION_HEAD"
  VR_RECEIPT_FILE="$FRESH_RECEIPT_DIR/receipts.tsv"
  FRESH_DISCOVERY_FILE="$FRESH_RECEIPT_DIR/discovered-checks.txt"
  git fetch origin "$BRANCH"
  git worktree add --detach "$SUPERVISOR_CHECKOUT" "$CORRECTION_HEAD"
  vr_init "$VR_RECEIPT_FILE" "$REPO" "$CORRECTION_HEAD"
  cd "$SUPERVISOR_CHECKOUT"
  # Repeat Step 4.5 discovery here. Write each discovered CHECK_ID and exact
  # CHECK_COMMAND to FRESH_DISCOVERY_FILE, then call vr_run or vr_record.
  : >"$FRESH_DISCOVERY_FILE"
  # printf '%s\t%s\n' "$CHECK_ID" "$CHECK_COMMAND" >>"$FRESH_DISCOVERY_FILE"
  # if vr_run "$CHECK_ID" "$CHECK_COMMAND"; then :; fi
  if [ ! -s "$FRESH_DISCOVERY_FILE" ] || ! vr_has_records_for_head "$CORRECTION_HEAD"; then
    echo '[speckit-runner] correction-head verification was not freshly discovered and recorded' >&2
    exit 1
  fi
fi
vr_has_records_for_head "$CORRECTION_HEAD" || {
  echo '[speckit-runner] no current receipt recorded for correction head' >&2
  exit 1
}
SUPERVISOR_RECEIPTS=$(cat "$VR_RECEIPT_FILE")
SUPERVISOR_DISCLOSURE=$(vr_disclosure)
```

If fresh checks are failed, not-run, or unavailable, continue. Their exact
states must remain in the final disclosure; none are PR-creation blockers.

---

## Step 7: Optional Final Advisory Review

If the first review reported `actionable=yes` or the correction changed the
pushed head, prompt the reviewer once more to inspect the updated remote head.
Ask only which original concerns are resolved and which suggestions remain. Do
not start another producer correction pass. If the first review had no actionable
suggestions, set `RESIDUAL_REVIEW="No residual suggestions."` and skip this turn.

The final review remains advisory. Persist residual suggestions for disclosure;
never convert them into a mission blocker merely because they remain.

```bash
RUN_FINAL_REVIEW="no"
if printf '%s' "$REVIEW_OUT" | grep -q 'actionable=yes' \
  || { [ -n "${CORRECTION_HEAD:-}" ] && [ "$CORRECTION_HEAD" != "$HEAD_SHA" ]; }; then
  RUN_FINAL_REVIEW="yes"
fi

if [ "$FIRST_REVIEW_STATUS" = "available" ] && [ -n "$RWID" ] \
  && [ "$RUN_FINAL_REVIEW" = "yes" ]; then
  FINAL_REVIEW_PROMPT=$(CORRECTION_OUT="$CORRECTION_OUT" SUPERVISOR_DISCLOSURE="$SUPERVISOR_DISCLOSURE" python3 -c "import json,os; print(json.dumps('Re-fetch branch $BRANCH and review its updated diff for issue #$0. Reassess only the independent suggestions from your prior turn against the producer correction summary and the current supervisor verification disclosure. Report which are resolved and which remain, with concise evidence. Do not edit, push, or create a PR. Remaining suggestions are advisory. End with [pylot] phase=final-review status=done.\n\nPRODUCER CORRECTION RECEIPT:\n' + os.environ['CORRECTION_OUT'] + '\n\nCURRENT SUPERVISOR VERIFICATION DISCLOSURE:\n' + os.environ['SUPERVISOR_DISCLOSURE']))")
  FINAL_REVIEW_RESP=$(curl -s --max-time 30 -X POST \
    -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
    -d "{\"prompt\": $FINAL_REVIEW_PROMPT}" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}/prompt")
  REVIEW_SEQ=$(printf '%s' "$FINAL_REVIEW_RESP" | jq -r '.turn_seq // empty')
  if [ -z "$REVIEW_SEQ" ]; then
    RESIDUAL_REVIEW="Final advisory review unavailable: prompt was not accepted."
    curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
      "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}/stop" >/dev/null 2>&1 || true
    RWID=""
  fi
else
  RESIDUAL_REVIEW="No final review run: first review unavailable or had no actionable suggestions."
  if [ -n "${RWID:-}" ]; then
    curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
      "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}/stop" >/dev/null 2>&1 || true
    RWID=""
  fi
fi
```

When `REVIEW_SEQ` exists, use `poll-reviewer.sh` again and re-run it only while
`REVIEW_POLL_RESULT=running`. On `unavailable`, set a concise unavailable reason,
clear `RWID`, and continue. On `done`, fetch output and accept it only when it
contains `phase=final-review status=done`; otherwise mark it unavailable. Stop the
reviewer immediately after capturing a valid final output. This wait has the same
15-minute cumulative ceiling and can never fail the mission.

```bash
if [ -n "${RWID:-}" ] && [ -n "${REVIEW_SEQ:-}" ]; then
  FINAL_REVIEW_STATE=$(curl -s --max-time 20 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}")
  FINAL_REVIEW_OUT=$(printf '%s' "$FINAL_REVIEW_STATE" | jq -r '.last_output // ""')
  if printf '%s' "$FINAL_REVIEW_OUT" | grep -q 'phase=final-review status=done'; then
    RESIDUAL_REVIEW="$FINAL_REVIEW_OUT"
  else
    RESIDUAL_REVIEW="Final advisory review unavailable: no valid completion marker."
  fi
  curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${RWID}/stop" >/dev/null 2>&1 || true
  RWID=""
fi
```

---

## Step 8: Create the Sole PR

Send the producer the final advisory record. This is the **only PR creation
boundary** in the pipeline.

```bash
PR_PROMPT=$(SUPERVISOR_DISCLOSURE="$SUPERVISOR_DISCLOSURE" STALE_SUPERVISOR_DISCLOSURE="${STALE_SUPERVISOR_DISCLOSURE:-}" FIRST_REVIEW_STATUS="$FIRST_REVIEW_STATUS" REVIEW_OUT="$REVIEW_OUT" CORRECTION_OUT="$CORRECTION_OUT" RESIDUAL_REVIEW="$RESIDUAL_REVIEW" python3 -c "import json,os; print(json.dumps('''Create the single PR for issue #$0 from the already-pushed branch. First confirm the worktree is clean and the remote head matches local HEAD. Invoke /create-compelling-prs and use that skill to compose and open the PR — do not substitute a placeholder template.

Copy the supervisor-owned verification disclosure below verbatim into the PR. It is authoritative over any producer claim: explicitly disclose every passed, failed, not-run, or unavailable state and never state or imply readiness when any current check is failed, not-run, or unavailable. If a correction moved the head, also include the stale-receipt disclosure so it is clear those results were not reused. Include an Independent review section summarizing first-review availability, suggestions, corrected/declined decisions, and residual or unavailable final review. Review suggestions and verification failures are transparent advisory context, not a reason to suppress the PR. Emit [pylot] phase=pr status=done pr=<PR_URL>.

CURRENT SUPERVISOR VERIFICATION DISCLOSURE:
''' + os.environ['SUPERVISOR_DISCLOSURE'] + '''

STALE SUPERVISOR RECEIPTS (include only when non-empty):
''' + os.environ.get('STALE_SUPERVISOR_DISCLOSURE', '') + '''

FIRST REVIEW STATUS:
''' + os.environ['FIRST_REVIEW_STATUS'] + '''

FIRST REVIEW:
''' + os.environ['REVIEW_OUT'] + '''

PRODUCER CORRECTION SUMMARY:
''' + os.environ['CORRECTION_OUT'] + '''

FINAL ADVISORY REVIEW:
''' + (os.environ.get('RESIDUAL_REVIEW') or 'Final advisory review unavailable.'))) ")
PR_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "{\"prompt\": $PR_PROMPT}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(printf '%s' "$PR_RESP" | jq -r '.turn_seq // empty')
```

Poll the producer to `done`, find the PR URL in its output, and confirm with
`gh pr view` that its head branch and issue linkage match this run. Confirm the
body contains the exact current supervisor disclosure; a producer's summary is
not a substitute.
Any producer prompt, poll, marker, or reconciliation failure runs Step C before
emitting its terminal outcome.

```bash
ISSUE_NUMBER="$0"
source ~/.claude/skills/speckit-runner/shared/pr-postcondition.sh || {
  echo '[speckit-runner] fatal: pr-postcondition.sh not found — boot sync may be incomplete' >&2
  exit 1
}
verify_pr_postcondition || { echo '[speckit-runner] PR postcondition failed' >&2; exit 1; }
```

---

## Step 9: Cleanup + Emit Outcome

Run Step C unconditionally, then report the PR and independent-review availability.
If the PR exists, residual or unavailable suggestions produce `status=success`,
not `failed` or `blocked`.

```bash
# Run the Step C snippet first. The session EXIT trap removes
# SUPERVISOR_CHECKOUT on this and every other terminal path.

if [ -n "$PR_NUM" ]; then
  echo "[pylot] outcome=\"speckit complete: PR #$PR_NUM opened; independent_review=$FIRST_REVIEW_STATUS\" status=success"
else
  echo "[pylot] outcome=\"verified checkpoint exists but no PR URL was confirmed — check worker output\" status=partial"
fi
```

---

## Hard Rules

- **Pre-flight is mandatory** — the worker must gather real data before speckit phases
- **Poll only via the scripts** — producer turns use `poll-worker.sh`; reviewer turns use bounded `poll-reviewer.sh`. Both return in <2 min per call. Never hand-roll a loop, pass a long Bash timeout, background a poll, wait for a notification, or end the operator turn while a worker turn is in flight.
- **Never stop a healthy worker on a timer** — `block_elapsed` is a checkpoint, not a failure. Only stop a worker when its heartbeat is stale (> ~10 min) or it reported a failure; never on elapsed time or empty mid-turn output alone. The script alone enforces the hard ceiling.
- **Cleanup always runs** — every terminal path runs Step C; reviewer unavailability stops that reviewer immediately and continues
- **External dispatch remains fire-and-forget** — foreground polling is internal mission execution, not a reason for the dispatcher to babysit the mission
- **Review in clean context** — the producer never reviews its own checkpoint; the reviewer never edits it
- **Supervisor owns verification** — discover commands only from the task and
  repository-owned instructions, execute them in the detached supervisor
  checkout, and preserve their HEAD-bound receipts. Producer prose can never
  create a passed receipt.
- **Repository trust boundary** — `/speckit-runner` must only be used against
  repositories whose contributor, agent, and CI instruction files are trusted to
  the same degree as the dispatch token. `vr_run` executes repository-discovered
  commands inside the supervisor session (holds `$PYLOT_DISPATCH_TOKEN`,
  `$PYLOT_API`, and `gh` credentials); a hostile or compromised instruction file
  in the target repository can exfiltrate those credentials.
- **Suggestions never gate** — allow one producer correction pass, disclose anything residual, and continue to the PR boundary
- **PR creation happens once and last** — verification, analyze/checklist, checkpoint push, and advisory review all precede `/create-compelling-prs`
- **Emit the outcome marker** — `[pylot] outcome=... status=` is mandatory before exiting
- **"already complete" only at the dedup gate** — only emit this when the issue is genuinely CLOSED (Step 0); never for timeouts or missing notifications
- **One task, one PR** — do not scope-creep into adjacent issues
