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
  grep -Fq -- "$needle" "$file" || { printf 'FAIL %s: missing %s\n' "$scenario" "$needle" >&2; exit 1; }
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
assert_contains "$(vr_field producer-claim)"$'\t'"$(vr_field 'tests pass')" "$RECEIPTS" producer-claim-recorded-not-run
assert_contains $'\t'"$(vr_field not-run)"$'\t'"$(vr_field current)"$'\t'"$(vr_field 'producer claim is not evidence')" "$RECEIPTS" producer-claim-not-passed
if ! vr_bind_current_head "$HEAD_A"; then
  printf 'FAIL same-head-must-accept-receipts\n' >&2
  exit 1
fi
printf 'PASS same-head-accepts-receipts\n'
if vr_record passed forged-pass 'echo claimed' 'producer assertion'; then
  printf 'FAIL forged-passed-receipt-must-be-rejected\n' >&2; exit 1
fi
printf 'PASS forged-passed-receipt-must-be-rejected\n'

vr_run passing-check 'printf observed' >/dev/null
assert_contains "$(vr_field passing-check)"$'\t'"$(vr_field 'printf observed')" "$RECEIPTS" supervisor-runs-passing-command
assert_contains $'\t'"$(vr_field 0)"$'\t'"$(vr_field '')"$'\t'"$(vr_field passed)"$'\t'"$(vr_field current)"$'\t'"$(vr_field supervisor-observed)" "$RECEIPTS" passing-receipt-observed

if vr_run failing-check 'exit 23' >/dev/null; then EXIT=0; else EXIT=$?; fi
assert_status 23 "$EXIT" failing-command-real-exit
assert_contains "$(vr_field failing-check)"$'\t'"$(vr_field 'exit 23')" "$RECEIPTS" failing-command-recorded
assert_contains $'\t'"$(vr_field 23)"$'\t'"$(vr_field '')"$'\t'"$(vr_field failed)"$'\t'"$(vr_field current)"$'\t'"$(vr_field supervisor-observed)" "$RECEIPTS" failing-state-and-exit

vr_record unavailable integration-check 'tool login' 'credential unavailable'
assert_contains "$(vr_field integration-check)"$'\t'"$(vr_field 'tool login')" "$RECEIPTS" unavailable-check-recorded
assert_contains $'\t'"$(vr_field N/A)"$'\t'"$(vr_field '')"$'\t'"$(vr_field unavailable)"$'\t'"$(vr_field current)"$'\t'"$(vr_field 'credential unavailable')" "$RECEIPTS" unavailable-is-explicit

vr_disclosure >"$TMP/disclosure.md"
assert_contains "| $(vr_field producer-claim) | $(vr_field 'tests pass') | $(vr_field not-run) | $(vr_field N/A) | $(vr_field current) | $(vr_field '') | $(vr_field 'producer claim is not evidence') |" "$TMP/disclosure.md" not-run-disclosed
assert_contains "| $(vr_field integration-check) | $(vr_field 'tool login') | $(vr_field unavailable) | $(vr_field N/A) | $(vr_field current) | $(vr_field '') | $(vr_field 'credential unavailable') |" "$TMP/disclosure.md" unavailable-disclosed

HOSTILE_CHECK=$'check|`name\twith\nnewlines'
HOSTILE_COMMAND=$'printf "pipe|backtick`\tline1\nline2"'
HOSTILE_NOTE=$'note|`\tline1\nline2'
vr_record not-run "$HOSTILE_CHECK" "$HOSTILE_COMMAND" "$HOSTILE_NOTE"
HOSTILE_CHECK_ENCODED=$(vr_field "$HOSTILE_CHECK")
HOSTILE_COMMAND_ENCODED=$(vr_field "$HOSTILE_COMMAND")
HOSTILE_NOTE_ENCODED=$(vr_field "$HOSTILE_NOTE")
assert_contains "$HOSTILE_CHECK_ENCODED" "$RECEIPTS" hostile-check-canonical-encoded
assert_contains "$HOSTILE_COMMAND_ENCODED" "$RECEIPTS" hostile-command-canonical-encoded
assert_status "$HOSTILE_CHECK" "$(vr_unfield "$HOSTILE_CHECK_ENCODED")" hostile-check-exact-round-trip
assert_status "$HOSTILE_COMMAND" "$(vr_unfield "$HOSTILE_COMMAND_ENCODED")" hostile-command-exact-round-trip
assert_status "$HOSTILE_NOTE" "$(vr_unfield "$HOSTILE_NOTE_ENCODED")" hostile-note-exact-round-trip
vr_disclosure >"$TMP/hostile-disclosure.md"
assert_contains "| $HOSTILE_CHECK_ENCODED | $HOSTILE_COMMAND_ENCODED |" "$TMP/hostile-disclosure.md" hostile-markdown-uses-safe-encoding
if grep -Fq -- "$HOSTILE_CHECK" "$TMP/hostile-disclosure.md" || grep -Fq -- 'pipe|backtick`' "$TMP/hostile-disclosure.md"; then
  printf 'FAIL hostile-markdown-must-not-inject-table-or-code-span\n' >&2
  exit 1
fi
printf 'PASS hostile-markdown-must-not-inject-table-or-code-span\n'

if vr_bind_current_head "$HEAD_B"; then
  printf 'FAIL moved-head-must-reject-old-receipts\n' >&2; exit 1
fi
printf 'PASS moved-head-must-reject-old-receipts\n'
vr_mark_stale "$HEAD_B"
assert_contains $'\tstale\t' "$RECEIPTS" stale-receipts-visible
vr_disclosure >"$TMP/stale-disclosure.md"
assert_contains "| $(vr_field failing-check) | $(vr_field 'exit 23') | $(vr_field failed) | $(vr_field 23) | stale | $(vr_field '') | receipt head " "$TMP/stale-disclosure.md" stale-disclosed

# A correction-head move retains a stale receipt separately and cannot proceed
# until a new receipt at that exact head contains a fresh recorded check.
OLD_RECEIPTS="$RECEIPTS"
STALE_COPY="$TMP/stale-$HEAD_A.tsv"
cp "$OLD_RECEIPTS" "$STALE_COPY"
FRESH_RECEIPT_DIR="$TMP/head-$HEAD_B"
VR_RECEIPT_FILE="$FRESH_RECEIPT_DIR/receipts.tsv"
vr_init "$VR_RECEIPT_FILE" fellowship-dev/example "$HEAD_B"
if vr_has_records_for_head "$HEAD_B"; then
  printf 'FAIL correction-head-must-require-fresh-execution\n' >&2
  exit 1
fi
printf 'PASS correction-head-requires-fresh-execution\n'
vr_record not-run correction-check 'fresh discovery command' 'freshly discovered at correction head'
if ! vr_has_records_for_head "$HEAD_B"; then
  printf 'FAIL correction-head-fresh-receipt-must-bind\n' >&2
  exit 1
fi
assert_contains $'\tstale\t' "$STALE_COPY" correction-head-retains-stale-receipt
if [ "$STALE_COPY" = "$VR_RECEIPT_FILE" ]; then
  printf 'FAIL correction-head-must-rotate-receipt-path\n' >&2
  exit 1
fi
printf 'PASS correction-head-rotates-fresh-receipt-path\n'

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
assert_contains 'FRESH_RECEIPT_DIR=' "$SKILL" correction-head-uses-new-receipt-path
assert_contains 'vr_has_records_for_head "$CORRECTION_HEAD"' "$SKILL" correction-head-fails-closed-without-fresh-execution
assert_contains 'trap cleanup_supervisor_checkout EXIT' "$SKILL" supervisor-checkout-cleanup-is-executable
printf 'PASS verification receipt contract\n'
