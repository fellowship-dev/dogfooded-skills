#!/usr/bin/env bash
# poll-worker.sh <WID> <TURN_SEQ>
#
# ONE bounded poll chunk (~85s wall — under the operator harness's default 120s Bash
# timeout, so it can NEVER be auto-backgrounded). The operator runs it, reads the
# result, and runs it again while RUNNING. The dumb wait lives here, not in the LLM.
#
#   exit 0  -> POLL_RESULT=done     (worker idle on this turn; last_output printed)
#   exit 10 -> POLL_RESULT=running  (worker healthy, still working — RUN AGAIN)
#   exit 1  -> POLL_RESULT=timeout  (overall budget hit; worker stopped)
#
# Cumulative elapsed is persisted across calls in a per-(job,worker,turn) state file,
# so re-running resumes the overall budget instead of restarting it.
#
# Env: PYLOT_API, PYLOT_JOB_ID, PYLOT_DISPATCH_TOKEN (from the operator runtime).
# Tunables: PYLOT_WORKER_POLL_CHUNK (default 85), PYLOT_WORKER_POLL_MAX (default 3600).
set -u
WID="${1:?usage: poll-worker.sh <WID> <TURN_SEQ>}"
TURN_SEQ="${2:?usage: poll-worker.sh <WID> <TURN_SEQ>}"
: "${PYLOT_API:?}"; : "${PYLOT_JOB_ID:?}"; : "${PYLOT_DISPATCH_TOKEN:?}"
CHUNK="${PYLOT_WORKER_POLL_CHUNK:-85}"        # wall-seconds per call; keep < 120
POLL_MAX="${PYLOT_WORKER_POLL_MAX:-3600}"     # overall budget across all calls this turn
STATE="/tmp/speckit_poll_${PYLOT_JOB_ID}_${WID}_${TURN_SEQ}.el"
TOTAL=$(cat "$STATE" 2>/dev/null || echo 0); [ -z "$TOTAL" ] && TOTAL=0
SECONDS=0; W_STATE="-"; W_SEQ="-"; W_EC="-"; ST=""
while [ "$SECONDS" -lt "$CHUNK" ] && [ "$((TOTAL + SECONDS))" -lt "$POLL_MAX" ]; do
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
TOTAL=$((TOTAL + SECONDS)); echo "$TOTAL" > "$STATE"
echo "[poll +${SECONDS}s | total ${TOTAL}s] state=$W_STATE seq=$W_SEQ"
printf '%s' "$ST" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("last_output","") or "")[-400:])
except Exception: pass' 2>/dev/null
if [ "$W_STATE" = "idle" ] && [ "$W_SEQ" = "$TURN_SEQ" ]; then
  rm -f "$STATE"; echo "POLL_RESULT=done worker_exit=$W_EC"; exit 0
elif [ "$TOTAL" -ge "$POLL_MAX" ]; then
  rm -f "$STATE"
  curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
    "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
  echo "POLL_RESULT=timeout"; exit 1
else
  echo "POLL_RESULT=running"; exit 10
fi
