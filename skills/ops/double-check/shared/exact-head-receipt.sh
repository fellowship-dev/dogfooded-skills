#!/usr/bin/env bash
# Immutable exact-head receipt gate for the double-check post stage.
# Source this file; it intentionally performs no GitHub mutation.

dc_is_full_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# Prints one of: promote, restart, blocked.  The caller owns the receipt write and
# all side effects.  A malformed/unreadable head fails closed.
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
