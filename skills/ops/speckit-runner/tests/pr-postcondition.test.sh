#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/shared/pr-postcondition.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"
mkdir "$BIN"
export PATH="$BIN:$PATH" GH_CALL_LOG="$TMP/gh-calls"

cat >"$BIN/gh" <<'EOF'
#!/bin/sh
if [ "$1" = pr ] && [ "$2" = list ]; then
  printf '{"number":141}\n'
elif [ "$1" = pr ] && [ "$2" = view ]; then
  printf 'view\n' >>"$GH_CALL_LOG"
  cat "$PR_FIXTURE"
else
  exit 64
fi
EOF
chmod +x "$BIN/gh"

cat >"$BIN/jq" <<'EOF'
#!/usr/bin/python3
import json, sys
args = sys.argv[1:]
query = args[-1]
data = json.load(sys.stdin)
if query.startswith('any('):
    issue = int(args[args.index('--argjson') + 2])
    repo = args[args.index('--arg') + 2]
    ok = any(item.get('number') == issue and item.get('repository', {}).get('nameWithOwner') == repo
             for item in data.get('closingIssuesReferences', []))
    sys.exit(0 if ok else 1)
field = query.split('.')[1].split()[0]
value = data.get(field, '') or ''
print(value if not isinstance(value, (dict, list)) else json.dumps(value))
EOF
chmod +x "$BIN/jq"

make_fixture() {
  PR_FIXTURE="$TMP/$1.json"
  python3 -c 'import json, sys; print(json.dumps({"url":"https://example.test/pr/141", "headRefName":sys.argv[1], "closingIssuesReferences":([] if sys.argv[2] == "no" else [{"number":141,"repository":{"nameWithOwner":"fellowship-dev/example"}}])}))' "$2" "$3" >"$PR_FIXTURE"
  export PR_FIXTURE
}

assert_case() {
  name=$1 expected=$2
  : >"$GH_CALL_LOG"
  if verify_pr_postcondition; then actual=0; else actual=$?; fi
  [ "$actual" = "$expected" ] || { printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2; exit 1; }
  views=$(wc -l <"$GH_CALL_LOG" | tr -d ' ')
  [ "$views" = 1 ] || { printf 'FAIL %s: expected one PR fetch, got %s\n' "$name" "$views" >&2; exit 1; }
  printf 'PASS %s\n' "$name"
}

REPO=fellowship-dev/example BRANCH=141-supervisor-postcondition ISSUE_NUMBER=141
export REPO BRANCH ISSUE_NUMBER

make_fixture matching-head "$BRANCH" yes
assert_case head-and-linkage-accepted 0
make_fixture wrong-head wrong-branch yes
assert_case wrong-head-rejected 1
make_fixture missing-link "$BRANCH" no
assert_case issue-linkage-remains-required 1

printf 'PASS PR postcondition contract\n'
