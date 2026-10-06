#!/usr/bin/env bash
# Behavior tests for scripts/file-finding.sh against a stub `gh` (no network).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FF="$ROOT/scripts/file-finding.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list")
    case "$*" in
      *"--label digest"*) [ -n "${STUB_DIGEST:-}" ] && echo "$STUB_DIGEST" ;;
      *) [ -n "${STUB_EXISTING:-}" ] && echo "$STUB_EXISTING" ;;
    esac ;;
  "issue create")
    case "$*" in
      *"Weekly findings digest"*) echo "https://github.com/o/r/issues/900" ;;
      *) echo "https://github.com/o/r/issues/${STUB_NEW:-501}" ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" FINDING_STATE_DIR="$TMP/state"
fail=0

run() { # scenario, expected stdout prefix, args...
  local name="$1" want="$2" got; shift 2
  : > "$GH_LOG"
  got=$(bash "$FF" --repo o/r --search "root cause" --body "evidence" "$@")
  case "$got" in
    "$want"*) printf 'PASS %s\n' "$name" ;;
    *) printf 'FAIL %s: want %q, got %q\n' "$name" "$want" "$got" >&2; fail=1 ;;
  esac
}
logged() { # scenario, ERE that must appear in the gh call log
  if grep -qE -- "$2" "$GH_LOG"; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s: no gh call matching /%s/\n' "$1" "$2" >&2; cat "$GH_LOG" >&2; fail=1; fi
}
not_logged() {
  if grep -qE -- "$2" "$GH_LOG"; then printf 'FAIL %s: unexpected gh call /%s/\n' "$1" "$2" >&2; fail=1; else printf 'PASS %s\n' "$1"; fi
}

# a. Same root cause open → comment, never create (even for P0).
STUB_EXISTING=42 run dedupe-comments "commented 42" --title t --severity P0
logged dedupe-searches-open-excluding-digest 'issue list --repo o/r --state open .*root cause in:title,body -label:digest'
logged dedupe-comment-target 'issue comment 42 --repo o/r'
not_logged dedupe-never-creates 'issue create'

# b. Non-blocking → existing weekly digest gets a comment.
STUB_DIGEST=77 run nonblocking-to-digest "digest 77 non-blocking" --title t --severity P2
logged digest-comment 'issue comment 77 --repo o/r'
not_logged digest-existing-no-create 'issue create'
# b'. No digest this week → created once with the digest label, then commented.
run digest-find-or-create "digest 900 non-blocking" --title t
logged digest-created-labeled 'issue create --repo o/r --title Weekly findings digest — [0-9]{4}-W[0-9]{2} --label digest,no-automation'
logged digest-created-then-commented 'issue comment 900'

# c. Cap: 3 blocking issues per cycle, the 4th goes to the digest; P0/incident exempt.
export FINDING_CYCLE=cycle-a
run cap-1 "created 501" --title t --blocking --label bug
logged create-passes-labels 'issue create --repo o/r --title t --body evidence --label bug'
run cap-2 "created 501" --title t --severity P1
run cap-3 "created 501" --title t --blocking
STUB_DIGEST=77 run cap-4-over "digest 77 over-cap" --title t --blocking
run cap-p0-exempt "created 501" --title t --severity P0
run cap-incident-exempt "created 501" --title t --incident
FINDING_CYCLE=cycle-b run cap-new-cycle-resets "created 501" --title t --blocking

# Dry run writes nothing.
FINDING_CYCLE=cycle-c run dry-run "would-created new" --title t --blocking --dry-run
not_logged dry-run-no-writes 'issue (create|comment)'
[ ! -e "$FINDING_STATE_DIR/o_r_cycle-c.count" ] && echo "PASS dry-run-no-count" || { echo "FAIL dry-run-no-count" >&2; fail=1; }

# Bad input is refused.
if bash "$FF" --repo o/r --title t --body x 2>/dev/null; then echo "FAIL requires-search" >&2; fail=1; else echo "PASS requires-search"; fi

# Contract: no skill instruction files an issue with a raw `gh issue create`.
SKILLS=$(cd "$ROOT/../.." && pwd)
if [ -d "$SKILLS/ops" ] && grep -rnE --include='*.md' '^[[:space:]]*(GH_TOKEN=[^ ]+[[:space:]]+)?gh issue create' "$SKILLS" >&2; then
  echo "FAIL no-raw-issue-create: route the lines above through file-finding.sh" >&2; fail=1
else
  echo "PASS no-raw-issue-create"
fi

exit $fail
