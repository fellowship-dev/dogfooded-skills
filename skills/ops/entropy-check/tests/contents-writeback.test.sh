#!/usr/bin/env bash
# entropy-check write-back commits QUALITY_SCORE.md straight to the integration branch through the
# GitHub Contents API with [skip ci] — no branch, no PR (owner decision 2026-10-07). Exercises
# scripts/contents-writeback.sh against a fake `gh` on PATH: guards, payload shape, conflict codes.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WB="$ROOT/scripts/contents-writeback.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0

pass() { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; fail=1; }

# Fake gh: records argv and stdin of every call, answers per $FAKE_GH_MODE.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
for a in "$@"; do
  if [ "$prev" = "--input" ]; then
    if [ "$a" = "-" ]; then cat > "$FAKE_GH_PAYLOAD"; else cp "$a" "$FAKE_GH_PAYLOAD"; fi
  fi
  prev=$a
done
case "$FAKE_GH_MODE" in
  get-ok)  printf '{"sha":"blob123","content":"%s"}\n' "$(printf '# QS\n| a | B |\n' | base64 | tr -d '\n')" ;;
  get-404) printf '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  put-ok)  printf '{"content":{"sha":"newblob"},"commit":{"sha":"c0ffee1234"}}\n' ;;
  put-409) printf '{"message":"QUALITY_SCORE.md does not match blob123","status":"409"}'; echo 'gh: conflict (HTTP 409)' >&2; exit 1 ;;
  put-422) printf '{"message":"sha does not match","status":"422"}'; echo 'gh: sha does not match (HTTP 422)' >&2; exit 1 ;;
  put-500) printf '{"message":"boom","status":"500"}'; echo 'gh: boom (HTTP 500)' >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

# run <mode> <args...>: sets RC, OUT; resets the call log and payload capture.
run() {
  local mode=$1; shift
  : > "$WORK/gh.log"; rm -f "$WORK/payload.json"
  OUT=$(PATH="$WORK/bin:$PATH" FAKE_GH_MODE="$mode" FAKE_GH_LOG="$WORK/gh.log" \
    FAKE_GH_PAYLOAD="$WORK/payload.json" bash "$WB" "$@" 2>"$WORK/err")
  RC=$?
}

printf '# QS\n| a | A | ✅ ⚠️ — |\n' > "$WORK/qs.md"
MSG='chore: entropy scan — PR #1 x [skip ci]'

# Guard: only QUALITY_SCORE.md, refused before any API call.
run put-ok put org/repo develop docs/other.md "$WORK/qs.md" blob123 "$MSG"
[ "$RC" = 2 ] && [ ! -s "$WORK/gh.log" ] && pass "refuses any path but QUALITY_SCORE.md, no API call" \
  || bad path-guard "rc=$RC calls=$(wc -l < "$WORK/gh.log")"
grep -q 'QUALITY_SCORE.md' "$WORK/err" && pass "refusal names the only writable path" || bad path-guard-msg "$(cat "$WORK/err")"

# Guard: commit message must carry [skip ci].
run put-ok put org/repo develop QUALITY_SCORE.md "$WORK/qs.md" blob123 'chore: entropy scan'
[ "$RC" = 2 ] && [ ! -s "$WORK/gh.log" ] && pass "refuses a message without [skip ci]" || bad skip-ci-guard "rc=$RC"

# Guard: branch is required (never guessed).
run put-ok put org/repo "" QUALITY_SCORE.md "$WORK/qs.md" blob123 "$MSG"
[ "$RC" = 2 ] && pass "refuses an empty branch" || bad branch-guard "rc=$RC"

# Success: one PUT to the contents endpoint with branch, sha, message and the exact file bytes.
run put-ok put org/repo develop QUALITY_SCORE.md "$WORK/qs.md" blob123 "$MSG"
[ "$RC" = 0 ] && [ "$OUT" = c0ffee1234 ] && pass "commit succeeds and prints the commit sha" || bad put-ok "rc=$RC out=$OUT"
grep -q -- '-X PUT repos/org/repo/contents/QUALITY_SCORE.md' "$WORK/gh.log" && pass "PUTs repos/<repo>/contents/QUALITY_SCORE.md" \
  || bad put-endpoint "$(cat "$WORK/gh.log")"
[ "$(jq -r .branch "$WORK/payload.json")" = develop ] && pass "payload targets the given branch" || bad payload-branch "$(cat "$WORK/payload.json")"
[ "$(jq -r .sha "$WORK/payload.json")" = blob123 ] && pass "payload carries the blob sha (optimistic concurrency)" || bad payload-sha ""
[ "$(jq -r .message "$WORK/payload.json")" = "$MSG" ] && pass "payload message is the [skip ci] message" || bad payload-msg ""
[ "$(jq -r .content "$WORK/payload.json" | base64 -d 2>/dev/null || jq -r .content "$WORK/payload.json" | base64 -D)" = "$(cat "$WORK/qs.md")" ] \
  && pass "payload content is the file, base64" || bad payload-content ""
grep -qE '^(git|push)' "$WORK/gh.log" && bad no-git "unexpected call" || true

# Conflicts: 409 and 422 both mean "re-fetch, re-apply, retry" → exit 3.
run put-409 put org/repo develop QUALITY_SCORE.md "$WORK/qs.md" blob123 "$MSG"
[ "$RC" = 3 ] && pass "409 → exit 3 (stale sha)" || bad put-409 "rc=$RC"
run put-422 put org/repo develop QUALITY_SCORE.md "$WORK/qs.md" blob123 "$MSG"
[ "$RC" = 3 ] && pass "422 → exit 3 (stale sha)" || bad put-422 "rc=$RC"
run put-500 put org/repo develop QUALITY_SCORE.md "$WORK/qs.md" blob123 "$MSG"
[ "$RC" = 1 ] && pass "other API failure → exit 1" || bad put-500 "rc=$RC"

# Fetch: decodes the branch's current file and prints its blob sha.
run get-ok fetch org/repo develop "$WORK/fresh.md"
[ "$RC" = 0 ] && [ "$OUT" = blob123 ] && pass "fetch prints the blob sha" || bad fetch-sha "rc=$RC out=$OUT"
[ "$(cat "$WORK/fresh.md")" = "$(printf '# QS\n| a | B |')" ] && pass "fetch writes the decoded file" || bad fetch-content "$(cat "$WORK/fresh.md")"
grep -q 'repos/org/repo/contents/QUALITY_SCORE.md?ref=develop' "$WORK/gh.log" && pass "fetch reads from the given branch" || bad fetch-ref "$(cat "$WORK/gh.log")"
run get-404 fetch org/repo develop "$WORK/fresh.md"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$WORK/fresh.md" ] && pass "absent file → empty sha, empty file (create)" || bad fetch-404 "rc=$RC out=$OUT"

# SKILL.md contract: step 4a uses the helper, never a branch push or a PR.
SKILL="$ROOT/SKILL.md"
S4A=$(awk '/^#### 4a\./{on=1} /^### 5\./{on=0} on' "$SKILL")
[ -n "$S4A" ] || bad skill-4a "no step 4a"
grep -q 'contents-writeback.sh' <<< "$S4A" && pass "step 4a commits through contents-writeback.sh" || bad skill-helper "missing"
grep -qE 'gh pr create|git -C "\$REPO_ROOT" (push|switch|commit)' <<< "$S4A" && bad skill-no-pr "step 4a still pushes a branch or opens a PR" \
  || pass "step 4a opens no branch and no PR"
grep -q '\[skip ci\]' <<< "$S4A" && pass "step 4a keeps [skip ci]" || bad skill-skip-ci "missing"
grep -q 'Hookshot stale by' "$SKILL" && bad skill-volatile "S6 note still emits a day count" || pass "S6 note carries dates, not a day count"

exit $fail
