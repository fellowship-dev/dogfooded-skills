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
      *"select(.title != "*) [ -n "${STUB_OLD_DIGEST:-}" ] && echo "$STUB_OLD_DIGEST" ;;
      *"--label digest"*) [ -n "${STUB_DIGEST:-}" ] && echo "$STUB_DIGEST" ;;
      *) [ -n "${STUB_EXISTING:-}" ] && echo "$STUB_EXISTING" ;;
    esac ;;
  "issue view") [ -n "${STUB_DIGEST_COMMENTS:-}" ] && printf '%s\n' "$STUB_DIGEST_COMMENTS" ;;
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
not_logged digest-no-rollover-when-none 'issue close'
# b2. Creating this week's digest closes last week's open one.
STUB_OLD_DIGEST=66 run digest-rollover "digest 900 non-blocking" --title t
logged digest-rollover-closes-old 'issue close 66 --repo o/r --comment Superseded by #900'
# b3. Same finding already in this week's digest: no second comment.
STUB_DIGEST=77 STUB_DIGEST_COMMENTS=$'### t\n\nold evidence' run digest-dedupe "digest 77 duplicate" --title t
not_logged digest-dedupe-no-comment 'issue comment'
# Body from stdin.
got=$(printf 'from stdin' | bash "$FF" --repo o/r --title t --search x --body-file - --dry-run)
[ "$got" = "would-digest new non-blocking" ] && echo "PASS body-file-stdin" || { echo "FAIL body-file-stdin: $got" >&2; fail=1; }

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
# The cap is per filer run, not per repo.
got=$(STUB_DIGEST=77 bash "$FF" --repo o/other --search x --body e --title t --blocking)
case "$got" in "digest 77 over-cap"*) echo "PASS cap-spans-repos" ;; *) echo "FAIL cap-spans-repos: $got" >&2; fail=1 ;; esac

# Dry run writes nothing.
FINDING_CYCLE=cycle-c run dry-run "would-created new" --title t --blocking --dry-run
not_logged dry-run-no-writes 'issue (create|comment)'
[ ! -e "$FINDING_STATE_DIR/cycle-c.count" ] && echo "PASS dry-run-no-count" || { echo "FAIL dry-run-no-count" >&2; fail=1; }

# Bad input is refused.
if bash "$FF" --repo o/r --title t --body x 2>/dev/null; then echo "FAIL requires-search" >&2; fail=1; else echo "PASS requires-search"; fi

# Contract: no skill instruction files an issue with a raw `gh issue create`.
SKILLS=$(cd "$ROOT/../.." && pwd)
if [ -d "$SKILLS/ops" ] && grep -rnE --include='*.md' '(^|[$][(]|&&|;)[[:space:]]*(GH_TOKEN=[^ ]+[[:space:]]+)?gh issue create' "$SKILLS" >&2; then
  echo "FAIL no-raw-issue-create: route the lines above through file-finding.sh" >&2; fail=1
else
  echo "PASS no-raw-issue-create"
fi

exit $fail
