# Self-Wake & Auto-Wake

## Auto-Wake (preferred)

Pass `context.conversation_id` at dispatch — auto-wake fires automatically when the mission completes and on PR lifecycle events. No manual scheduling needed. See [Dispatch](dispatch.md).

## Self-Wake (manual timing)

Use when you need a timed check-in independent of mission state (e.g. polling without auto-wake, or scheduling a follow-up):

```bash
CONV_ID=$(ls /tmp/claude-home/.claude/session-env/ | head -1)
curl -sS -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"in_seconds": 300, "content": "Check mission <job_id> status"}' \
  "$PYLOT_GATEWAY_URL/conversations/$CONV_ID/wakes"
```

`in_seconds` >= 60. Wakes are one-off — if the condition is not yet met, schedule exactly one more before returning. Do not stop monitoring silently.

## Timing Guide

| Waiting for | Recommended delay |
|---|---|
| PR to open (simple — few lines) | 5–8 min (300–480 s) |
| PR to open (moderate task) | 8–15 min (480–900 s) |
| PR to open (complex — new feature) | 15–25 min (900–1500 s) |
| PR merge after it is open | 5–10 min (300–600 s) |

Before rescheduling: check the last log line. If the worker is still "pending" or "provisioning", add 2–3 min to your interval.

## Wake Event Payloads

When `context.conversation_id` is passed at dispatch, two wake types fire per mission:

**Mission terminal wake** — fires when mission reaches `done`, `failed`, `cancelled`, or `timeout`:
```json
{
  "ts": "...",
  "job_id": "...",
  "agent": "infra.lead",
  "new_status": "done",
  "old_status": "running",
  "cost_usd": 2.99,
  "exit_code": 0,
  "duration_s": 630,
  "task_preview": "..."
}
```

**PR lifecycle wake** — fires when a PR containing `Closes #N` is opened or merged:
```json
{
  "event": "pr_opened",
  "repo": "fellowship-dev/pylot",
  "pr_number": 629,
  "pr_url": "https://github.com/fellowship-dev/pylot/pull/629",
  "pr_title": "...",
  "merged": false
}
```

Events: `pr_opened`, `pr_merged`, `pr_closed`. Both wakes require the `mission_conversations` link — created only when `context.conversation_id` is passed at dispatch. There is no separate subscription mechanism.
