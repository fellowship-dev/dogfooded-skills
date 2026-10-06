#!/usr/bin/env bash
# Speed contract for double-check (perf: double-check mission time).
# Pins the three measured fixes so a later edit cannot silently bring the cost back:
#   1. stage 01 writes the verbatim artifacts by shell redirection, not through the handoff;
#   2. stage 01 never pushes (its base merge is a local check; see base-merge-no-push.test.sh);
#   3. stage 03 tests its fix delta once, waits on the process, and never sleep-polls.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
S01="$ROOT/stages/01-setup/CONTEXT.md"
S02="$ROOT/stages/02-review/CONTEXT.md"
S03="$ROOT/stages/03-fix/CONTEXT.md"
fail=0

need() { # file, fixed string, scenario
  if grep -qF -- "$2" "$1"; then printf 'PASS %s\n' "$3"; else printf 'FAIL %s: missing %q in %s\n' "$3" "$2" "${1#"$ROOT"/}" >&2; fail=1; fi
}
forbid_re() { # file, ERE, scenario
  if grep -nE -- "$2" "$1" >/dev/null; then printf 'FAIL %s: %s matches /%s/\n' "$3" "${1#"$ROOT"/}" "$2" >&2; grep -nE -- "$2" "$1" >&2; fail=1; else printf 'PASS %s\n' "$3"; fi
}

# 1. Artifacts by redirection; the handoff template no longer embeds them.
need "$S01" 'gh pr diff $PR --repo $REPO > "$OUT/diff.patch"' setup-diff-redirected
need "$S01" '> "$OUT/pr-body.md"' setup-body-redirected
need "$S01" '> "$OUT/first-review.md"' setup-first-review-redirected
need "$S01" '> "$OUT/changed-files.txt"' setup-manifest-redirected
forbid_re "$S01" '^## Full Diff' setup-handoff-has-no-inline-diff
forbid_re "$S01" '^\{full diff text' setup-handoff-has-no-diff-placeholder
need "$S02" 'diff.patch' review-reads-diff-file
need "$S02" 'changed-files.txt' review-reads-manifest-file
need "$S02" 'first-review.md' review-reads-first-review-file
need "$S02" 'pr-body.md' review-reads-body-file

# 2. Stage 01 pushes nothing: no hooked push, and no base-merge push either (pylot#3738).
forbid_re "$S01" '^[[:space:]]*git push' setup-never-pushes

# 3. Fix delta, once; process-bound waits; no fixed long sleeps anywhere in the skill.
need "$S03" 'PYLOT_GATE_BASE_SHA=$PRE_FIX_HEAD_SHA' fix-scoped-to-own-commits
need "$S03" 'until [ -f "$LOG.rc" ]' fix-waits-on-exit
for f in "$ROOT"/SKILL.md "$ROOT"/CONTEXT.md "$ROOT"/stages/*/CONTEXT.md; do
  forbid_re "$f" '(^|[;&|[:space:]`])sleep [0-9]{2,}([^0-9]|$)' "no-fixed-long-sleep:${f#"$ROOT"/}"
done

exit "$fail"
