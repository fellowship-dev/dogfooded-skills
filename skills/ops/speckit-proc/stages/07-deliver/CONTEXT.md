# Deliver

Resume worker to create the PR, then operator verifies the deliverable via GitHub API.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/06-test/handoff.md` | Full file | Session ID, test status |
| Shared | `../../shared/worker-dispatch.md` | "Resume" section | How to resume the worker |
| Reference | `references/pr-template.md` | Full file | PR title/body format |

## Process

1. Read the test handoff. Confirm tests pass. Extract worker session ID.

2. Build resume prompt (include PR format from `references/pr-template.md`):
   ```
   Commit any uncommitted spec files:
     git add specs/ && git diff --cached --quiet || git commit -m "docs: speckit specs for #$ISSUE"
   Push the branch and create a PR:
     gh pr create --repo $REPO --title "<type>: <desc> (#$ISSUE)" --body "<PR template>"
   Then run /speckit-analyze $ISSUE and /speckit-checklist $ISSUE.
   Fix any issues found, commit, and push.
   Report: PR number, PR URL, analyze/checklist results.
   ```

3. Resume worker per `shared/worker-dispatch.md`.

4. Wait for completion. Read worker log. Extract PR number and URL.

5. Stop worker environment (`/stop-worker`).

6. **Operator verifies via GitHub API:**
   - PR exists and is open: `gh pr view $PR --repo $1 --json state`
   - PR links to issue: body contains `#$ISSUE`
   - Spec files in diff: `gh pr diff $PR --repo $1 --name-only | grep "^specs/"`
   - CI status: `gh pr checks $PR --repo $1`

7. Write handoff with: PR number, URL, verification results, final status.

8. Emit outcome marker based on verification.

## Audit

| Check | Pass Condition |
|-------|---------------|
| PR is open | `gh pr view` returns state OPEN |
| Issue linked | PR body contains `#$ISSUE` or issue URL |
| Specs committed | PR diff includes files under `specs/` |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Delivery handoff | `.procedure-output/speckit-proc/07-deliver/handoff.md` | Markdown: PR number, URL, verification, outcome |
