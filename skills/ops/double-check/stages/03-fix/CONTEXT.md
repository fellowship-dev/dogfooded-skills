# Stage 03: Fix (subagent)

Run ONLY if stage 02 reported `fixes_needed: true`. If `fixes_needed: false`, the orchestrator
skips this stage entirely.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — REPO_DIR, PR/base branch names
- `.procedure-output/double-check/02-review/handoff.md` — the Fix List + Tests Posture

## Task
Apply the fixes the review stage identified, test the fix delta once, and push the fix commits to the
PR branch. Operate on the same working tree the setup stage prepared (`REPO_DIR`, already on the PR
branch with the base merged).

## Steps

```bash
REPO_DIR={REPO_DIR from setup handoff}
PR_BRANCH={PR_BRANCH from setup handoff}
cd "$REPO_DIR"
PRE_FIX_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid')
POST_FIX_HEAD_SHA=$PRE_FIX_HEAD_SHA
```

### Apply fixes

For each item in the stage-02 Fix List (MUST-FIX items, plus NICE-TO-HAVE items judged worth doing):
1. Plan the fix
2. Implement the fix
3. Commit: `git add ... && git commit -m "fix: [description] (review finding for #$PR)"`

### Run tests — once, scoped to your fix delta

Test what your fix commits changed, once. The PR's own changes were tested by its author's push,
and CI plus the release gate stay the full-suite authority, so never run the full suite here
(no `npm test` that maps to "all", no full corpus).

Pick the command in this order:

1. **The repo's scoped gate, based on `PRE_FIX_HEAD_SHA`.** Use the scoped/changed-only command
   the repo playbook names, pointed at your own commits. For `fellowship-dev/pylot`
   (install the three package roots first if `node_modules` is missing, per the playbook):

   ```bash
   cd "$REPO_DIR"
   [ -d node_modules ] || npm ci; [ -d gateway/node_modules ] || npm --prefix gateway ci
   [ -d infra/node_modules ] || npm --prefix infra ci
   PYLOT_GATE_BASE_SHA=$PRE_FIX_HEAD_SHA PYLOT_GATE_SKIP_BATS=1 ./scripts/test.sh corpus --changed-only
   ```

   `scripts/gate-scope.sh` diffs `PRE_FIX_HEAD_SHA..HEAD` and still fails closed to the full
   corpus for shared or unmapped paths. That is the gate deciding, not you.
2. **No scoped gate named:** the targeted tests for the files you touched, or else the stack
   default below.

```bash
# Stack defaults, only when the repo names no scoped command:
npm test 2>/dev/null || npx jest --passWithNoTests 2>/dev/null || echo "No test command found"
RAILS_ENV=test bundle exec rspec <touched spec files> --format progress 2>/dev/null || echo "Not a Rails project"
pytest 2>/dev/null || python -m pytest 2>/dev/null || echo "No pytest found"
go test ./... 2>/dev/null || echo "Not a Go project"
```

Record: the exact command, pass/fail, number of tests, any regressions introduced by your fixes,
and the commit SHA it ran on.

If tests fail after your fixes: debug and re-fix until green, or explicitly note the failure as
pre-existing. If the review's Tests Posture said "not applicable" (deps-only/lockfile-only, or a
docs-only fix), skip the suite and note why.

### Waiting on a long command

Run it in the foreground with the Bash tool's longest timeout (600000 ms) when it fits. When it
may run longer, start it in the background with its exit code captured, then block until it
exits. Each wait call returns the moment the command finishes (or after 9.5 minutes, when you run
the same wait again):

```bash
LOG=/tmp/double-check-gate.log; rm -f "$LOG" "$LOG.rc"
( <command>; echo $? > "$LOG.rc" ) > "$LOG" 2>&1 &   # or the Bash tool's run_in_background

# wait call (Bash timeout 600000), repeated until it prints exit=:
end=$((SECONDS+570)); until [ -f "$LOG.rc" ] || [ $SECONDS -ge $end ]; do sleep 5; done
if [ -f "$LOG.rc" ]; then echo "exit=$(cat "$LOG.rc")"; tail -60 "$LOG"; else echo "still running"; fi
```

Never poll with a fixed sleep of a minute or more followed by `tail` or `ps`: measured
runs slept up to ten minutes after the work had finished.

### Push fixes

If you made fix commits:

The test run above is this push's test run. Push with `--no-verify`, so the repo's pre-push hook
does not run a second, wider gate (the PR's whole scope) on the same code, only when either:

- the scoped run above was green on the exact commit you are pushing (`git rev-parse HEAD`
  equals the SHA you recorded), or
- the fix delta (`git diff --name-only $PRE_FIX_HEAD_SHA HEAD`) changes only documentation
  (Markdown or `docs/`), and the handoff says so.

Otherwise push without `--no-verify` and let the hook be the test run, waited on as above.

```bash
cd "$REPO_DIR"
git push --no-verify origin $PR_BRANCH   # only under the two conditions above
POST_FIX_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid')
if [ "$POST_FIX_HEAD_SHA" != "$PRE_FIX_HEAD_SHA" ]; then
  REVIEW_RECEIPT_INVALIDATED=true
else
  REVIEW_RECEIPT_INVALIDATED=false
fi
```

If you couldn't push (permission denied): note that fixes need to be applied by the repo owner —
this goes into the handoff and the review comment.

## Output: handoff.md

Path: `.procedure-output/double-check/03-fix/handoff.md`

```markdown
# Stage 03: Fix

pushed: {true | false | n/a}
pre_fix_head_sha: {40-character remote SHA}
post_fix_head_sha: {40-character remote SHA, or pre_fix_head_sha when no push}
review_receipt_invalidated: {true when a push changed head; otherwise false}

## Fixes Applied
| # | Finding | Commit | Notes |
|---|---------|--------|-------|
| 1 | {description} | {sha or "not committed"} | {detail} |
{or "none"}

## Tests After Fixes
- Command: {exact command, e.g. scoped gate based on PRE_FIX_HEAD_SHA}
- Ran on: {40-character commit SHA}
- Suite: {pass (N/N) | fail — details | not run — reason}
- Regressions: {none | list}

## Push
{pushed to PR_BRANCH | permission denied — repo owner must apply | n/a — no commits}
```

## Success criteria
- Each Fix-List item addressed (or documented why not)
- Fix delta tested once with the scoped command, result and exact SHA recorded (or explicitly
  skipped with reason); no full-suite run and no duplicate hook run
- Fix commits pushed (or push failure documented)
- A successful fix push invalidates the Stage 02 receipt; the orchestrator starts a fresh exact-head cycle

## Failure
- Build/test environment unusable → document it; still write handoff so stage 04 can report it
- Push permission denied → note in handoff for the review comment; not a hard failure
