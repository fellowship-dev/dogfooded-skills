# Stage 05: Push Branch + Create Release PR (subagent)

## Inputs
- `.procedure-output/release-train-runner/00-claim-compute/handoff.md` (REMOTE_EXEC, REPO_DIR, REPO)
- `.procedure-output/release-train-runner/01-preflight/handoff.md` (DEFAULT_BRANCH, manifest)
- `.procedure-output/release-train-runner/02-release-branch/handoff.md` (RELEASE_BRANCH, RELEASE_DATE)
- `.procedure-output/release-train-runner/03-validate-integrate/handoff.md` (per-PR log, conflicts, skips)
- `.procedure-output/release-train-runner/04-lockfiles/handoff.md` (lockfile result)
- `shared/release-pr-template.md` (PR body template)

## Task
Push the release branch and open ONE release PR with a unified test plan and the full
conflict/skip log. Never force-push. Never merge the release PR — Max reviews and merges it.

## Steps

1. Push the release branch (never force):
```bash
$REMOTE_EXEC "cd $REPO_DIR && git push origin $RELEASE_BRANCH"
```

2. Create the release PR against the default branch using `shared/release-pr-template.md`.
   Fill the body from the upstream handoffs:
   - Included-PRs table + merge/test columns ← stage 03 per-PR log
   - Conflicts Resolved ← stage 03 conflict log
   - Skipped PRs ← stage 01 + stage 03 skips
   - Test Results ← stage 03 + stage 04
   - Manual Test Plan ← combined, deduplicated from each included PR body (stage 01 manifest)
```bash
gh pr create --repo $REPO \
  --base $DEFAULT_BRANCH \
  --head $RELEASE_BRANCH \
  --title "🚂 Release train — $RELEASE_DATE (N PRs)" \
  --body "{filled-in template}"
```

3. Capture the release PR URL and number.

4. Write handoff.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/05-push-release-pr/handoff.md`

```markdown
# Stage 05: Push + Release PR

## Status
release_pr_ok: {true|false}

## Push
{release branch pushed to origin — no force}

## Release PR
- Number: #N
- URL: {url}
- Base: {DEFAULT_BRANCH}
- Head: {RELEASE_BRANCH}
- Included PRs: {count} | Skipped: {count}
```

## Success criteria
- Release branch pushed (no force)
- Exactly one release PR opened against the default branch, NOT merged
- PR body includes the merge-order table, conflict log, skip list, test results, and a unified
  manual test plan

## Failure
- Push rejected or PR creation fails → `release_pr_ok: false`, document reason. Orchestrator
  emits `status=failed` at stage 05 and stops.
