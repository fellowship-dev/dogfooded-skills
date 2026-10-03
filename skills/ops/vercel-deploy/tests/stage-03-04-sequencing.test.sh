#!/usr/bin/env bash
set -euo pipefail

# Regression test for review finding R1 on pylot#3690 (dogfooded-skills PR #197): the first cut of
# the alias-verification fix ran `vercel alias set` in Stage 03, immediately after `vercel deploy
# --prod` returned, BEFORE Stage 04 confirmed the deployment reached READY. A deployment that later
# went ERROR/CANCELED would already have prod traffic aliased to it, with no revert logic -- a new
# production-routing race introduced by the very fix meant to prevent stale-alias incidents. This
# test extracts Stage 03's and Stage 04's *actual* bash fences live out of SKILL.md (not a
# hand-copied mimic) and asserts `vercel alias set` is invoked only from Stage 04's READY branch,
# never from Stage 03, and never when the deployment goes ERROR.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL_MD="$ROOT/SKILL.md"

extract_stage() {
  python3 - "$SKILL_MD" "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
heading = sys.argv[2]
after = text.split(heading, 1)[1]
m = re.search(r"```bash\n(.*?)\n```", after, re.DOTALL)
if not m:
    sys.exit(f"{heading} bash fence not found")
sys.stdout.write(m.group(1))
PYEOF
}

# Stage 03/04's extracted scripts do `source /tmp/vercel-deploy-ctx.env` as their first line (the
# real inter-stage contract) -- write fixtures to that exact path and restore whatever was there
# before, rather than diverging from what SKILL.md actually says.
CTX_ENV_PATH=/tmp/vercel-deploy-ctx.env
CTX_ENV_BACKUP=$(mktemp)
if [ -e "$CTX_ENV_PATH" ]; then cp "$CTX_ENV_PATH" "$CTX_ENV_BACKUP"; else rm -f "$CTX_ENV_BACKUP"; fi

STAGE03_SCRIPT=$(mktemp)
STAGE04_SCRIPT=$(mktemp)
MOCK_DIR=$(mktemp -d)
DEPLOY_DIR=$(mktemp -d)
trap '
  rm -rf "$STAGE03_SCRIPT" "$STAGE04_SCRIPT" "$MOCK_DIR" "$DEPLOY_DIR"
  if [ -e "$CTX_ENV_BACKUP" ]; then cp "$CTX_ENV_BACKUP" "$CTX_ENV_PATH"; else rm -f "$CTX_ENV_PATH"; fi
  rm -f "$CTX_ENV_BACKUP"
' EXIT

extract_stage "## Stage 03" > "$STAGE03_SCRIPT"
extract_stage "## Stage 04" > "$STAGE04_SCRIPT"

mkdir -p "$MOCK_DIR/bin"

NEW_ID="dpl_2CChZ3ppJktkUwjM4F9Cxk83M6ts"
DEPLOY_HOST="mock-deployment-xyz.vercel.app"

# Mock `npx`: `vercel deploy --prod ...` prints a deployment URL; `vercel alias set ...` logs the
# call (so we can assert whether/when it fired) and exits per ALIAS_SET_EXIT_MOCK.
cat > "$MOCK_DIR/bin/npx" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "vercel" ] && [ "$2" = "deploy" ]; then
  echo "https://$DEPLOY_HOST_MOCK"
  exit 0
fi
if [ "$1" = "vercel" ] && [ "$2" = "alias" ]; then
  echo "ALIAS_SET_CALL: $*" >> "$CALL_LOG"
  exit "${ALIAS_SET_EXIT_MOCK:-0}"
fi
echo "mock npx: unhandled invocation: $*" >&2
exit 1
EOF
chmod +x "$MOCK_DIR/bin/npx"

# Mock `curl`: only used by Stage 04's poll loop here. Returns a canned deployments response
# based on POLL_STATE_MOCK, so each scenario resolves on its first poll (no 10s sleeps).
cat > "$MOCK_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${POLL_STATE_MOCK:-READY}" in
  READY)
    printf '{"deployments":[{"state":"READY","uid":"%s"}]}' "$NEW_ID_MOCK"
    ;;
  ERROR)
    printf '{"deployments":[{"state":"ERROR"}]}'
    ;;
  EMPTY_ID)
    printf '{"deployments":[{"state":"READY"}]}'
    ;;
  *)
    echo "mock curl: unhandled POLL_STATE_MOCK: ${POLL_STATE_MOCK:-}" >&2
    exit 1
    ;;
esac
EOF
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

reset_call_log() { : > "$MOCK_DIR/call.log"; }
call_log_contents() { cat "$MOCK_DIR/call.log" 2>/dev/null || true; }

run_stage03() {
  cat > "$CTX_ENV_PATH" <<EOF
DEPLOY_BRANCH=main
DEPLOY_DIR=$DEPLOY_DIR
PROD_DOMAIN=pylot.fellowship.dev
EOF
  CALL_LOG="$MOCK_DIR/call.log" \
  DEPLOY_HOST_MOCK="$DEPLOY_HOST" \
  VERCEL_TOKEN=mock-token-not-real \
  VERCEL_ORG_ID=team_mockorg \
  PATH="$MOCK_DIR/bin:$PATH" \
    bash -c "source '$STAGE03_SCRIPT'" 2>&1
}

run_stage04() {
  CALL_LOG="$MOCK_DIR/call.log" \
  NEW_ID_MOCK="$NEW_ID" \
  VERCEL_TOKEN=mock-token-not-real \
  VERCEL_ORG_ID=team_mockorg \
  POLL_STATE_MOCK="${POLL_STATE_MOCK:-READY}" \
  ALIAS_SET_EXIT_MOCK="${ALIAS_SET_EXIT_MOCK:-0}" \
  PATH="$MOCK_DIR/bin:$PATH" \
    bash -c "source '$STAGE04_SCRIPT'" 2>&1
}

# Scenario 1: the R1 race itself. Deploy succeeds (Stage 03), but the deployment then goes ERROR
# (Stage 04). `vercel alias set` must NEVER be called -- this is exactly the sequencing bug: the
# pre-fix Stage 03 called alias set unconditionally, before Stage 04 even ran, so an ERROR outcome
# here was aliased anyway.
reset_call_log
STAGE03_OUT=$(run_stage03) && STAGE03_EXIT=0 || STAGE03_EXIT=$?
assert_eq 0 "$STAGE03_EXIT" error-path-stage03-succeeds
case "$(call_log_contents)" in
  *ALIAS_SET_CALL*)
    printf 'FAIL error-path-no-alias-before-ready: alias set was called during/after Stage 03, before Stage 04 ran\n' >&2
    exit 1
    ;;
esac
POLL_STATE_MOCK=ERROR
STAGE04_OUT=$(run_stage04) && STAGE04_EXIT=0 || STAGE04_EXIT=$?
assert_eq 1 "$STAGE04_EXIT" error-path-stage04-fails
assert_contains "$STAGE04_OUT" "terminal state ERROR" error-path-message
case "$(call_log_contents)" in
  *ALIAS_SET_CALL*)
    printf 'FAIL error-path-no-alias-ever: alias set was called even though the deployment went ERROR\n' >&2
    exit 1
    ;;
esac
printf 'PASS error-path-never-aliases-a-dead-deployment\n'

# Scenario 2: happy path. Stage 03 must not touch the alias; Stage 04 must set it exactly once,
# after READY and after NEW_DEPLOYMENT_ID is captured.
reset_call_log
run_stage03 >/dev/null
case "$(call_log_contents)" in
  *ALIAS_SET_CALL*)
    printf 'FAIL happy-path-stage03-no-alias: Stage 03 called vercel alias set\n' >&2
    exit 1
    ;;
esac
POLL_STATE_MOCK=READY
# NB: Stage 04's bash fence ends with `[ $ELAPSED -ge $MAX_WAIT ] && { ...; exit 1; }` -- a
# pre-existing (pre-dates this PR) shell idiom where the trailing `&&` leaks the guard's own
# false/1 exit status as the script's exit status on every non-timeout path, success included.
# So sourcing Stage 04 standalone always yields exit 1 here regardless of outcome; assert success
# via message content instead of exit code (same approach would apply to a timeout, were it
# exercised here).
STAGE04_OUT=$(run_stage04) || true
assert_contains "$STAGE04_OUT" "Stage 04 complete" happy-path-reaches-complete
case "$STAGE04_OUT" in
  *"Stage 04 failed"*)
    printf 'FAIL happy-path-no-failure-message: unexpected failure message in output:\n%s\n' "$STAGE04_OUT" >&2
    exit 1
    ;;
esac
assert_contains "$STAGE04_OUT" "alias set to pylot.fellowship.dev" happy-path-message
ALIAS_CALLS=$(grep -c "ALIAS_SET_CALL" "$MOCK_DIR/call.log" || true)
assert_eq 1 "$ALIAS_CALLS" happy-path-alias-called-exactly-once
grep "ALIAS_SET_CALL" "$MOCK_DIR/call.log" | grep -q "https://$DEPLOY_HOST pylot.fellowship.dev" || {
  printf 'FAIL happy-path-alias-args: alias set was not called with the deployed URL and PROD_DOMAIN\n' >&2
  exit 1
}
printf 'PASS happy-path-aliases-exactly-once-after-ready\n'

# Scenario 3 (D1): Stage 04 must fail closed when the alias-set call itself fails, after READY.
POLL_STATE_MOCK=READY
ALIAS_SET_EXIT_MOCK=3
STAGE04_OUT=$(run_stage04) && STAGE04_EXIT=0 || STAGE04_EXIT=$?
assert_eq 1 "$STAGE04_EXIT" alias-set-failure-fails-stage04
assert_contains "$STAGE04_OUT" "vercel alias set exited 3" alias-set-failure-message
unset ALIAS_SET_EXIT_MOCK
printf 'PASS stage04-fails-closed-on-alias-set-failure\n'

# Scenario 4 (D1): Stage 04 must fail closed, without ever calling alias set, when the deployment
# reports READY but the API response carries no deployment id.
reset_call_log
POLL_STATE_MOCK=EMPTY_ID
STAGE04_OUT=$(run_stage04) && STAGE04_EXIT=0 || STAGE04_EXIT=$?
assert_eq 1 "$STAGE04_EXIT" empty-id-fails-stage04
assert_contains "$STAGE04_OUT" "READY but no id in API response" empty-id-message
case "$(call_log_contents)" in
  *ALIAS_SET_CALL*)
    printf 'FAIL empty-id-no-alias-call: alias set was called despite no deployment id\n' >&2
    exit 1
    ;;
esac
printf 'PASS stage04-fails-closed-on-empty-deployment-id\n'

printf 'PASS stage-03-04-sequencing (pylot#3690 / review finding R1)\n'
