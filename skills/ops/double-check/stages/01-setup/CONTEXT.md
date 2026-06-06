# Stage 01: Setup (subagent)

## Inputs
- `pr` and `repo` (passed in the Task prompt)
- `GH_TOKEN` in the environment

No upstream handoffs — this is the first stage.

## Task
Gather everything the review stage needs and prepare a clean local working tree:
PR metadata, CI status, the existing (first) review comments, the full diff, and a checked-out
PR branch with the base branch merged in (to surface conflicts early).

## Steps

```bash
export PR={pr}      # PR number
export REPO={repo}  # org/repo
```

### Fetch PR metadata

```bash
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

# Extract key info
PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')
PR_BRANCH=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')
```

### Check CI status (best-effort — may fail with PAT)

```bash
gh pr checks $PR --repo $REPO 2>/dev/null || echo "CI checks not accessible via token"
```

### Read ALL existing PR review comments (the "first review")

```bash
gh pr view $PR --repo $REPO --json comments --jq '.comments[].body'
gh pr view $PR --repo $REPO --json reviews --jq '.reviews[].body'
```

Capture every finding from automated CI / the Claude GitHub App / bots verbatim — the review
stage curates these in a clean context, so they must be carried over faithfully (never pre-curated here).

### Read the full diff

```bash
# Get diff (full)
gh pr diff $PR --repo $REPO

# Get changed file names
gh pr diff $PR --repo $REPO --name-only
```

Include the full diff text in the handoff. The review stage works only from this handoff.

### Checkout PR branch + merge base

```bash
REPO_NAME=$(echo $REPO | cut -d/ -f2)
REPO_DIR="/tmp/double-check-$REPO_NAME"

if [ ! -d "$REPO_DIR" ]; then
  git clone "https://github.com/$REPO.git" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch origin $PR_BRANCH
git checkout $PR_BRANCH
git pull origin $PR_BRANCH

# Merge base branch to catch conflicts
git fetch origin $BASE_BRANCH
git merge origin/$BASE_BRANCH --no-edit || {
  echo "Merge conflict — resolve manually"
  exit 1
}
```

If the merge conflicts (or the PR can't be fetched/checked out), write the handoff with
`setup_ok: false` and the reason — the orchestrator will treat this as a blocked exit.

## Output: handoff.md

Path: `.procedure-output/double-check/01-setup/handoff.md`

```markdown
# Stage 01: Setup

setup_ok: {true|false}

## PR
- Number: {PR}
- Title: {PR_TITLE}
- URL: {PR_URL}
- Branch: `{PR_BRANCH}` → `{BASE_BRANCH}`
- Author: {author}
- Size: +{additions} / -{deletions}, {N} files, {N} commits
- Labels: {labels or none}

## Local Checkout
- REPO_DIR: {REPO_DIR}
- Checked out: `{PR_BRANCH}` with `{BASE_BRANCH}` merged
- Merge conflict: {none | details}

## CI Status
{gh pr checks output, or "not accessible via token"}

## PR Body
{PR body verbatim}

## First Review (existing comments + reviews, verbatim)
{every finding from CI / bots / reviewers, verbatim — or "No existing review comments found"}

## Changed Files
{name list}

## Full Diff
{full diff text}
```

## Success criteria
- `setup_ok: true`
- PR metadata, CI status, first review (verbatim), changed files, and full diff all captured
- PR branch checked out in REPO_DIR with base merged; REPO_DIR recorded for downstream stages

## Failure
- PR not found / `gh` error / merge conflict → write handoff with `setup_ok: false` + reason
  (orchestrator emits a blocked outcome)
