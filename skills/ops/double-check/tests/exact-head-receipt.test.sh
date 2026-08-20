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

# Exercise the helper through a fake gh executable. This proves the final decision reads the live
# API response rather than accepting a SHA supplied by a caller.
MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT
mkdir -p "$MOCK_DIR/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$DC_GH_LOG"' 'cat "$DC_GH_RESPONSE"' > "$MOCK_DIR/bin/gh"
chmod +x "$MOCK_DIR/bin/gh"
export DC_GH_LOG="$MOCK_DIR/gh.log"
export DC_GH_RESPONSE="$MOCK_DIR/response.json"
export PATH="$MOCK_DIR/bin:$PATH"
printf '{"headRefOid":"%s","comments":[]}' "$A" > "$DC_GH_RESPONSE"
assert_eq promote "$(dc_live_promotion_decision 3179 fellowship-dev/pylot "$A" 0 "$MOCK_DIR/live.json")" fake-gh-unchanged-head-promotes
rg -Fq 'pr view 3179 --repo fellowship-dev/pylot --json headRefOid,comments' "$DC_GH_LOG" || {
  printf 'FAIL fake-gh-live-read\n' >&2
  exit 1
}
printf 'PASS fake-gh-live-read\n'
printf '{"headRefOid":"%s","comments":[{"id":"blocker","createdAt":"2026-08-20T00:00:00Z"}]}' "$B" > "$DC_GH_RESPONSE"
assert_eq restart "$(dc_live_promotion_decision 3179 fellowship-dev/pylot "$A" 0 "$MOCK_DIR/live.json")" fake-gh-moving-head-restarts
printf '{"headRefOid":"%s","comments":[{"id":"blocker","createdAt":"2026-08-20T00:00:00Z"}]}' "$A" > "$DC_GH_RESPONSE"
assert_eq blocked "$(dc_live_promotion_decision 3179 fellowship-dev/pylot "$A" 0 "$MOCK_DIR/live.json" '[]')" fake-gh-new-comment-blocks

# The procedure itself must place an executable gate immediately before the approval path. These
# assertions prevent a documentation-only regression from reintroducing stale-receipt promotion.
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
assert_contains 'dc_live_promotion_decision' executable-live-read-helper
assert_contains 'dc_require_promotable_head' executable-comment-and-label-guard
assert_contains 'COMMENT_CURSOR_CHANGED=true' same-sha-new-comment-fails-closed
assert_contains 'final_comment_cursor:' review-receipt-cursor-is-consumed
assert_contains 'cat <<REVIEW_EOF' promotion-marker-expands
if rg -Fq "cat <<'REVIEW_EOF'" "$POST_CONTEXT"; then
  printf 'FAIL promotion-marker-must-not-be-literal\n' >&2
  exit 1
fi
printf 'PASS exact-head receipt gate\n'
