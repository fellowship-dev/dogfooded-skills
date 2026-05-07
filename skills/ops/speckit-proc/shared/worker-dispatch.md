# Worker Dispatch

Standard pattern for operator stages that interact with the worker.

## First Spawn (Stage 02)

```bash
WORKER_SESSION=$(uuidgen)
HANDLE=$(bash scripts/spawn-worker.sh "$ENV" "$JOB_ID" "$WORKER_SESSION" "$REPO_DIR" "$PROMPT" "$MODEL")
bash scripts/wait-for-worker.sh "$ENV" "$HANDLE" "$JOB_ID" "$WORKER_SESSION"
```

Save `$WORKER_SESSION` in the handoff file -- all subsequent stages resume this session.

## Resume (Stages 03-07)

Read `$WORKER_SESSION` from the prior stage's handoff, then:

```bash
HANDLE=$(bash scripts/spawn-worker.sh "$ENV" "$JOB_ID" "$WORKER_SESSION" "$REPO_DIR" "$PROMPT" "$MODEL" --resume)
bash scripts/wait-for-worker.sh "$ENV" "$HANDLE" "$JOB_ID" "$WORKER_SESSION"
```

The worker carries forward all context from prior phases because `--resume` continues the Claude Code session.

## Wait Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Worker completed | Read log, write handoff |
| 1 | Worker errored | Read log tail, report failure |
| 2 | Stalled (9 min no output) | Retry with adjusted prompt (max 3 attempts) |

## Stall Recovery

On exit 2:
1. Read last 30 lines of worker log
2. Adjust prompt to address where the worker stalled
3. Resume same session with adjusted prompt
4. After 3 failed attempts: emit `[pylot] outcome="stalled" status=failed`

## Worker Log

```
$DISPATCH_DIR/running/${JOB_ID}.workers/${WORKER_SESSION}.log
```

Read the tail after each wait to extract: file paths created, phase outcomes, errors.

## Starting / Stopping the Worker Environment

Before stage 02, start the environment if a health gate is configured:
```bash
/start-worker
```

After stage 07 (or on failure), stop it:
```bash
/stop-worker
```
