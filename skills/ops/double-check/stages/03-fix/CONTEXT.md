# Stage 03: Fix (subagent)

Run ONLY if stage 02 reported `fixes_needed: true`. If `fixes_needed: false`, the orchestrator
skips this stage entirely.

## Inputs
- `.procedure-output/double-check/01-setup/handoff.md` — REPO_DIR, PR/base branch names
- `.procedure-output/double-check/02-review/handoff.md` — the Fix List + Tests Posture

## Task
Apply the fixes the review stage identified, verify the fix delta under the owning contract, and push the fix commits to the
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

### Select and run verification for your fix delta

Read the owning repository's active instructions and verification contract before running
commands. Select meaningful checks for `PRE_FIX_HEAD_SHA..HEAD` and affected behavior/direct
consumers, not just filenames. The author's previous run does not prove your fixes or changed
integration behavior. Preserve required broad/full-suite, dependency/lockfile, migration,
transformation, build, integration and release gates. Verify actual CI configuration and policy
before assigning a gate to CI; never assume a full gate exists elsewhere.

Pick commands in this order:

1. **The repo's impact/scoped gate, based on `PRE_FIX_HEAD_SHA`.** Use the command the
   repo playbook names, pointed at your own commits. For `fellowship-dev/pylot`
   (install the three package roots first if `node_modules` is missing, per the playbook):

   ```bash
   set -e
   cd "$REPO_DIR"
   [ -d node_modules ] || npm ci
   [ -d gateway/node_modules ] || npm --prefix gateway ci
   [ -d infra/node_modules ] || npm --prefix infra ci
   PYLOT_GATE_BASE_SHA=$PRE_FIX_HEAD_SHA PYLOT_GATE_SKIP_BATS=1 ./scripts/test.sh corpus --changed-only
   ```

   Stop on an installation failure. `scripts/gate-scope.sh` diffs
   `PRE_FIX_HEAD_SHA..HEAD` and still fails closed to the full corpus for shared or unmapped
   paths. That expansion remains mandatory; do not override it to save time.
2. **No impact command named:** inspect the repo's test scripts and runner configuration,
   select explicit affected tests plus direct-consumer/integration checks, and explain the
   mapping. For shared, dependency, transformational or unmapped impact, broaden the scope
   conservatively. Run a full suite when the owning contract requires it or meaningful coverage
   cannot be selected more narrowly. Do not invent stack defaults or try unrelated runners
   until one appears green.

Keep stdout, stderr and exit status. Do not hide errors, chain a failure into a success echo,
or permit zero tests as a successful test result. An empty impact selection is acceptable only
when the repo contract explicitly classifies it as non-runtime and its required documentation,
policy or static checks pass; report it as non-runtime verification, not tests passed.

Record the exact command, scope and rationale, result, test count, environment, commit SHA,
remaining required gates and any regressions. Missing tooling or coverage is an explicit gap.
If tests fail, debug and re-fix, then rerun the affected checks on the final revision. A
pre-existing failure needs independent evidence and disclosure; it cannot satisfy a required
green gate. Dependencies/lockfiles are not automatically exempt. Markdown may be executable
policy: use the repo's classification rather than declaring it test-free yourself.

Run each selected check once on unchanged code where the contract permits receipt reuse.
Repeat only for new changes, failures or unresolved concerns; retain independent review and
exact-head acceptance. Before choosing a hook as the verification run, inspect what it runs
and ensure it covers the required scope. Avoid an identical explicit-plus-hook run only when
repo policy allows deduplication; hook bypass never waives other hook checks.

### Waiting on a long command

Run it in the foreground with the Bash tool's longest timeout (600000 ms) when it fits. When it
may run longer, start it in the background with its exit code captured, then block until it
exits. Each wait call returns the moment the command finishes (or after 9.5 minutes, when you run
the same wait again):

```bash
LOG=$(mktemp /tmp/double-check-gate.XXXXXX); rm -f "$LOG" "$LOG.rc"
( <command>; echo $? > "$LOG.rc" ) > "$LOG" 2>&1 &   # or the Bash tool's run_in_background

# wait call (Bash timeout 600000), repeated until it prints exit=:
end=$((SECONDS+570)); until [ -f "$LOG.rc" ] || [ $SECONDS -ge $end ]; do sleep 5; done
if [ -f "$LOG.rc" ]; then echo "exit=$(cat "$LOG.rc")"; tail -60 "$LOG"; else echo "still running"; fi
```

Never poll with a fixed sleep of 30 seconds or more followed by `tail` or `ps`: measured
runs slept up to ten minutes after the work had finished.

### Push fixes

If you made fix commits:

A green scoped receipt alone does not authorize `--no-verify`. Push normally unless the
owning repo explicitly permits bypass and every check the hook would omit has passed on the
exact pushed revision with the required scope/environment. Record that authority and evidence.
If the hook supplies the verification run, wait for its result and record the exact revision;
missing or failing evidence cannot be converted into a pass by bypassing the hook.

```bash
cd "$REPO_DIR"
git push origin $PR_BRANCH
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
- Contract and scope: {owner policy, affected behavior/consumers, selection rationale}
- Command: {exact command, e.g. impact gate based on PRE_FIX_HEAD_SHA}
- Ran on: {40-character commit SHA}
- Suite: {pass (N/N) | fail — details | not run — reason}
- Environment and remaining gates: {details}
- Regressions: {none | list}

## Push
{pushed to PR_BRANCH | permission denied — repo owner must apply | n/a — no commits}
```

## Success criteria
- Each Fix-List item addressed (or documented why not)
- Meaningful fix-delta/consumer verification follows the owning contract; required broader
  gates preserved, commands/results/counts/environment/exact SHA recorded, gaps disclosed
- Repeated runs justified by changes, failures, concerns or required policy; hook checks not waived
- Fix commits pushed (or push failure documented)
- A successful fix push invalidates the Stage 02 receipt; the orchestrator starts a fresh exact-head cycle

## Failure
- Build/test environment unusable → document it; still write handoff so stage 04 can report it
- Push permission denied → note in handoff for the review comment; not a hard failure
