# Stage 00: Setup (inline)

## Inputs
- `$ARGUMENTS` — `org/repo --issues 10,14,15,16 [--branch build/name]`

## Task
Establish shared context: resolve the default branch, create the build branch and `build-train`
label, read every batched issue, and block if a build train is already in progress.

## Steps

1. Parse arguments:
   - `REPO` = first positional (`org/repo`)
   - `ISSUE_NUMBERS` = comma-separated value of `--issues` (split on `,`)
   - `BRANCH_ARG` = value of `--branch` (optional)

2. **One-train-per-repo check** — block if an existing build train is open:
```bash
EXISTING=$(git ls-remote --heads origin 'build/*' | awk '{print $2}' | sed 's#refs/heads/##')
if [ -n "$EXISTING" ]; then
  EXISTING_PR=$(gh pr list --repo $REPO --state open --label build-train \
    --json number,headRefName --jq '.[0].number // empty')
fi
```
If `EXISTING_PR` is set (a `build/*` branch exists AND has an open PR labeled `build-train`), set
`blocked: true` and stop (orchestrator emits the blocked marker). A stale branch with no open PR
is not a block — proceed normally.

3. Determine default branch:
```bash
DEFAULT_BRANCH=$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name)
```

4. Create the build branch (append `-2` if it already exists):
```bash
BUILD_BRANCH="${BRANCH_ARG:-build/$(date +%Y-%m-%d)}"
git ls-remote --heads origin "$BUILD_BRANCH" | grep -q . && BUILD_BRANCH="${BUILD_BRANCH}-2"
gh api repos/$REPO/git/refs -X POST \
  -f ref="refs/heads/$BUILD_BRANCH" \
  -f sha="$(gh api repos/$REPO/git/ref/heads/$DEFAULT_BRANCH -q .object.sha)"
```

5. Create the `build-train` label if missing:
```bash
gh label create build-train --repo $REPO --color 1D76DB \
  --description "Part of a build-train batch" 2>/dev/null || true
```

6. Read all issues and build a manifest:
```bash
for ISSUE in $ISSUE_NUMBERS; do
  gh issue view $ISSUE --repo $REPO --json number,title,body,labels,assignees
done
```
For each issue capture: number, title, and a short context summary (key requirements + any
"depends on #N" / "blocked by #N" mentions) for the worker prompts and the dependency planner.

7. Write handoff.

## Output: handoff.md

Path: `.procedure-output/build-train/00-setup/handoff.md`

```markdown
# Stage 00: Setup

## Status
blocked: {true|false}   # true only if a build train already exists
block_reason: {existing branch name, or "none"}

## Config
| Field | Value |
|-------|-------|
| Repo | {org/repo} |
| Default branch | {name} |
| Build branch | {name} |
| Issues | {10,14,15,16} |

## Issue Manifest
| # | Title | Context summary | Dependency hints |
|---|-------|-----------------|------------------|
| 10 | Brand assets | ... | none |
| 14 | Blog pages | ... | depends on #10 (uses brand tokens) |
```

## Success criteria
- Build branch created (or `blocked: true` with reason)
- `build-train` label exists
- Every issue read; manifest row per issue with dependency hints captured

## Failure
- `gh api` ref creation fails → write handoff with `blocked: true`, reason = the error
