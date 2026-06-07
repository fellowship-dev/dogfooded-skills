# Stage 02: Create Release Branch (subagent)

## Inputs
- `.procedure-output/release-train-runner/00-claim-compute/handoff.md` (REMOTE_EXEC, REPO_DIR)
- `.procedure-output/release-train-runner/01-preflight/handoff.md` (DEFAULT_BRANCH)

## Task
Cut a fresh release branch from the tip of the default branch on the remote environment.

## Steps

1. Derive the branch name:
```bash
RELEASE_DATE=$(date +%Y-%m-%d)
RELEASE_BRANCH="release/$RELEASE_DATE"
```

2. Create it from the default branch:
```bash
$REMOTE_EXEC "cd $REPO_DIR && git checkout -b $RELEASE_BRANCH origin/$DEFAULT_BRANCH"
```

3. If the branch name is already taken, append a counter and retry: `release/$RELEASE_DATE-2`,
   `release/$RELEASE_DATE-3`, etc. Record the final name actually used.

4. Write handoff.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/02-release-branch/handoff.md`

```markdown
# Stage 02: Release Branch

## Status
branch_ok: {true|false}

## Release Branch
- Name: {release/YYYY-MM-DD or -N variant actually used}
- Cut from: origin/{DEFAULT_BRANCH}
- RELEASE_DATE: {YYYY-MM-DD}
```

## Success criteria
- A release branch exists on the remote env, checked out, based on `origin/$DEFAULT_BRANCH`
- The actual branch name (including any `-N` counter) recorded for downstream stages

## Failure
- Cannot create the branch (e.g. remote unreachable) → `branch_ok: false`, document reason.
  Orchestrator emits `status=failed` at stage 02 and stops.
