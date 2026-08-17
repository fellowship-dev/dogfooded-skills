#!/usr/bin/env bash
# poll-reviewer.sh <WID> <TURN_SEQ>
#
# Bounded advisory-review polling. Re-run while REVIEW_POLL_RESULT=running.
# Every reviewer failure becomes REVIEW_POLL_RESULT=unavailable; it never applies
# producer-turn failure semantics to the mission.
set -u
WID="${1:?usage: poll-reviewer.sh <WID> <TURN_SEQ>}"
TURN_SEQ="${2:?usage: poll-reviewer.sh <WID> <TURN_SEQ>}"
DIR=$(cd "$(dirname "$0")" && pwd)

OUT=$(PYLOT_WORKER_POLL_BLOCK=900 PYLOT_WORKER_POLL_CEILING=900 \
  bash "$DIR/poll-worker.sh" "$WID" "$TURN_SEQ" 2>&1)
RC=$?
printf '%s\n' "$OUT"

if printf '%s' "$OUT" | grep -q 'POLL_RESULT=done worker_exit=0'; then
  echo "REVIEW_POLL_RESULT=done"
  exit 0
fi
if printf '%s' "$OUT" | grep -Eq 'state=(error|reaped|stopped)'; then
  RC=1
fi
if [ "$RC" -eq 10 ] && printf '%s' "$OUT" | grep -q 'POLL_RESULT=running'; then
  echo "REVIEW_POLL_RESULT=running"
  exit 10
fi

# The base helper already stops at its ceiling. Stop again for every other
# runtime/transport result so cleanup is deterministic and idempotent.
curl -s --max-time 20 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
echo "REVIEW_POLL_RESULT=unavailable"
exit 0
