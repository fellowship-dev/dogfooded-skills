---
name: pylot-workers
description: Worker API reference for operator skills that drive repo devbox workers. Documents spawn → prompt → poll → stop lifecycle. Not a runnable skill — imported as a baseline into every operator so worker-driving skills can reference it.
user-invocable: false
---

# pylot-workers — Worker API Reference

Every operator has this skill loaded as a baseline. Worker-driving skills
(`speckit-runner`, `deps-runner-proc`, `release-train-runner-proc`) use these
endpoints to spawn and drive a repo devbox worker via the gateway.

All calls require `Authorization: Bearer $PYLOT_DISPATCH_TOKEN`.
Gateway base: `$PYLOT_API` (or `$PYLOT_GATEWAY_URL`).
Mission ID: `$PYLOT_JOB_ID`.

---

## 1. Spawn a worker

```bash
SPAWN_RESP=$(curl -s --max-time 90 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"repo\": \"$REPO\"}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers")
WID=$(echo "$SPAWN_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))' 2>/dev/null)
```

Returns `{"ok": true, "worker_id": <number>}` (201) or an error body.
`WID` is the worker row id used in all subsequent calls.

---

## 2. Queue a prompt

```bash
PROMPT_RESP=$(curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": \"$PROMPT\"}" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/prompt")
TURN_SEQ=$(echo "$PROMPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))' 2>/dev/null)
```

Returns `{"ok": true, "turn_seq": <number>}` (202) or 409 if the worker is busy.
Always capture `turn_seq` — it's the handle for polling.

---

## 3. Poll to idle

Poll until `turn_state == "idle"` AND `turn_seq == TURN_SEQ`.

```bash
WORKER_EXIT=""; POLL_EL=0; POLL_MAX="${PYLOT_WORKER_POLL_MAX:-2400}"
while [ "$POLL_EL" -lt "$POLL_MAX" ]; do
  sleep 15; POLL_EL=$((POLL_EL + 15))
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
done
```

`last_output` in the final `$ST` response contains the worker's turn output (capped at 16 KB tail).
The executor stale-turn reaper sets `exit_code=-1` if the devbox dies mid-turn, so this never
hangs past the reaper window.

---

## 4. Stop the worker

```bash
curl -s --max-time 30 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
```

Idempotent. Always call stop when the skill is done — even if the turn failed.
The harvest backstop also stops workers, but explicit stop is faster and cheaper.

---

## Drive loop pattern

```
spawn → prompt(phase1) → poll-to-idle → check output →
        prompt(phase2) → poll-to-idle → check output →
        ...
        stop → emit [pylot] outcome= marker
```

Between phases, read `last_output` from the final poll response to detect
phase-level failures before sending the next prompt.

Emit the outcome marker AFTER stopping the worker:
```
[pylot] outcome="<summary>" status=<success|partial|failed|blocked>
```
