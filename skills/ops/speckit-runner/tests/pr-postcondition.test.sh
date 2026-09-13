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

make_fixture() {
  PR_FIXTURE="$TMP/$1.json"
  owner=${4:-fellowship-dev} name=${5:-example}
  python3 -c 'import json, sys; print(json.dumps({"url":"https://example.test/pr/141", "headRefName":sys.argv[1], "closingIssuesReferences":([] if sys.argv[2] == "no" else [{"id":"R_test","number":141,"repository":{"id":"R_repo","name":sys.argv[4],"owner":{"id":"O_test","login":sys.argv[3]}},"url":"https://example.test/issues/141"}])}))' "$2" "$3" "$owner" "$name" >"$PR_FIXTURE"
  export PR_FIXTURE
}

make_fixture_missing_repo_key() {
  PR_FIXTURE="$TMP/$1.json"
  python3 -c 'import json, sys; print(json.dumps({"url":"https://example.test/pr/141", "headRefName":sys.argv[1], "closingIssuesReferences":[{"id":"R_test","number":141,"url":"https://example.test/issues/141"}]}))' "$2" >"$PR_FIXTURE"
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
make_fixture wrong-repo "$BRANCH" yes other-org other-example
assert_case wrong-repo-rejected 1
make_fixture_missing_repo_key missing-repo-key "$BRANCH"
assert_case missing-repo-key-rejected 1

printf 'PASS PR postcondition contract\n'
