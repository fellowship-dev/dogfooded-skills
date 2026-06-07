# Stage 06: Notify + Release Environment (subagent)

## Inputs
- `.procedure-output/release-train-runner/00-claim-compute/handoff.md`
  (provider, ENV_ID/CS_NAME, REMOTE_EXEC, REPO_DIR, DEFAULT_BRANCH, REPO)
- `.procedure-output/release-train-runner/03-validate-integrate/handoff.md` (included/skipped counts, conflicts)
- `.procedure-output/release-train-runner/05-push-release-pr/handoff.md` (release PR URL, branch)

## Task
Write the async notification trigger, then release/stop the remote compute. **NO QUEST** — the
trigger file is the only notification sink here; the local report (stage 07) is the durable record.

## Steps

1. Write the async notification trigger (for moonlighter / Telegram dispatch):
```bash
QUEUE_DIR="$HOME/.local/share/pylot/queue"
TRIGGER_FILE="$QUEUE_DIR/release-train_$(date +%s)_$RANDOM.trigger"
cat > "$TRIGGER_FILE" <<TRIGGER
header: 🚂 /release-train-runner
report: inline
---
🚂 Release train ready for $REPO
$N PRs merged into $RELEASE_BRANCH. $M conflicts resolved, tests green.
Review: $PR_URL
TRIGGER
```

2. Release the remote compute so it stops billing:
```bash
# Ona
$REMOTE_EXEC "cd $REPO_DIR && git checkout $DEFAULT_BRANCH"
gitpod environment stop $ENV_ID

# Codespaces (retention-period handles auto-delete)
gh cs stop -c "$CS_NAME"
```
   Use the branch matching the provider recorded in the stage 00 handoff.

3. Write handoff.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/06-release-env/handoff.md`

```markdown
# Stage 06: Notify + Release Env

## Status
teardown_ok: {true|false}

## Notification
- Trigger file: {path written or "skipped — not async"}

## Compute
- Provider: {ona|codespaces}
- Handle: {ENV_ID|CS_NAME}
- Action: {stopped / auto-delete via retention}
```

## Success criteria
- Async trigger written (or explicitly skipped if not running async)
- Remote compute stopped/released
- No Quest call made anywhere

## Failure
- Compute fails to stop → `teardown_ok: false`, document the dangling env so it can be cleaned
  up manually. This is non-fatal: the train already succeeded — note it and continue to stage 07.
