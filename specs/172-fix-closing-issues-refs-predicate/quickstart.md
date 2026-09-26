# Quickstart: Verify the closingIssuesReferences Predicate Fix

**Prerequisite**: `jq` on `PATH` (jq-1.7 locally, present on `ubuntu-latest`) — already a runtime
dependency of `pr-postcondition.sh`; the test no longer stubs it out.

1. `bash skills/ops/speckit-runner/tests/pr-postcondition.test.sh` → all cases PASS, exit 0.
2. Confirm the corrected predicate accepts a same-number ref in the correct repo (existing
   `head-and-linkage-accepted` case) and still rejects a wrong-head PR and a PR with no closing
   linkage at all (existing `wrong-head-rejected`, `issue-linkage-remains-required` cases).
3. Confirm the new wrong-repo case: same issue number, different `owner.login`/`name` → rejected.
4. Fail-closed spot checks: a fixture with `repository` omitted from the reference, and a fixture
   with an empty `closingIssuesReferences` array — both reject cleanly (exit 1), never a jq error
   (`set -eu` in the test harness would surface a jq crash as a nonzero exit from the wrong line;
   confirm the failure is `verify_pr_postcondition`'s own `return 1`, not a jq stack trace).
5. **Must-fail-before check (primary acceptance evidence)**: revert only the predicate in
   `pr-postcondition.sh` back to `.repository.nameWithOwner`, leave `SKILL.md` and the test fixture
   fixed, re-run the suite → it must FAIL. Restore the fix. Paste both outputs (red, then green) in
   the PR.
6. `grep -rn '\.repository\.nameWithOwner' skills/ops/speckit-runner/` → zero results.
7. `diff <(grep -A1 'any(.closingIssuesReferences' skills/ops/speckit-runner/shared/pr-postcondition.sh) <(grep -A1 'any(.closingIssuesReferences' skills/ops/speckit-runner/SKILL.md)` → confirms both sites carry the identical predicate text (adjust the grep context if line wrapping differs; the point is a byte-level diff of the predicate clause, not the whole file).
8. `git diff --stat` → only the 3 scope-fenced files (+ optional new fixture) changed.
