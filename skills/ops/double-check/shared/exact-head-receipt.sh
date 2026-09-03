#!/usr/bin/env bash
# Immutable exact-head gate for the double-check post stage.
# Source this file; it intentionally performs no GitHub mutation.

dc_is_full_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# Prints one of: promote, restart, blocked.  The caller owns all side effects.
# A malformed/unreadable head fails closed.
dc_exact_head_decision() {
  local reviewed_head_sha=$1 live_head_sha=$2 restart_count=$3

  if ! dc_is_full_sha "$reviewed_head_sha" || ! dc_is_full_sha "$live_head_sha"; then
    printf '%s\n' blocked
  elif [ "$reviewed_head_sha" = "$live_head_sha" ]; then
    printf '%s\n' promote
  elif [ "$restart_count" = 0 ]; then
    printf '%s\n' restart
  else
    printf '%s\n' blocked
  fi
}

# Read the authoritative PR head immediately before a promotion mutation. The
# caller must stop unless this prints `promote`; a cached JSON document must
# never authorize a comment or label that advances the review pipeline.
dc_live_promotion_decision() {
  local pr=$1 repo=$2 reviewed_head_sha=$3 restart_count=$4 output_file=$5

  if ! gh pr view "$pr" --repo "$repo" --json headRefOid >"$output_file"; then
    printf '%s\n' blocked
    return 0
  fi

  local live_head_sha
  live_head_sha=$(jq -r '.headRefOid // empty' "$output_file" 2>/dev/null || true)
  dc_exact_head_decision "$reviewed_head_sha" "$live_head_sha" "$restart_count"
}
