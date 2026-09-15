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
    # Genuine dialect probe: `[[ ... ]]` is a bashism. A POSIX-only shell
    # (dash) must reject it; this must not depend on whatever /bin/sh
    # happens to resolve to on the host running the test (on macOS,
    # /bin/sh is bash, which silently accepts it). We explicitly invoke a
    # named POSIX-only shell binary rather than the ambient /bin/sh.
    posix_sh=""
    for candidate in dash "busybox sh"; do
      set -- $candidate
      if command -v "$1" >/dev/null 2>&1; then
        posix_sh=$candidate
        break
      fi
    done
    if [ -z "$posix_sh" ]; then
      echo "compatibility: no POSIX-only shell binary (dash/busybox) available to probe; skipping" >&2
      exit 1
    fi
    if $posix_sh -c '[[ x = x ]]' >/dev/null 2>&1; then
      # A POSIX-only shell accepted a bashism: the seeded defect is present.
      exit 1
    else
      # A POSIX-only shell correctly rejected the bashism: no defect.
      exit 0
    fi
    ;;
  *)
    echo "usage: $0 authorization|secret-handling|process-tree-cancellation|session-continuity|compatibility" >&2
    exit 2
    ;;
esac
