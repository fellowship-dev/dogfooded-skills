#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../shared/exact-head-receipt.sh
source "$ROOT/shared/exact-head-receipt.sh"
# shellcheck source=../shared/nonpromotion-receipt.sh
source "$ROOT/shared/nonpromotion-receipt.sh"

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
json_field() {
  node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))[process.argv[2]]" "$1" "$2"
}
INCIDENT_REVIEWED=$(json_field "$FIXTURE" reviewed_head_sha)
INCIDENT_LIVE=$(json_field "$FIXTURE" live_head_sha)
INCIDENT_COMMENT=$(json_field "$FIXTURE" new_comment)
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
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "$DC_GH_LOG"' \
  '[ "${DC_GH_FAIL:-false}" = true ] && exit 1' \
  'cat "$DC_GH_RESPONSE"' > "$MOCK_DIR/bin/gh"
chmod +x "$MOCK_DIR/bin/gh"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'filter=; file=' \
  'for arg in "$@"; do case "$arg" in .*|\[*|type\ *) filter=$arg ;; *.json) file=$arg ;; esac; done' \
  '[ -n "$file" ] && input=$(cat "$file") || input=$(cat)' \
  'node -e '\''const [filter,input]=process.argv.slice(1); let x={}; try{x=JSON.parse(input)}catch{}; const nl=String.fromCharCode(10); if(filter.includes("headRefOid")){process.stdout.write((x.headRefOid||"")+nl)} else if(filter.includes("type ==")){process.exit(Array.isArray(x)?0:1)} else if(filter.includes("comments[]")){process.stdout.write(JSON.stringify((x.comments||[]).map(({id,createdAt,updatedAt})=>({id,createdAt,updatedAt})))+nl)} else {process.stdout.write(JSON.stringify(x)+nl)} '\'' "$filter" "$input"' > "$MOCK_DIR/bin/jq"
chmod +x "$MOCK_DIR/bin/jq"
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

# Run the Stage 04 live-read branch, not just the decision helper. Nonpromotion must leave a
# durable local receipt and make no GitHub comment, label, or PR-edit mutation.
stage04_live_gate() {
  local reviewed=$1 restart_count=$2 expected_cursor=$3 receipt_id=$4 output_file=$5 receipt_dir=$6
  local decision live_head live_cursor live_read_failed=false reason
  if ! gh pr view 3179 --repo fellowship-dev/pylot --json title,body,additions,deletions,files,headRefOid,comments > "$output_file"; then
    live_read_failed=true
  fi
  live_head=$(jq -r '.headRefOid // empty' "$output_file" 2>/dev/null || true)
  decision=$(dc_exact_head_decision "$reviewed" "$live_head" "$restart_count")
  [ "$live_read_failed" = true ] && decision=blocked
  live_cursor=$(jq -c '[.comments[] | {id, createdAt, updatedAt}]' "$output_file" 2>/dev/null || true)
  if [ "$(printf '%s' "$expected_cursor" | jq -cS . 2>/dev/null)" != "$(printf '%s' "$live_cursor" | jq -cS . 2>/dev/null)" ]; then
    decision=blocked
    reason='review comments changed after cohesive review'
  fi
  [ "$live_read_failed" = true ] && reason='live PR read failed'
  case "$decision" in
    restart)
      dc_write_nonpromotion_receipt restart "$receipt_dir" "$reviewed" "$live_head" "$receipt_id" "$restart_count" "$live_cursor"
      return 3
      ;;
    blocked)
      dc_write_nonpromotion_receipt blocked "$receipt_dir" "$reviewed" "${live_head:-unavailable}" "$receipt_id" "$restart_count" "$live_cursor" "${reason:-exact-head receipt unavailable or superseded}"
      return 2
      ;;
    promote)
      gh pr comment 3179 --repo fellowship-dev/pylot --body 'promotable exact-head review'
      gh pr edit 3179 --repo fellowship-dev/pylot --add-label double-checked
      ;;
  esac
}

mutation_count() {
  local count
  count=$(rg -c '^pr (comment|edit)|^label ' "$DC_GH_LOG" 2>/dev/null || true)
  printf '%s\n' "${count:-0}"
}
run_nonpromotion_case() {
  local scenario=$1 reviewed=$2 restart_count=$3 response=$4 expected_status=$5 expected_receipt=$6
  : > "$DC_GH_LOG"
  printf '%s' "$response" > "$DC_GH_RESPONSE"
  local receipt_dir="$MOCK_DIR/$scenario"
  set +e
  stage04_live_gate "$reviewed" "$restart_count" '[]' receipt-3197 "$MOCK_DIR/$scenario.json" "$receipt_dir" >/dev/null
  local status=$?
  set -e
  assert_eq "$expected_status" "$status" "$scenario-status"
  assert_eq 0 "$(mutation_count)" "$scenario-no-github-mutations"
  [ -s "$receipt_dir/$expected_receipt" ] || { printf 'FAIL %s durable receipt missing\n' "$scenario" >&2; exit 1; }
  printf 'PASS %s durable-local-receipt\n' "$scenario"
}

run_nonpromotion_case first-move "$A" 0 "{\"headRefOid\":\"$B\",\"comments\":[]}" 3 restart.md
run_nonpromotion_case second-move "$B" 1 "{\"headRefOid\":\"$C\",\"comments\":[]}" 2 blocked.md
run_nonpromotion_case same-sha-late-comment "$A" 0 "{\"headRefOid\":\"$A\",\"comments\":[{\"id\":\"late\",\"createdAt\":\"2026-08-20T00:00:00Z\"}]}" 2 blocked.md
DC_GH_FAIL=true run_nonpromotion_case live-read-failure "$A" 0 '{"headRefOid":"","comments":[]}' 2 blocked.md

: > "$DC_GH_LOG"
printf '{"headRefOid":"%s","comments":[]}' "$A" > "$DC_GH_RESPONSE"
stage04_live_gate "$A" 0 '[]' receipt-promote "$MOCK_DIR/promote.json" "$MOCK_DIR/promote" >/dev/null
assert_eq 2 "$(mutation_count)" promotable-path-keeps-comment-and-label-mutations

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
