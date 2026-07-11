#!/usr/bin/env bash
# poll-worker.sh <WID> <TURN_SEQ>
#
# ONE bounded poll chunk (~85s wall — under the operator harness's default 120s Bash
# timeout, so it can NEVER be auto-backgrounded). The operator runs it, reads the
# result, and runs it again while RUNNING. The dumb wait lives here, not in the LLM.
#
#   exit 0  -> POLL_RESULT=done            (worker idle on this turn; last_output printed)
#   exit 10 -> POLL_RESULT=running         (worker healthy, still working — RUN AGAIN)
#   exit 20 -> POLL_RESULT=block_elapsed   (a poll block expired; worker NOT stopped.
#                                           A decision packet is printed: heartbeat age,
#                                           output_changed flag, log tail. Re-run this
#                                           script to grant another block, or POST
#                                           /workers/<WID>/stop yourself to give up.)
#   exit 1  -> POLL_RESULT=ceiling_timeout (hard ceiling hit; worker stopped)
#
# Cumulative elapsed is persisted across calls in a per-(job,worker,turn) state file,
# so re-running resumes the overall clock instead of restarting it. The script never
# stops a worker at a block boundary — only the operator decides that. The only
# script-initiated stop is at the hard ceiling.
#
# Env: PYLOT_API, PYLOT_JOB_ID, PYLOT_DISPATCH_TOKEN (from the operator runtime).
# Tunables: PYLOT_WORKER_POLL_CHUNK   (default 85    — wall-seconds per call; keep < 120)
#           PYLOT_WORKER_POLL_BLOCK   (default 1800  — seconds per decision block)
#           PYLOT_WORKER_POLL_CEILING (default 14400 — hard cap across all blocks this turn)
set -u
WID="${1:?usage: poll-worker.sh <WID> <TURN_SEQ>}"
TURN_SEQ="${2:?usage: poll-worker.sh <WID> <TURN_SEQ>}"
: "${PYLOT_API:?}"; : "${PYLOT_JOB_ID:?}"; : "${PYLOT_DISPATCH_TOKEN:?}"
CHUNK="${PYLOT_WORKER_POLL_CHUNK:-85}"          # wall-seconds per call; keep < 120
BLOCK="${PYLOT_WORKER_POLL_BLOCK:-1800}"        # seconds per decision block
CEILING="${PYLOT_WORKER_POLL_CEILING:-14400}"   # hard cap across all blocks this turn
STATE="/tmp/speckit_poll_${PYLOT_JOB_ID}_${WID}_${TURN_SEQ}.el"
TOTAL=$(sed -n 1p "$STATE" 2>/dev/null); [ -z "$TOTAL" ] && TOTAL=0
PREV_HASH=$(sed -n 2p "$STATE" 2>/dev/null); [ -z "$PREV_HASH" ] && PREV_HASH="-"
BLOCK_END=$(( (TOTAL / BLOCK + 1) * BLOCK ))
[ "$BLOCK_END" -gt "$CEILING" ] && BLOCK_END="$CEILING"
SECONDS=0; W_STATE="-"; W_SEQ="-"; W_EC="-"; ST=""
while [ "$SECONDS" -lt "$CHUNK" ] && [ "$((TOTAL + SECONDS))" -lt "$BLOCK_END" ]; do
  sleep 8
  ST=$(curl -s --max-time 12 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}")
  LINE=$(printf '%s' "$ST" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
ec = d.get("last_exit_code")
print("%s %s %s" % (d.get("turn_state","-"), d.get("turn_seq","-"), "-" if ec is None else ec))
' 2>/dev/null)
  W_STATE="${LINE%% *}"; REST="${LINE#* }"; W_SEQ="${REST%% *}"; W_EC="${REST##* }"
  [ "$W_STATE" = "idle" ] && [ "$W_SEQ" = "$TURN_SEQ" ] && break
done
# If the loop never fetched (e.g. resumed already past a boundary), fetch once for the packet.
if [ -z "$ST" ]; then
  ST=$(curl -s --max-time 12 -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}")
  LINE=$(printf '%s' "$ST" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
ec = d.get("last_exit_code")
print("%s %s %s" % (d.get("turn_state","-"), d.get("turn_seq","-"), "-" if ec is None else ec))
' 2>/dev/null)
  W_STATE="${LINE%% *}"; REST="${LINE#* }"; W_SEQ="${REST%% *}"; W_EC="${REST##* }"
fi
TOTAL=$((TOTAL + SECONDS))
OUT_HASH=$(printf '%s' "$ST" | python3 -c 'import sys,json,hashlib
try: o = json.load(sys.stdin).get("last_output","") or ""
except Exception: o = ""
print(hashlib.sha256(o.encode()).hexdigest()[:12])' 2>/dev/null); [ -z "$OUT_HASH" ] && OUT_HASH="-"
echo "[poll +${SECONDS}s | total ${TOTAL}s / ceiling ${CEILING}s] state=$W_STATE seq=$W_SEQ"
if [ "$W_STATE" = "idle" ] && [ "$W_SEQ" = "$TURN_SEQ" ]; then
  printf '%s' "$ST" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("last_output","") or "")[-400:])
except Exception: pass' 2>/dev/null
  rm -f "$STATE"; echo "POLL_RESULT=done worker_exit=$W_EC"; exit 0
elif [ "$TOTAL" -ge "$CEILING" ]; then
  rm -f "$STATE"
  printf '%s' "$ST" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("last_output","") or "")[-2000:])
except Exception: pass' 2>/dev/null
  curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
  echo "POLL_RESULT=ceiling_timeout"; exit 1
elif [ "$TOTAL" -ge "$BLOCK_END" ]; then
  # Block boundary: print the decision packet. The worker keeps running — the
  # operator decides (re-run to continue, or POST /stop to give up).
  EMPTY_HASH=$(printf '' | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')
  if [ "$OUT_HASH" = "$EMPTY_HASH" ]; then CHANGED="empty"
  elif [ "$OUT_HASH" = "$PREV_HASH" ]; then CHANGED="no"
  elif [ "$PREV_HASH" = "-" ]; then CHANGED="first-block"
  else CHANGED="yes"; fi
  printf '%s' "$ST" | python3 -c 'import sys, json, datetime
try: d = json.load(sys.stdin)
except Exception: d = {}
hb = d.get("heartbeat_at")
age = "-"
if hb:
    try:
        t = datetime.datetime.fromisoformat(str(hb).replace("Z", "+00:00"))
        if t.tzinfo is None: t = t.replace(tzinfo=datetime.timezone.utc)  # gateway sends naive UTC
        age = str(int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds())) + "s"
    except Exception: pass
print("heartbeat_age=%s turn_started_at=%s" % (age, d.get("turn_started_at","-")))
out = (d.get("last_output","") or "")[-2000:]
if out:
    print("--- last worker output (tail) ---")
    print(out)
else:
    print("(no output captured yet this turn — last_output fills at turn end; judge health by heartbeat_age)")' 2>/dev/null
  printf '%s\n%s\n' "$TOTAL" "$OUT_HASH" > "$STATE"
  echo "POLL_RESULT=block_elapsed output_changed=$CHANGED total=${TOTAL}s ceiling=${CEILING}s"
  exit 20
else
  printf '%s\n%s\n' "$TOTAL" "$PREV_HASH" > "$STATE"
  echo "POLL_RESULT=running"; exit 10
fi
