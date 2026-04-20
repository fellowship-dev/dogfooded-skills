---
name: build-train
description: Batch multiple GitHub issues into a single build branch. Dispatches workers per issue, collects PRs, merges into build branch, creates one final PR to main. Saves 4N review missions by running the review pipeline once.
argument-hint: "org/repo --issues 10,14,15,16 [--branch build/name]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# build-train

Batch-execute multiple issues into a single build branch. Each issue gets a worker; each worker creates a PR targeting the build branch. The final PR to main goes through the full review pipeline once.

## When to Use

- 3+ open issues on the same repo that can be worked in parallel (or sequentially)
- CTO heartbeat detects a batch of related work
- Manual dispatch: `/build-train Lexgo-cl/lexgo-website --issues 10,14,15,16`

## Arguments

Parse `$ARGUMENTS` for:

- **repo**: `org/repo` (required, first positional arg)
- **--issues**: comma-separated issue numbers (required)
- **--branch**: build branch name (optional, default: `build/YYYY-MM-DD`)

## Phase 0: Setup

### 0.1 Determine default branch

```bash
DEFAULT_BRANCH=$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name)
```

### 0.2 Create build branch

```bash
BUILD_BRANCH="${BRANCH_ARG:-build/$(date +%Y-%m-%d)}"
# Append counter if exists
git ls-remote --heads origin "$BUILD_BRANCH" | grep -q . && BUILD_BRANCH="${BUILD_BRANCH}-2"
gh api repos/$REPO/git/refs -X POST \
  -f ref="refs/heads/$BUILD_BRANCH" \
  -f sha="$(gh api repos/$REPO/git/ref/heads/$DEFAULT_BRANCH -q .object.sha)"
```

### 0.3 Create `build-train` label if missing

```bash
gh label create build-train --repo $REPO --color 1D76DB --description "Part of a build-train batch" 2>/dev/null || true
```

### 0.4 Read all issues

```bash
for ISSUE in $ISSUE_NUMBERS; do
  gh issue view $ISSUE --repo $REPO --json number,title,body,labels,assignees
done
```

Build a manifest of issues with titles and key context for worker prompts.

## Phase 1: Dispatch Workers

For each issue, spawn a worker via `claude -p`. The worker boot prompt MUST include:

```
You are headless. Never ask clarifying questions. Make assumptions and proceed.

CRITICAL INSTRUCTIONS — READ CAREFULLY:
1. Create your PR targeting branch "$BUILD_BRANCH" (NOT $DEFAULT_BRANCH, NOT main, NOT master)
2. Add the label "build-train" to your PR
3. Work ONLY on issue #$ISSUE_NUMBER — do not fix other issues or expand scope

To create the PR targeting the correct branch:
  gh pr create --repo $REPO --base $BUILD_BRANCH --head your-feature-branch --title "..." --body "..." --label build-train

TASK:
Fix/implement issue #$ISSUE_NUMBER on $REPO: $ISSUE_TITLE
$ISSUE_BODY_SUMMARY

EXPECTED OUTPUT:
A PR targeting $BUILD_BRANCH with the build-train label.
```

### Worker spawn

Use the same `claude -p` pattern as crew-runner:

```bash
WORKER_SESSION=$(uuidgen)
WORKER_LOG="$WORKER_LOG_DIR/${WORKER_SESSION}.log"

(
  unset CLAUDECODE CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT
  cd $WORKER_DIR
  claude -p --verbose --session-id "$WORKER_SESSION" --dangerously-skip-permissions -- "$WORKER_PROMPT" </dev/null >> "$WORKER_LOG" 2>&1
) &
WORKER_PID=$!
```

### Sequential vs parallel

- At `team_max_concurrent=1`: spawn one worker, wait, spawn next
- At higher concurrency: spawn multiple, wait for all

Use `scripts/wait-for-job.sh` to block until each worker exits.

## Phase 2: Verify + Fix

After each worker finishes, verify the PR:

```bash
# Find the PR the worker created (search by head branch or recent PRs)
PR_NUMBER=$(gh pr list --repo $REPO --state open --label build-train --json number,headRefName \
  --jq ".[] | select(.number > $LAST_KNOWN_PR) | .number" | head -1)
```

### Verify checklist

1. **PR exists** — if not, log failure, continue to next issue
2. **PR targets build branch** — check base ref:

   ```bash
   BASE=$(gh pr view $PR_NUMBER --repo $REPO --json baseRefName -q .baseRefName)
   if [ "$BASE" != "$BUILD_BRANCH" ]; then
     gh pr edit $PR_NUMBER --repo $REPO --base "$BUILD_BRANCH"
   fi
   ```

3. **Has `build-train` label** — add if missing:

   ```bash
   gh pr edit $PR_NUMBER --repo $REPO --add-label build-train
   ```

### On worker failure

1. Check last 30 lines of worker log
2. If retries remain (max 2 per issue): adjust prompt, re-dispatch
3. If exhausted: log as skipped, continue to next issue

## Phase 3: Merge PRs into Build Branch

After all workers complete, merge each PR into the build branch:

```bash
for PR in $BUILD_TRAIN_PRS; do
  gh pr merge $PR --repo $REPO --merge --admin
done
```

Handle conflicts same as release-train-runner:

- Lockfiles: regenerate
- Adjacent lines: keep both
- Irreconcilable: skip that PR, log reason

## Phase 4: Create Final PR

```bash
gh pr create --repo $REPO \
  --base $DEFAULT_BRANCH \
  --head $BUILD_BRANCH \
  --title "build-train: $BUILD_BRANCH (N issues)" \
  --body "## Build Train

N issues implemented and merged into this branch:

| Issue | Title | PR | Status |
|-------|-------|----|--------|
| #10 | Brand assets | #N | Merged |
| #14 | Blog pages | #N | Merged |

Individual PRs linked above for per-issue review.

---
Generated by /build-train"
```

The final PR has NO `build-train` label. It triggers the normal review pipeline.

## Phase 5: Report

Write to `reports/YYYY-MM-DD-build-train-REPO.md`:

```markdown
# Build Train: $REPO
**Branch:** $BUILD_BRANCH
**Final PR:** #N
**Issues:** N attempted, M completed, K skipped

## Issues

| # | Issue | Worker | PR | Status |
|---|-------|--------|----|--------|
| 1 | #10 Brand assets | session-abc | #50 | Merged |
| 2 | #14 Blog | session-def | #51 | Merged |

## What's left
- Issue #15: worker failed, needs manual dispatch
```

Commit and push the report.

## Hard Rules

1. **Worker prompts MUST specify `--base $BUILD_BRANCH`** — primary instruction, repeated twice in prompt
2. **Verify and fix** every PR after worker completes — change base branch and add label if worker got it wrong
3. **Final PR has NO `build-train` label** — enters normal review pipeline
4. **Never force push** the build branch
5. **Skip rather than break** — if a worker or merge fails, skip and continue
6. **One build-train per repo at a time** — check for existing `build/*` branches before starting
7. **SCOPE LOCK applies** — work only the listed issues, nothing else
