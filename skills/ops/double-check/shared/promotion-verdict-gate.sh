#!/usr/bin/env bash
# Fail-closed first-check promotion gate. Source this file; it performs no GitHub mutation.

# Prints one of:
#   promote
#   needs-work:{negative-verdict|invalid-review-state|review-state-head-mismatch|blocking-findings}
#
# A first check may advance the pipeline only with an explicit positive verdict and a valid
# final review-state ledger for the exact live head. Open and confirmed findings are blockers;
# anything that cannot be parsed is deliberately treated as a blocker too.
dc_first_check_promotion_decision() {
  local verdict=$1 live_head_sha=$2 review_state=$3

  if [ "$verdict" != "ready" ]; then
    printf '%s\n' 'needs-work:negative-verdict'
    return 0
  fi
  if ! dc_is_full_sha "$live_head_sha"; then
    printf '%s\n' 'needs-work:invalid-review-state'
    return 0
  fi
  local state_check
  state_check=$(printf '%s' "$review_state" | node -e '
    let state; try { state = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
    if (!state || state.v !== 1 || !Array.isArray(state.findings)) process.exit(1);
    process.stdout.write(`${state.head_sha || ""}\n${state.findings.some(({status}) => status === "open" || status === "confirmed")}`);
  ' 2>/dev/null) || {
    printf '%s\n' 'needs-work:invalid-review-state'
    return 0
  }
  local state_head_sha has_blockers
  state_head_sha=$(printf '%s\n' "$state_check" | sed -n '1p')
  has_blockers=$(printf '%s\n' "$state_check" | sed -n '2p')
  if [ "$state_head_sha" != "$live_head_sha" ]; then
    printf '%s\n' 'needs-work:review-state-head-mismatch'
    return 0
  fi
  if [ "$has_blockers" = true ]; then
    printf '%s\n' 'needs-work:blocking-findings'
    return 0
  fi
  printf '%s\n' promote
}
