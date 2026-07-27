# Stage 03: Fix (subagent)

Run ONLY if stage 02 reported `fixes_needed: true`. If `fixes_needed: false`, the orchestrator
skips this stage entirely.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — REPO_DIR, PR/base branch names
- `.procedure-output/double-check/02-review/handoff.md` — the Fix List + Tests Posture

## Task
Apply the fixes the review stage identified, re-run the test suite, and push the fix commits to the
PR branch. Operate on the same working tree the setup stage prepared (`REPO_DIR`, already on the PR
branch with the base merged).

## Steps

```bash
REPO_DIR={REPO_DIR from setup handoff}
PR_BRANCH={PR_BRANCH from setup handoff}
cd "$REPO_DIR"
```

### Apply fixes

For each item in the stage-02 Fix List (MUST-FIX items, plus NICE-TO-HAVE items judged worth doing):
1. Plan the fix
2. Implement the fix
3. Commit: `git add ... && git commit -m "fix: [description] (review finding for #$PR)"`

### Run tests

Run the project's test suite after fixes. The command depends on the stack:

```bash
# Node.js / Next.js
npm test 2>/dev/null || npx jest --passWithNoTests 2>/dev/null || echo "No test command found"

# Ruby on Rails
RAILS_ENV=test bundle exec rspec --format progress 2>/dev/null || echo "Not a Rails project"

# Python
pytest 2>/dev/null || python -m pytest 2>/dev/null || echo "No pytest found"

# Go
go test ./... 2>/dev/null || echo "Not a Go project"

# Detect from package.json
if [ -f package.json ]; then
  npm run test 2>/dev/null || npx vitest run 2>/dev/null || true
fi
```

Record: pass/fail, number of tests, any regressions introduced by your fixes.

If tests fail after your fixes: debug and re-fix until green, or explicitly note the failure as
pre-existing. If the review's Tests Posture said "not applicable" (deps-only/lockfile-only), skip
the suite and note why.

### Push fixes

If you made fix commits:

```bash
cd "$REPO_DIR"
git push origin $PR_BRANCH
```

If you couldn't push (permission denied): note that fixes need to be applied by the repo owner —
this goes into the handoff and the review comment.

## Output: handoff.md

Path: `.procedure-output/double-check/03-fix/handoff.md`

```markdown
# Stage 03: Fix

pushed: {true | false | n/a}

## Fixes Applied
| # | Finding | Commit | Notes |
|---|---------|--------|-------|
| 1 | {description} | {sha or "not committed"} | {detail} |
{or "none"}

## Tests After Fixes
- Suite: {pass (N/N) | fail — details | not run — reason}
- Regressions: {none | list}

## Push
{pushed to PR_BRANCH | permission denied — repo owner must apply | n/a — no commits}
```

## Success criteria
- Each Fix-List item addressed (or documented why not)
- Test suite run and result recorded (or explicitly skipped with reason)
- Fix commits pushed (or push failure documented)

## Failure
- Build/test environment unusable → document it; still write handoff so stage 04 can report it
- Push permission denied → note in handoff for the review comment; not a hard failure
