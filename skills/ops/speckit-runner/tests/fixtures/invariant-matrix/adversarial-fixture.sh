#!/bin/sh
set -eu

# Deliberately defective portable behaviors. A zero status means the review
# probe observed the seeded violation.
case "${1:-}" in
  authorization)
    actual=allow
    test "$actual" != deny
    ;;
  secret-handling)
    secret='fixture-secret-value'
    actual="diagnostic token=$secret"
    case "$actual" in *"$secret"*) exit 0;; *) exit 1;; esac
    ;;
  process-tree-cancellation)
    sleep 30 &
    child=$!
    if kill -0 "$child" 2>/dev/null; then
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      exit 0
    fi
    exit 1
    ;;
  session-continuity)
    before=session-123
    after=session-new
    test "$before" != "$after"
    ;;
  compatibility)
    specimen='[[ x = x ]]'
    case "$specimen" in *'[['*) exit 0;; *) exit 1;; esac
    ;;
  *)
    echo "usage: $0 authorization|secret-handling|process-tree-cancellation|session-continuity|compatibility" >&2
    exit 2
    ;;
esac
