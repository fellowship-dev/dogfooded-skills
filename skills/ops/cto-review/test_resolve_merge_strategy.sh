#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolver="$script_dir/resolve-merge-strategy.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/pylot" <<'SH'
#!/usr/bin/env bash
if [ "${PYLOT_TEST_FAIL:-}" = "1" ]; then exit 1; fi
printf '%s' "${PYLOT_TEST_TEAMS:-{\"teams\":[]}}"
SH
chmod +x "$tmp_dir/pylot"

assert_strategy() {
  expected="$1"
  payload="$2"
  actual="$(PYLOT_CLI_BIN="$tmp_dir/pylot" PYLOT_TEST_TEAMS="$payload" "$resolver" Lexgo-cl/rails-backend)"
  if [ "$actual" != "$expected" ]; then
    echo "expected $expected, got $actual for $payload" >&2
    exit 1
  fi
}

assert_strategy auto '{"teams":[{"repos":["Lexgo-cl/rails-backend"],"deploy":{"release_mode":"ship"}}]}'
assert_strategy auto '{"teams":[{"repos":["lexgo-cl/RAILS-BACKEND"],"deploy":{"release_mode":"ship"}}]}'
assert_strategy label-only '{"teams":[{"repos":["Lexgo-cl/rails-backend"],"deploy":{"release_mode":"propose"}}]}'
assert_strategy label-only '{"teams":[{"repos":["Lexgo-cl/rails-backend"],"deploy":null}]}'
assert_strategy label-only '{"teams":[]}'
assert_strategy label-only '{"teams":[{"repos":["Lexgo-cl/rails-backend"],"deploy":{"release_mode":"ship"}},{"repos":["Lexgo-cl/rails-backend"],"deploy":{"release_mode":"propose"}}]}'
assert_strategy label-only '{"teams":[{"repos":["Lexgo-cl/rails-backend"],"deploy":{"release_mode":"ship"}},{"repos":["Lexgo-cl/rails-backend"],"deploy":{"release_mode":"ship"}}]}'
assert_strategy label-only 'not-json'

actual="$(PYLOT_CLI_BIN="$tmp_dir/pylot" PYLOT_TEST_FAIL=1 "$resolver" Lexgo-cl/rails-backend)"
test "$actual" = "label-only"

echo "resolve-merge-strategy: all cases passed"
