# Deliver

Create the PR, run final review, and verify the deliverable is complete.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/04-implement/result.md` | Full file | Implementation status and test results |
| Reference | `references/pr-template.md` | Full file | PR title and body format |

## Process

1. Read the implementation output. Confirm tests passed and code is committed.

2. Commit spec files if not already committed:
   ```bash
   git add specs/ && git diff --cached --quiet || git commit -m "docs: add speckit specs for issue #$ISSUE"
   ```

3. Push the feature branch:
   ```bash
   git push origin $(git branch --show-current)
   ```

4. Create the PR using format from `references/pr-template.md`:
   ```bash
   gh pr create --repo $1 --head $(git branch --show-current) --base $DEFAULT_BRANCH \
     --title "<type>: <description> (#$ISSUE)" --body "<from template>"
   ```

5. Run the review phases with fresh eyes -- you wrote this code, now challenge it:
   ```
   /speckit-analyze $ISSUE
   /speckit-checklist $ISSUE
   ```
   If issues found, fix them, commit, and push.

6. Final verification (all mandatory):
   - [ ] PR exists and is open: `gh pr view --repo $1`
   - [ ] Tests pass (re-run yourself, do not trust earlier output)
   - [ ] Spec files are in the PR diff
   - [ ] PR body links to the source issue

7. Write delivery report and emit outcome marker.

## Audit

| Check | Pass Condition |
|-------|---------------|
| PR is open | `gh pr view` returns state OPEN |
| Issue linked | PR body contains `#$ISSUE` or full issue URL |
| Specs committed | PR diff includes files under `specs/` |
| Tests pass | Test suite exits 0 after review fixes |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Delivery report | `.procedure-output/speckit-proc/05-deliver/report.md` | Markdown: PR number, URL, check results, outcome |
