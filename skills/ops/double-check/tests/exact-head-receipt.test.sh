#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../shared/exact-head-receipt.sh
source "$ROOT/shared/exact-head-receipt.sh"

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
FIXTURE="$ROOT/tests/fixtures/pr-3179-stage03-to-stage04.json"

assert_eq() {
  local expected=$1 actual=$2 scenario=$3
  [ "$expected" = "$actual" ] || {
    printf 'FAIL %s: expected %s, got %s\n' "$scenario" "$expected" "$actual" >&2
    exit 1
  }
  printf 'PASS %s\n' "$scenario"
}

# Unchanged head: one reviewed receipt may promote.
assert_eq promote "$(dc_exact_head_decision "$A" "$A" 0)" unchanged-head
# PR #3179 replay: its stale A receipt cannot promote; B receives exactly one clean restart.
assert_eq restart "$(dc_exact_head_decision "$A" "$B" 0)" stage03-to-stage04-concurrent-push
# A second move exhausts the one-restart budget; callers must write a blocked receipt only.
assert_eq blocked "$(dc_exact_head_decision "$B" "$C" 1)" second-moving-head
# Remote-read failure / malformed data is fail-closed and cannot reach mutations.
assert_eq blocked "$(dc_exact_head_decision "$B" unavailable 0)" unavailable-live-head
assert_eq blocked "$(dc_exact_head_decision short "$B" 0)" malformed-reviewed-head

# A hermetic Stage 04 mutation model: only promote reaches the verdict/label/downstream paths.
simulate_post() {
  local reviewed=$1 live=$2 restart=$3 comment=${4:-}
  case "$(dc_exact_head_decision "$reviewed" "$live" "$restart")" in
    promote) printf 'verdict,label,double-checked,downstream\n' ;;
    restart) printf 'restart:%s;review-input:%s\n' "$live" "$comment" ;;
    blocked) printf 'blocked;no-label;no-downstream\n' ;;
  esac
}

assert_eq 'verdict,label,double-checked,downstream' "$(simulate_post "$A" "$A" 0)" unchanged-head-one-promotion
INCIDENT_REVIEWED=$(jq -r '.reviewed_head_sha' "$FIXTURE")
INCIDENT_LIVE=$(jq -r '.live_head_sha' "$FIXTURE")
INCIDENT_COMMENT=$(jq -r '.new_comment' "$FIXTURE")
assert_eq "restart:$INCIDENT_LIVE;review-input:$INCIDENT_COMMENT" \
  "$(simulate_post "$INCIDENT_REVIEWED" "$INCIDENT_LIVE" 0 "$INCIDENT_COMMENT")" incident-restarts-with-new-blocker
assert_eq 'blocked;no-label;no-downstream' "$(simulate_post "$B" "$C" 1)" second-move-no-side-effects
assert_eq 'blocked;no-label;no-downstream' "$(simulate_post "$B" unavailable 0)" read-failure-no-side-effects
# Re-delivery uses the same terminal state, so it cannot create a new restart or label mutation.
assert_eq 'blocked;no-label;no-downstream' "$(simulate_post "$B" "$C" 1)" terminal-replay-dedupes

# The procedure itself must place the gate before the approval path and document a live recheck
# at each mutation boundary. These assertions prevent a prose-only regression from reintroducing
# the PR #3179 stale-receipt promotion race.
POST_CONTEXT="$ROOT/stages/04-post/CONTEXT.md"
assert_contains() {
  local needle=$1 scenario=$2
  rg -Fq "$needle" "$POST_CONTEXT" || {
    printf 'FAIL %s: missing %s\n' "$scenario" "$needle" >&2
    exit 1
  }
  printf 'PASS %s\n' "$scenario"
}
assert_contains 'DECISION=$(dc_exact_head_decision' live-head-gate-is-executable
assert_contains 'if [ "$DECISION" = restart ]; then' stale-receipt-restarts
assert_contains 'if [ "$DECISION" = blocked ]; then' second-move-fails-closed
assert_contains 'Immediately before every `gh pr edit` / `gh label` mutation' labels-recheck-live-head
assert_contains 'fetch `headRefOid,comments` once more and re-run' comment-rechecks-live-head
printf 'PASS exact-head receipt gate\n'
