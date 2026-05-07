# Verify

Confirm the worker's deliverable meets quality gates. Check PR state, CI status, and spec completeness.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/02-implement/result.md` | Full file | PR number, branch, worker status |
| Reference | `references/verification-checks.md` | Full file | Detailed check procedures |

## Process

1. Read the implementation output. Extract PR number, branch name, worker exit status.

2. If worker failed with no PR created: emit `[pylot] outcome="worker failed -- no PR" status=failed` and stop.

3. Verify PR exists and is open:
   ```bash
   gh pr view $PR --repo $1 --json state,title,body,headRefName
   ```

4. Check CI/test status:
   ```bash
   gh pr checks $PR --repo $1
   ```
   If checks are still running, wait up to 5 minutes (poll every 30s).

5. Verify PR body references the source issue (contains `#$0` or issue URL).

6. Verify spec files are in the PR diff:
   ```bash
   gh pr diff $PR --repo $1 --name-only | grep "^specs/"
   ```

7. Write verification report with pass/fail for each check.

8. Emit outcome marker based on results (see `references/verification-checks.md` for decision table).

## Audit

| Check | Pass Condition |
|-------|---------------|
| PR is open | `gh pr view` returns state OPEN |
| Issue linked | PR body contains `#$0` or full issue URL |
| Specs committed | PR diff includes at least one file under `specs/` |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Verification report | `.procedure-output/speckit-proc/03-verify/report.md` | Markdown: per-check pass/fail, final outcome |
