---
name: release-train-runner
description: Merge a sequence of PRs into a single release branch on remote compute. Resolves conflicts, runs full test suite, creates one release PR with a unified test plan.
user-invocable: true
argument-hint: "[org/repo] [pr1] [pr2] [pr3] ... (complementary instructions)"
---

Merge PRs into a release train for repo `$0`. PR numbers follow as `$1`, `$2`, `$3`, etc.

Complementary instructions (if any) appear in parentheses at the end of the arguments — treat them as extra context that narrows scope or provides guidance.

Write the report to `reports/YYYY-MM-DD-release-train-$0.md` (replace `/` with `-` in the repo name).

---

# Release Train Runner

Merge N reviewed PRs into a single release branch on remote compute (Ona or Codespaces). Run the full test suite after each merge. Produce one release PR with conflicts documented and a unified manual test plan.

## When to Use

- 2+ PRs ready to merge on a repo (typically `double-checked` or `ready-to-merge`)
- Max asks to package PRs for release
- Moonlighter detects PR backlog and dispatches automatically

## Inputs

- **REPO**: `org/repo` (e.g., `Lexgo-cl/rails-backend`)
- **PR_NUMBERS**: Space-separated PR numbers in merge order (e.g., `1372 1375 1430`)
- Merge order = the order provided. Caller decides sequencing (typically oldest first, low-risk before high-risk).

## Phase 0: Claim Compute Environment

**All work happens on remote compute. NEVER merge locally.**

### Option A: Ona (if project has Ona setup)

Look up the repo Ona project ID and env name pattern from the team CLAUDE.md.

```bash
gitpod environment list 2>&1 | grep -i "<repo-name>"
```

- Stopped env → `gitpod environment start <ENV_ID>`
- No env but project exists → `gitpod environment create --project <PROJECT_ID>`
- No project → try Codespaces (Option B)

### Option B: Codespaces

```bash
export GH_TOKEN=$(grep '^CODESPACE_TOKEN=' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)

CS_NAME=$(gh cs create \
  --repo $REPO \
  --branch $DEFAULT_BRANCH \
  --machine basicLinux32gb \
  --idle-timeout 120m \
  --retention-period 1h \
  --display-name "release-train-$(date +%m%d)")
```

**Preference:** Use Ona if the project has it set up (environment is warm, deps installed). Fall back to Codespaces otherwise.

### Environment abstraction

Throughout this document:
- `REMOTE_EXEC` = `gitpod environment ssh $ENV_ID --` OR `gh cs ssh -c $CS_NAME --`
- `REPO_DIR` = workspace directory on remote (e.g., `/workspaces/rails-backend`)

Substitute the correct command based on which compute you claimed.

## Phase 1: Pre-Flight

### 1.1 Determine default branch

```bash
DEFAULT_BRANCH=$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name)
```

Lexgo uses `master`, most others use `main`. Never assume.

### 1.2 Fetch PR metadata for all PRs

```bash
for PR in $PR_NUMBERS; do
  gh pr view $PR --repo $REPO --json number,title,headRefName,author,labels,additions,deletions,changedFiles,url,body
done
```

Collect into a manifest:

| PR | Title | Author | Branch | LOC | Files | Labels |
|----|-------|--------|--------|-----|-------|--------|

### 1.3 Validate PRs

For each PR, verify:
- State is `open` (not already merged or closed)
- Base branch matches `$DEFAULT_BRANCH`
- Not a draft

If any PR fails validation, **report and skip it** — don't abort the whole train.

### 1.4 Ensure environment is clean

```bash
$REMOTE_EXEC "cd $REPO_DIR && git fetch origin && git checkout $DEFAULT_BRANCH && git reset --hard origin/$DEFAULT_BRANCH && git clean -fd"
```

## Phase 2: Create Release Branch

```bash
RELEASE_DATE=$(date +%Y-%m-%d)
RELEASE_BRANCH="release/$RELEASE_DATE"

# If branch exists, append counter
$REMOTE_EXEC "cd $REPO_DIR && git checkout -b $RELEASE_BRANCH origin/$DEFAULT_BRANCH"
```

If the branch name is taken, try `release/$RELEASE_DATE-2`, `-3`, etc.

## Phase 3: Sequential Merge + Test

For each PR in the provided order:

### 3.1 Merge

```bash
$REMOTE_EXEC "cd $REPO_DIR && \
  git fetch origin $PR_BRANCH && \
  git merge origin/$PR_BRANCH --no-ff -m 'Merge PR #$PR_NUMBER: $PR_TITLE'"
```

### 3.2 Handle conflicts

If merge conflicts:

1. List conflicting files: `git diff --name-only --diff-filter=U`
2. Read each conflicting file to understand both sides
3. Resolve:
   - **Lockfiles** (Gemfile.lock, yarn.lock, package-lock.json) → re-run the package manager after all merges
   - **Adjacent line changes** → keep both
   - **Same function modified differently** → attempt intelligent merge, log decision
   - **Truly irreconcilable** → skip this PR, log reason, `git merge --abort`, continue with next PR
4. After resolution: `git add . && git commit --no-edit`
5. Record every conflict and resolution for the release PR description

### 3.3 Run test suite

Look up the test command from the repo CLAUDE.md:

| Project | Test Command |
|---------|-------------|
| Lexgo (Rails) | `RAILS_ENV=test bundle exec rspec --format progress` |
| Booster Pack / Farmesa / Inbox Angel (Strapi+Next) | `cd backend && npm run build && cd ../frontend && npm run build` |
| MTG LOTR (Next.js) | `npm run build` |

```bash
$REMOTE_EXEC "cd $REPO_DIR && <TEST_COMMAND>"
```

**If tests fail after merging PR #N:**

1. Check if the failure is from the current PR or a conflict with a previously merged PR
2. If it's a pre-existing test failure (baseline), note it and continue
3. If the merge introduced the failure:
   - Attempt a simple fix (missing import, type error, obvious conflict residue)
   - If fixable: commit as `fix: resolve merge conflict in [file] between PR #X and #Y`
   - If not fixable: **revert this PR's merge** (`git revert HEAD --no-edit`), log it as skipped, continue with next PR
4. Re-run tests to confirm green before proceeding

### 3.4 Log result

After each PR, record:
- Merge status: clean / conflicts resolved / skipped
- Conflicts: files + resolution strategy
- Test result: pass / fail (with details)

## Phase 4: Regenerate Lockfiles (if needed)

If any merged PR touched dependencies:

```bash
# Rails
$REMOTE_EXEC "cd $REPO_DIR && bundle install"

# Node
$REMOTE_EXEC "cd $REPO_DIR && npm install"  # or yarn install
```

Commit: `chore: regenerate lockfile after release train merges`

Run tests once more after lockfile regeneration.

## Phase 5: Push Release Branch

```bash
$REMOTE_EXEC "cd $REPO_DIR && git push origin $RELEASE_BRANCH"
```

## Phase 6: Create Release PR

```bash
gh pr create --repo $REPO \
  --base $DEFAULT_BRANCH \
  --head $RELEASE_BRANCH \
  --title "🚂 Release train — $RELEASE_DATE (N PRs)" \
  --body "$(cat <<'BODY'
## Release Train — RELEASE_DATE

N PRs merged sequentially, tests verified after each merge.

### Included PRs (merge order)

| # | PR | Title | Author | LOC | Merge | Tests |
|---|-----|-------|--------|-----|-------|-------|
| 1 | [#NNN](url) | Title | @author | +X/-Y | Clean | Pass |
| 2 | [#NNN](url) | Title | @author | +X/-Y | Conflicts resolved | Pass |

### Conflicts Resolved

- `path/to/file` — PR #X and #Y both modified; resolution: [description]
(or "No conflicts — clean merges across all PRs")

### Skipped PRs

- PR #Z — [reason: irreconcilable conflict / test failure after merge]
(or "None — all PRs included")

### Test Results

- Full suite after final merge: **PASS** (N examples, 0 failures)
- Baseline failures (pre-existing): [list if any]

### Manual Test Plan

Combined test plan covering all included PRs:
- [ ] [Specific user action from PR #A] — expected: [outcome]
- [ ] [Specific user action from PR #B] — expected: [outcome]
- [ ] [Cross-PR interaction check] — expected: [outcome]
- [ ] [Regression check on adjacent workflows]

### How to Review

```bash
git fetch origin release/YYYY-MM-DD
git diff master...release/YYYY-MM-DD --stat
```

Review the combined diff. Individual PR descriptions are linked above for context.

### On merge

GitHub will auto-close the included PRs (their commits are contained in this branch).

---
🚂 Generated by `/release-train-runner`
BODY
)"
```

## Phase 7: Notify

If running async (moonlighter, Telegram dispatch):

```bash
QUEUE_DIR="$HOME/.local/share/pylot/queue"
TRIGGER_FILE="$QUEUE_DIR/release-train_$(date +%s)_$RANDOM.trigger"
cat > "$TRIGGER_FILE" <<TRIGGER
header: 🚂 /release-train-runner
report: inline
---
🚂 Release train ready for $REPO
$N PRs merged into $RELEASE_BRANCH. $M conflicts resolved, tests green.
Review: $PR_URL
TRIGGER
```

## Phase 8: Release Environment

```bash
# Ona
$REMOTE_EXEC "cd $REPO_DIR && git checkout $DEFAULT_BRANCH"
gitpod environment stop $ENV_ID

# Codespaces (retention-period handles auto-delete)
gh cs stop -c "$CS_NAME"
```

## Report (REQUIRED)

Every release train produces a report at `reports/YYYY-MM-DD-release-train-ORG-REPO.md`.

```markdown
# Release Train: [org/repo] — YYYY-MM-DD

**Date:** YYYY-MM-DD
**Repo:** [org/repo]
**Release PR:** #N — [url]
**Release Branch:** release/YYYY-MM-DD
**Compute:** [Ona env ID / Codespace name]
**Duration:** [X minutes]

## Source PRs

| # | PR | Title | Author | LOC | Merge | Tests | Status |
|---|-----|-------|--------|-----|-------|-------|--------|
| 1 | [#N](url) | Title | @author | +X/-Y | Clean | Pass | Included |
| 2 | [#N](url) | Title | @author | +X/-Y | 2 conflicts | Pass | Included |
| 3 | [#N](url) | Title | @author | +X/-Y | — | Fail | Skipped |

## Conflict Log

### PR #X + PR #Y — `path/to/file`
- Conflict type: [adjacent lines / same function / lockfile]
- Resolution: [description of what was kept/changed]

## Test Results

- After PR #1: PASS
- After PR #2: PASS (2 conflicts resolved)
- After PR #3: FAIL — reverted, skipped
- Final suite: PASS (N examples, M baseline failures)

## Manual Test Plan

[Combined from all included PRs — deduplicated, ordered by workflow area]

## Verdict

Release branch is ready for Max to review and merge.
```

## Key Rules

- **Never force push** the release branch
- **Never delete** source PR branches — GitHub auto-deletes on merge
- **Always --no-ff** merge to preserve PR commit boundaries
- **Always run tests** after each merge — don't batch merges then test
- **Never merge the release PR** — Max reviews and merges manually
- **Log every conflict** resolution for transparency
- **Skip rather than break** — if a PR causes test failures, skip it rather than shipping broken code
- **Merge order matters** — follow the order provided by the caller
- **Lockfile conflicts are mechanical** — regenerate, don't manually resolve
