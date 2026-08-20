#!/usr/bin/env bash
# Supervisor-owned, HEAD-bound verification receipts for speckit-runner.
# Source this file from the operator session.  Commands are deliberately supplied
# by repository discovery; this helper knows nothing about languages or runners.

vr_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

vr_init() {
  VR_RECEIPT_FILE=${1:?receipt file required}
  VR_REPOSITORY=${2:?repository required}
  VR_HEAD_SHA=${3:?HEAD SHA required}
  mkdir -p "$(dirname "$VR_RECEIPT_FILE")"
  : >"$VR_RECEIPT_FILE"
  printf 'repository\thead_sha\tcheck\tcommand\tstarted_at\tended_at\texit_status\tartifact\tstate\tfreshness\tnote\n' >"$VR_RECEIPT_FILE"
}

# Canonical fields are hex encoded: tabs, newlines, pipes, and backticks retain
# their exact values without ever becoming TSV or Markdown syntax. Bash cannot
# represent NUL in an argument, so it is the sole byte outside this contract.
vr_field() {
  printf 'hex:'
  LC_ALL=C printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

vr_unfield() {
  local encoded=${1#hex:} byte output='' index=0
  case "$1" in hex:*) ;; *) return 64 ;; esac
  [[ $encoded =~ ^([0123456789abcdefABCDEF]{2})*$ ]] || return 64
  while [ "$index" -lt "${#encoded}" ]; do
    printf -v byte '%b' "\\x${encoded:index:2}"
    output+=$byte
    index=$((index + 2))
  done
  printf '%s' "$output"
}

vr_write() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(vr_field "$VR_REPOSITORY")" "$(vr_field "$VR_HEAD_SHA")" "$(vr_field "$1")" \
    "$(vr_field "$2")" "$(vr_field "$3")" "$(vr_field "$4")" "$(vr_field "$5")" \
    "$(vr_field "$6")" "$(vr_field "$7")" "$(vr_field "${8:-current}")" "$(vr_field "${9:-}")" >>"$VR_RECEIPT_FILE"
}

# Execute only from the supervisor/operator context.  A producer's prose never
# calls this function, so it cannot manufacture a passed receipt.
vr_run() {
  local check=${1:?check identity required} command=${2:?command required} artifact=${3:-}
  local started ended status state
  started=$(vr_now)
  if bash -lc "$command"; then status=0; else status=$?; fi
  ended=$(vr_now)
  state=failed
  [ "$status" -eq 0 ] && state=passed
  vr_write "$check" "$command" "$started" "$ended" "$status" "$artifact" "$state" current "supervisor-observed"
  return "$status"
}

# Use when discovery establishes that a check cannot be started (for example a
# missing runtime or required credential).  Do not translate it to passed.
vr_record() {
  local state=${1:?state required} check=${2:?check identity required} command=${3:-} note=${4:-} artifact=${5:-}
  # `passed` is intentionally excluded: only vr_run may observe a zero exit.
  case "$state" in failed|not-run|unavailable) ;; *) return 64 ;; esac
  local now; now=$(vr_now)
  vr_write "$check" "$command" "$now" "$now" "N/A" "$artifact" "$state" current "$note"
}

# A receipt file is reusable only at exactly the head it names.  Earlier data
# remains visible, but this marks it stale and prevents it from being presented
# as current verification.
vr_bind_current_head() {
  local current_head=${1:?current HEAD required}
  [ -f "$VR_RECEIPT_FILE" ] || return 1
  local receipt_head
  receipt_head=$(awk -F '\t' 'NR == 2 { print $2; exit }' "$VR_RECEIPT_FILE")
  receipt_head=$(vr_unfield "$receipt_head") || return 1
  [ -n "$receipt_head" ] && [ "$receipt_head" = "$current_head" ]
}

vr_mark_stale() {
  local current_head=${1:?current HEAD required}
  [ -f "$VR_RECEIPT_FILE" ] || return 1
  awk -F '\t' -v OFS='\t' -v current="$current_head" 'NR == 1 { print; next } { $10="stale"; $11="receipt head " $2 " does not match current head " current; print }' "$VR_RECEIPT_FILE" >"$VR_RECEIPT_FILE.tmp"
  mv "$VR_RECEIPT_FILE.tmp" "$VR_RECEIPT_FILE"
}

vr_disclosure() {
  [ -f "$VR_RECEIPT_FILE" ] || return 1
  printf '### Supervisor verification receipts\n\n'
  printf '| Check | Command / identity | State | Exit | HEAD binding | Evidence | Note |\n|---|---|---|---|---|---|---|\n'
  # Hex fields are safe to place directly in a Markdown table. Keep this POSIX
  # awk: BSD awk rejects a ternary expression directly inside printf arguments.
  awk -F '\t' 'NR > 1 { evidence = $8; if (evidence == "") evidence = "N/A"; printf "| %s | %s | %s | %s | %s | %s | %s |\n", $3, $4, $9, $7, $10, evidence, $11 }' "$VR_RECEIPT_FILE"
}

vr_has_records_for_head() {
  local current_head=${1:?current HEAD required}
  vr_bind_current_head "$current_head" || return 1
  awk -F '\t' 'NR > 1 { found = 1; exit } END { exit !found }' "$VR_RECEIPT_FILE"
}
