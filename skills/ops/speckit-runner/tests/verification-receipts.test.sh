#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../shared/verification-receipts.sh
source "$ROOT/shared/verification-receipts.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RECEIPTS="$TMP/receipts.tsv"
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

assert_contains() {
  local needle=$1 file=$2 scenario=$3
  rg -Fq "$needle" "$file" || { printf 'FAIL %s: missing %s\n' "$scenario" "$needle" >&2; exit 1; }
  printf 'PASS %s\n' "$scenario"
}
assert_status() {
  local expected=$1 actual=$2 scenario=$3
  [ "$expected" = "$actual" ] || { printf 'FAIL %s: expected %s, got %s\n' "$scenario" "$expected" "$actual" >&2; exit 1; }
  printf 'PASS %s\n' "$scenario"
}

vr_init "$RECEIPTS" fellowship-dev/example "$HEAD_A"
# A producer claim is inert: only the helper's observed command can write passed.
vr_record not-run producer-claim 'tests pass' 'producer claim is not evidence'
assert_contains $'producer-claim\ttests pass\t' "$RECEIPTS" producer-claim-recorded-not-run
assert_contains $'\tnot-run\tcurrent\tproducer claim is not evidence' "$RECEIPTS" producer-claim-not-passed
if vr_record passed forged-pass 'echo claimed' 'producer assertion'; then
  printf 'FAIL forged-passed-receipt-must-be-rejected\n' >&2; exit 1
fi
printf 'PASS forged-passed-receipt-must-be-rejected\n'

vr_run passing-check 'printf observed' >/dev/null
assert_contains $'passing-check\tprintf observed\t' "$RECEIPTS" supervisor-runs-passing-command
assert_contains $'\t0\t\tpassed\tcurrent\tsupervisor-observed' "$RECEIPTS" passing-receipt-observed

if vr_run failing-check 'exit 23' >/dev/null; then EXIT=0; else EXIT=$?; fi
assert_status 23 "$EXIT" failing-command-real-exit
assert_contains $'failing-check\texit 23\t' "$RECEIPTS" failing-command-recorded
assert_contains $'\t23\t\tfailed\tcurrent\tsupervisor-observed' "$RECEIPTS" failing-state-and-exit

vr_record unavailable integration-check 'tool login' 'credential unavailable'
assert_contains $'integration-check\ttool login\t' "$RECEIPTS" unavailable-check-recorded
assert_contains $'\tN/A\t\tunavailable\tcurrent\tcredential unavailable' "$RECEIPTS" unavailable-is-explicit

vr_disclosure >"$TMP/disclosure.md"
assert_contains '| producer-claim | `tests pass` | not-run | N/A | current | N/A | producer claim is not evidence |' "$TMP/disclosure.md" not-run-disclosed
assert_contains '| integration-check | `tool login` | unavailable | N/A | current | N/A | credential unavailable |' "$TMP/disclosure.md" unavailable-disclosed

if vr_bind_current_head "$HEAD_B"; then
  printf 'FAIL moved-head-must-reject-old-receipts\n' >&2; exit 1
fi
printf 'PASS moved-head-must-reject-old-receipts\n'
vr_mark_stale "$HEAD_B"
assert_contains $'\tstale\treceipt head ' "$RECEIPTS" stale-receipts-visible
vr_disclosure >"$TMP/stale-disclosure.md"
assert_contains '| failing-check | `exit 23` | failed | 23 | stale | N/A | receipt head ' "$TMP/stale-disclosure.md" stale-disclosed

# The skill must discover commands from the target repository and run them from
# the supervisor context; it may not bake any framework-specific command in.
SKILL="$ROOT/SKILL.md"
assert_contains 'repository-owned verification discovery' "$SKILL" repository-owned-discovery
assert_contains 'vr_run "$CHECK_ID" "$CHECK_COMMAND"' "$SKILL" supervisor-executes-discovered-command
assert_contains 'VR_RECEIPT_FILE' "$SKILL" receipts-threaded-through-runner
assert_contains 'FIRST_REVIEW_STATUS="unavailable"' "$SKILL" reviewer-unavailable-recorded
assert_contains 'independent_review=$FIRST_REVIEW_STATUS\" status=success' "$SKILL" reviewer-unavailable-does-not-block-pr
assert_contains 'Copy the supervisor-owned verification disclosure below verbatim into the PR' "$SKILL" failed-and-unavailable-disclosure-required
assert_contains 'vr_mark_stale "$CORRECTION_HEAD"' "$SKILL" correction-head-marks-receipts-stale
printf 'PASS verification receipt contract\n'
