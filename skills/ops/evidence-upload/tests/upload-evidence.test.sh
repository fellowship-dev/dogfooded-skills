#!/usr/bin/env bash
# Behavior tests for scripts/upload_evidence.sh against a stub `curl` (no network).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
UP="$ROOT/scripts/upload_evidence.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/files"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "curl ${STUB_CURL_VERSION:-8.7.1} (stub)"; exit 0; fi
printf '%s\n' "$*" >> "$CURL_LOG"
prev=""
for a in "$@"; do
  if [ "$prev" = "-K" ]; then
    printf '%s\n' "$a" >> "$CFG_LOG"
    [ "$(stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a")" = "600" ] && echo mode600 >> "$CFG_LOG"
    grep -q 'user = "AKIATEST:sec\\"ret"' "$a" && echo creds-ok >> "$CFG_LOG"
  fi
  prev="$a"
done
case "$*" in
  *" -T "*) printf '%s' "${STUB_PUT:-200}" ;;
  *) printf '%s' "${STUB_HEAD:-200}" ;;
esac
STUB
chmod +x "$TMP/bin/curl"
printf 'png' > "$TMP/files/Step 01 navigate.png"
printf 'gif' > "$TMP/files/demo.gif"
printf 'zip' > "$TMP/files/dump.zip"
export PATH="$TMP/bin:$PATH" CURL_LOG="$TMP/curl.log" CFG_LOG="$TMP/cfg.log"
ENVS=(EVIDENCE_AWS_ACCESS_KEY_ID=AKIATEST 'EVIDENCE_AWS_SECRET_ACCESS_KEY=sec"ret'
  EVIDENCE_BUCKET=test-bucket EVIDENCE_REGION=us-east-1
  EVIDENCE_PUBLIC_BASE_URL=https://test-bucket.s3.us-east-1.amazonaws.com/)
BASE=https://test-bucket.s3.us-east-1.amazonaws.com
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# 1. Missing env secret fails clearly, exit 2.
set +e
out=$(env -u EVIDENCE_AWS_ACCESS_KEY_ID -u EVIDENCE_AWS_SECRET_ACCESS_KEY bash "$UP" --repo o/r "$TMP/files/demo.gif" 2>&1); code=$?
set -e
[ "$code" = 2 ] && printf '%s' "$out" | grep -q 'not configured for this environment' \
  && pass missing-env || bad "missing-env: code=$code out=$out"

# 2. Credentials are never accepted as arguments.
set +e
env "${ENVS[@]}" bash "$UP" --access-key X --repo o/r "$TMP/files/demo.gif" >/dev/null 2>&1; code=$?
set -e
[ "$code" = 2 ] && pass reject-cred-args || bad "reject-cred-args: code=$code"

# 3. Dry-run key layout: owner/repo/YYYY/MM/<sha16>-<sanitized>.
h=$( (command -v sha256sum >/dev/null && sha256sum "$TMP/files/Step 01 navigate.png" || shasum -a 256 "$TMP/files/Step 01 navigate.png") | cut -c1-16)
out=$(env "${ENVS[@]}" bash "$UP" --dry-run --repo acme/app "$TMP/files/Step 01 navigate.png")
want="key: acme/app/$(date -u +%Y/%m)/${h}-Step-01-navigate.png"
printf '%s\n' "$out" | grep -qxF "$want" && printf '%s\n' "$out" | grep -qxF "url: $BASE/acme/app/$(date -u +%Y/%m)/${h}-Step-01-navigate.png" \
  && pass dry-run-key || bad "dry-run-key: $out"

# 4. --prefix replaces the date segment; repo from an ssh origin remote.
git -C "$TMP" init -q repo && git -C "$TMP/repo" remote add origin git@github.com:Org/Some.repo.git
out=$(cd "$TMP/repo" && env "${ENVS[@]}" bash "$UP" --dry-run --prefix _smoke "$TMP/files/demo.gif")
printf '%s\n' "$out" | grep -Eq '^key: Org/Some\.repo/_smoke/[0-9a-f]{16}-demo\.gif$' && pass prefix-and-remote || bad "prefix-and-remote: $out"

# 4b. Unsafe prefix characters are sanitized; dot segments rejected.
out=$(env "${ENVS[@]}" bash "$UP" --dry-run --repo o/r --prefix "Sign up flow/2026-10-13" "$TMP/files/demo.gif")
printf '%s\n' "$out" | grep -Eq '^key: o/r/Sign-up-flow/2026-10-13/[0-9a-f]{16}-demo\.gif$' && pass prefix-sanitized || bad "prefix-sanitized: $out"
set +e
env "${ENVS[@]}" bash "$UP" --dry-run --repo o/r --prefix "a/../b" "$TMP/files/demo.gif" >/dev/null 2>&1; code=$?
set -e
[ "$code" = 2 ] && pass prefix-dotdot || bad "prefix-dotdot: code=$code"

# 5. Unsupported extension fails that file (exit 1) without uploading.
: > "$CURL_LOG"
set +e
env "${ENVS[@]}" bash "$UP" --repo o/r "$TMP/files/dump.zip" >/dev/null 2>&1; code=$?
set -e
[ "$code" = 1 ] && [ ! -s "$CURL_LOG" ] && pass unsupported-ext || bad "unsupported-ext: code=$code"

# 6. Upload path: signed PUT with headers, creds via 0600 -K file, verified HEAD, URL + Markdown.
: > "$CURL_LOG"; : > "$CFG_LOG"
out=$(env "${ENVS[@]}" bash "$UP" --repo o/r --alt "Step 1" "$TMP/files/Step 01 navigate.png" "$TMP/files/demo.gif")
url1=$(printf '%s\n' "$out" | sed -n 1p)
case "$url1" in "$BASE/o/r/"*"-Step-01-navigate.png") pass url-line ;; *) bad "url-line: $out" ;; esac
printf '%s\n' "$out" | sed -n 2p | grep -qxF "![Step 1]($url1)" && pass markdown-line || bad "markdown-line: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4 ] && pass two-files || bad "two-files: $out"
grep -q -- '--aws-sigv4 aws:amz:us-east-1:s3' "$CURL_LOG" && grep -q 'Content-Type: image/gif' "$CURL_LOG" \
  && grep -q 'Cache-Control: public, max-age=31536000, immutable' "$CURL_LOG" && grep -q -- '-sI' "$CURL_LOG" \
  && pass put-headers || bad "put-headers: $(cat "$CURL_LOG")"
if grep -q 'AKIATEST\|sec"ret' "$CURL_LOG"; then bad "creds-in-argv"; else pass creds-not-in-argv; fi
grep -q creds-ok "$CFG_LOG" && grep -q mode600 "$CFG_LOG" && pass creds-config-file || bad "creds-config-file: $(cat "$CFG_LOG")"
cfg=$(head -1 "$CFG_LOG"); [ ! -e "$cfg" ] && pass config-removed || bad "config-removed: $cfg"

# 7. Public URL not 200 -> failure, no URL printed.
set +e
out=$(env "${ENVS[@]}" STUB_HEAD=403 bash "$UP" --repo o/r "$TMP/files/demo.gif" 2>/dev/null); code=$?
set -e
[ "$code" = 1 ] && [ -z "$out" ] && pass head-verify || bad "head-verify: code=$code out=$out"

# 8. Old curl is rejected clearly.
set +e
out=$(env "${ENVS[@]}" STUB_CURL_VERSION=7.68.0 bash "$UP" --repo o/r "$TMP/files/demo.gif" 2>&1); code=$?
set -e
[ "$code" = 2 ] && printf '%s' "$out" | grep -q '>= 7.75' && pass old-curl || bad "old-curl: $out"

exit "$fail"
