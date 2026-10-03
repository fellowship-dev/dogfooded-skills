#!/usr/bin/env bash
set -euo pipefail

# Regression test for pylot#3690: Stage 05 reported status=success off a bare HTTP-200 check
# against $PROD_DOMAIN even while the custom-domain alias was pinned to a stale deployment — 19
# days of non-deploys went undetected. This test extracts Stage 05's *actual* bash fence straight
# out of SKILL.md (not a hand-copied mimic) and runs it against a mocked Vercel API, so a future
# edit that regresses the alias-id check breaks this test rather than only the doc.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL_MD="$ROOT/SKILL.md"

extract_stage05() {
  python3 - "$SKILL_MD" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
after = text.split("## Stage 05", 1)[1]
m = re.search(r"```bash\n(.*?)\n```", after, re.DOTALL)
if not m:
    sys.exit("Stage 05 bash fence not found")
sys.stdout.write(m.group(1))
PYEOF
}

# Stage 05's extracted script unconditionally does `source /tmp/vercel-deploy-ctx.env` as its
# first line (the real inter-stage contract) — write fixtures to that exact path and restore
# whatever was there before, rather than diverging from what SKILL.md actually says.
CTX_ENV_PATH=/tmp/vercel-deploy-ctx.env
CTX_ENV_BACKUP=$(mktemp)
if [ -e "$CTX_ENV_PATH" ]; then cp "$CTX_ENV_PATH" "$CTX_ENV_BACKUP"; else rm -f "$CTX_ENV_BACKUP"; fi

STAGE05_SCRIPT=$(mktemp)
trap '
  rm -rf "$STAGE05_SCRIPT" "$MOCK_DIR"
  if [ -e "$CTX_ENV_BACKUP" ]; then cp "$CTX_ENV_BACKUP" "$CTX_ENV_PATH"; else rm -f "$CTX_ENV_PATH"; fi
  rm -f "$CTX_ENV_BACKUP"
' EXIT
extract_stage05 > "$STAGE05_SCRIPT"

MOCK_DIR=$(mktemp -d)
mkdir -p "$MOCK_DIR/bin"

STALE_ID="dpl_9gcENKpM7TtLoetZFxoJDVjhF11Y"
NEW_ID="dpl_2CChZ3ppJktkUwjM4F9Cxk83M6ts"
HEAD_SHA_FULL="2CChZ3ppJktkUwjM4F9Cxk83M6tsdeadbeefcafe"

cat > "$MOCK_DIR/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "rev-parse" ] && [ "\$2" = "HEAD" ]; then
  echo "$HEAD_SHA_FULL"
  exit 0
fi
echo "mock git: unhandled invocation: \$*" >&2
exit 1
EOF
chmod +x "$MOCK_DIR/bin/git"

cat > "$MOCK_DIR/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "CURL_CALL: $*" >> "$CURL_LOG"
URL="${@: -1}"
case "$URL" in
  */v4/aliases/*)
    [ "${ALIAS_API_FAIL:-false}" = true ] && exit 22
    cat "$ALIAS_RESPONSE_FILE"
    ;;
  *api/version*)
    [ "${VERSION_API_FAIL:-false}" = true ] && exit 22
    cat "$VERSION_RESPONSE_FILE"
    ;;
  https://*)
    [ "${HTTP_STATUS_MOCK:-200}" = "FAIL" ] && exit 22
    echo -n "${HTTP_STATUS_MOCK:-200}"
    ;;
  *)
    echo "mock curl: unhandled URL: $URL" >&2
    exit 1
    ;;
esac
MOCKEOF
chmod +x "$MOCK_DIR/bin/curl"

assert_eq() {
  local expected=$1 actual=$2 scenario=$3
  [ "$expected" = "$actual" ] || {
    printf 'FAIL %s: expected %s, got %s\n' "$scenario" "$expected" "$actual" >&2
    exit 1
  }
}

assert_contains() {
  local haystack=$1 needle=$2 scenario=$3
  case "$haystack" in
    *"$needle"*) ;;
    *)
      printf 'FAIL %s: expected output to contain %q\nACTUAL OUTPUT:\n%s\n' "$scenario" "$needle" "$haystack" >&2
      exit 1
      ;;
  esac
}

run_stage05() {
  cat > "$CTX_ENV_PATH" <<EOF
PROD_DOMAIN=pylot.fellowship.dev
VERCEL_ORG_ID=team_mockorg
VERCEL_TOKEN=mock-token-not-real
NEW_DEPLOYMENT_ID=$NEW_ID
VERSION_CHECK_PATH=${VERSION_CHECK_PATH:-}
EOF
  CURL_LOG="$MOCK_DIR/curl.log" \
  ALIAS_RESPONSE_FILE="$MOCK_DIR/alias_response.json" \
  VERSION_RESPONSE_FILE="$MOCK_DIR/version_response.json" \
  HTTP_STATUS_MOCK="${HTTP_STATUS_MOCK:-200}" \
  ALIAS_API_FAIL="${ALIAS_API_FAIL:-false}" \
  VERSION_API_FAIL="${VERSION_API_FAIL:-false}" \
  VERSION_CHECK_PATH="${VERSION_CHECK_PATH:-}" \
  PATH="$MOCK_DIR/bin:$PATH" \
    bash -c "source '$STAGE05_SCRIPT'" 2>&1
}

# Scenario 1: alias still points at a stale deployment — the exact pylot#3690 incident.
# Must now fail closed and name both ids, where the pre-fix code reported status=success.
printf '{"alias":"pylot.fellowship.dev","deploymentId":"%s"}' "$STALE_ID" > "$MOCK_DIR/alias_response.json"
unset VERSION_CHECK_PATH
OUTPUT=$(run_stage05) && EXIT=0 || EXIT=$?
assert_eq 1 "$EXIT" stale-alias-must-fail
assert_contains "$OUTPUT" "$STALE_ID" stale-alias-names-stale-id
assert_contains "$OUTPUT" "$NEW_ID" stale-alias-names-new-id
printf 'PASS stale-alias-fails-naming-both-ids\n'

# Scenario 2: alias matches the deployment just created, no VERSION_CHECK_PATH — must pass.
printf '{"alias":"pylot.fellowship.dev","deploymentId":"%s"}' "$NEW_ID" > "$MOCK_DIR/alias_response.json"
unset VERSION_CHECK_PATH
OUTPUT=$(run_stage05) && EXIT=0 || EXIT=$?
assert_eq 0 "$EXIT" matching-alias-passes
assert_contains "$OUTPUT" "Stage 05 complete" matching-alias-reaches-complete
assert_contains "$OUTPUT" "version check skipped" matching-alias-skips-version-check-when-unset
printf 'PASS matching-alias-passes-version-check-skipped\n'

# Scenario 3: alias matches AND VERSION_CHECK_PATH set with a build id that is a HEAD prefix.
printf '{"alias":"pylot.fellowship.dev","deploymentId":"%s"}' "$NEW_ID" > "$MOCK_DIR/alias_response.json"
printf '{"buildId":"%s"}' "${HEAD_SHA_FULL:0:8}" > "$MOCK_DIR/version_response.json"
VERSION_CHECK_PATH=/api/version
OUTPUT=$(run_stage05) && EXIT=0 || EXIT=$?
assert_eq 0 "$EXIT" version-check-prefix-matches
assert_contains "$OUTPUT" "version check passed" version-check-passed-message
printf 'PASS version-check-matching-buildid-passes\n'

# Scenario 4: alias matches but the served buildId is NOT a prefix of HEAD — must fail.
printf '{"buildId":"deadbeef"}' > "$MOCK_DIR/version_response.json"
VERSION_CHECK_PATH=/api/version
OUTPUT=$(run_stage05) && EXIT=0 || EXIT=$?
assert_eq 1 "$EXIT" version-check-mismatch-fails
assert_contains "$OUTPUT" "is not a prefix of HEAD" version-check-mismatch-message
printf 'PASS version-check-mismatched-buildid-fails\n'
unset VERSION_CHECK_PATH

# Scenario 5: the original HTTP-status check must still gate — not regressed by the new checks.
HTTP_STATUS_MOCK=500
OUTPUT=$(run_stage05) && EXIT=0 || EXIT=$?
assert_eq 1 "$EXIT" http-500-still-fails
assert_contains "$OUTPUT" "returned HTTP 500" http-500-message
printf 'PASS http-status-check-still-gates\n'

# Scenario 6: the alias-lookup curl itself fails (network/timeout) — must fail closed, naming the
# lookup failure distinctly from a stale-alias id mismatch. Exercises the mock's ALIAS_API_FAIL
# injection, which existed but was never set by any scenario before this one.
HTTP_STATUS_MOCK=200
ALIAS_API_FAIL=true
OUTPUT=$(run_stage05) && EXIT=0 || EXIT=$?
assert_eq 1 "$EXIT" alias-api-failure-fails
assert_contains "$OUTPUT" "could not read aliased deployment id" alias-api-failure-message
ALIAS_API_FAIL=false
printf 'PASS alias-api-failure-fails-closed\n'

# Scenario 7: the version-check curl itself fails when VERSION_CHECK_PATH is set — must fail
# closed, naming the missing buildId distinctly from a buildId-prefix mismatch. Exercises the
# mock's VERSION_API_FAIL injection, which existed but was never set by any scenario before this.
printf '{"alias":"pylot.fellowship.dev","deploymentId":"%s"}' "$NEW_ID" > "$MOCK_DIR/alias_response.json"
VERSION_CHECK_PATH=/api/version
VERSION_API_FAIL=true
OUTPUT=$(run_stage05) && EXIT=0 || EXIT=$?
assert_eq 1 "$EXIT" version-api-failure-fails
assert_contains "$OUTPUT" "no buildId in response" version-api-failure-message
VERSION_API_FAIL=false
unset VERSION_CHECK_PATH

printf 'PASS version-api-failure-fails-closed\n'
printf 'PASS stage-05-verify (pylot#3690)\n'
