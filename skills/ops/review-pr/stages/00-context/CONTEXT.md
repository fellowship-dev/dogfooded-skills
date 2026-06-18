# Stage 00: Context (inline)

## Inputs
- PR number + `org/repo` (from invocation: `PR=$1`, `REPO=$2`)
- `GH_TOKEN` in the environment

## Task
Run the dedup gate, then gather all PR context and the full diff that the review subagent will
need. This stage runs inline in the orchestrator — do NOT spawn a Task. Read-only: no checkout, no
fixes, no pushes.

If the dedup gate trips (PR already has the `reviewed` label), the orchestrator emits the
already-complete outcome marker and STOPS — stages 01 and 02 do not run.

## Steps

### Step 0: Dedup Gate

```bash
export PR=$1
export REPO=$2

ALREADY_DONE=$(gh pr view $PR --repo $REPO --json labels --jq '[.labels[].name] | contains(["reviewed"])')
if [ "$ALREADY_DONE" = "true" ]; then
  exit 0
fi
```

If this exits, STOP the whole procedure. Do not spawn stage 01.

### Step 1: Gather Context

```bash
# PR metadata
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')
PR_BRANCH=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')
ADDITIONS=$(gh pr view $PR --repo $REPO --json additions --jq '.additions')
DELETIONS=$(gh pr view $PR --repo $REPO --json deletions --jq '.deletions')
FILE_COUNT=$(gh pr view $PR --repo $REPO --json files --jq '.files | length')

# Repo conventions (best-effort)
DECODE_FLAG="-d"; uname 2>/dev/null | grep -qi darwin && DECODE_FLAG="-D"
gh api repos/$REPO/contents/CLAUDE.md --jq '.content' 2>/dev/null | base64 $DECODE_FLAG 2>/dev/null || echo "(no CLAUDE.md)"

# Existing PR comments (avoid duplicating observations)
gh pr view $PR --repo $REPO --json comments --jq '.comments[].body'
gh pr view $PR --repo $REPO --json reviews --jq '.reviews[].body'

# CI status (best-effort)
gh pr checks $PR --repo $REPO 2>/dev/null || echo "CI checks not accessible"
```

### Step 2: Read the Diff

```bash
# Full diff
gh pr diff $PR --repo $REPO

# Changed file names (for quick overview)
gh pr diff $PR --repo $REPO --name-only
```

Capture the FULL diff into the handoff — the entire diff is reviewed together in stage 01, so the
subagent needs all of it.

### Step 3: Closes vs Refs raw data (for the mandatory check in stage 01)

```bash
gh pr view $PR --repo $REPO --json body --jq '.body' | grep -oE '(Closes|Fixes|Resolves) #[0-9]+' | grep -oE '[0-9]+'
```

For each linked issue number found with a `Closes`/`Fixes`/`Resolves` keyword, capture its
unchecked-acceptance-criteria count so stage 01 can apply the check without re-fetching:

```bash
gh issue view ISSUE_N --repo $REPO --json body --jq '.body' | grep -c '- \[ \]' || echo 0
```

### Step 4: Write handoff

## Output: handoff.md

Path: `.procedure-output/review-pr/00-context/handoff.md`

```markdown
# Stage 00: Context — $REPO PR #$PR

## PR Metadata
- Title: {PR_TITLE}
- URL: {PR_URL}
- Branch: {PR_BRANCH} → {BASE_BRANCH}
- Author: {author}
- Size: +{ADDITIONS} / -{DELETIONS} across {FILE_COUNT} files
- Labels: {labels}

## PR Body
{full PR body}

## Repo Conventions (CLAUDE.md)
{full CLAUDE.md content, or "(no CLAUDE.md)"}

## Existing Comments / Reviews
{existing comment + review bodies, or "(none)"}

## CI Status
{gh pr checks output, or "CI checks not accessible"}

## Changed Files
{name-only list}

## Full Diff
```diff
{the complete gh pr diff output}
```

## Closes vs Refs — Raw Data
{for each linked issue: ISSUE_N → unchecked acceptance-criteria count}
{or "No Closes/Fixes/Resolves keywords found"}
```

## Success criteria
- Dedup gate ran first; if `reviewed` already present, procedure stopped here
- PR metadata, body, conventions, existing comments, CI status all captured
- The FULL diff captured in the handoff (not truncated)
- Closes-vs-Refs raw data captured
- handoff.md written before the stage 01 Task is spawned

## Failure
