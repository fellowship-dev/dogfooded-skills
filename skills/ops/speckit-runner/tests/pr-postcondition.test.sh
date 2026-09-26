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
make_fixture wrong-owner "$BRANCH" yes other-org example
assert_case wrong-owner-only-rejected 1
make_fixture wrong-repo-name "$BRANCH" yes fellowship-dev other-example
assert_case wrong-repo-only-rejected 1
make_fixture missing-refs "$BRANCH" yes
python3 - "$PR_FIXTURE" <<'PYFIXTURE'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
del data["closingIssuesReferences"]
path.write_text(json.dumps(data))
PYFIXTURE
assert_case missing-refs-rejected 1
make_fixture_missing_repo_key missing-repo-key "$BRANCH"
assert_case missing-repo-key-rejected 1

# Exercise the actual Step 0 jq expression, not a duplicated predicate.
python3 - "$ROOT/SKILL.md" <<'PYTEST'
import json
from pathlib import Path
import re
import subprocess
import sys

skill = Path(sys.argv[1]).read_text()
start = skill.index("EXISTING_PR=$(printf")
end = skill.index("\n\n", start)
block = skill[start:end]
match = re.search(r"--arg repo \"\$REPO\" '([\s\S]+)'\)", block)
assert match, "Step 0 EXISTING_PR jq expression not found"
predicate = match.group(1)

def pr(number, owner="fellowship-dev", repo="example", refs=True):
    item = {"number": number, "url": f"https://example.test/pr/{number}", "headRefName": f"branch-{number}"}
    item["closingIssuesReferences"] = ([{"id": "I_test", "number": 141,
        "repository": {"id": "R_test", "name": repo, "owner": {"id": "O_test", "login": owner}},
        "url": "https://example.test/issues/141"}] if refs else [])
    return item

missing = pr(7)
del missing["closingIssuesReferences"]
for name, payload, expected in [
    ("matching-existing-pr-reused", [pr(11, "other-org"), pr(22)], 22),
    ("wrong-owner-not-selected", [pr(11, "other-org")], None),
    ("wrong-repo-not-selected", [pr(11, repo="other-repo")], None),
    ("empty-refs-not-selected", [pr(11, refs=False)], None),
    ("missing-refs-not-selected", [missing], None),
]:
    output = subprocess.check_output(["jq", "-c", "--argjson", "issue", "141", "--arg", "repo",
        "fellowship-dev/example", predicate], input=json.dumps(payload), text=True).strip()
    actual = json.loads(output)["number"] if output else None
    assert actual == expected, f"{name}: expected {expected}, got {actual}"
    print(f"PASS Step 0 {name}")
PYTEST

printf 'PASS PR postcondition contract\n'
