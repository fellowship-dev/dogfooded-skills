# Stage 04: Regenerate Lockfiles (subagent)

## Inputs
- `.procedure-output/release-train-runner/00-claim-compute/handoff.md` (REMOTE_EXEC, REPO_DIR)
- `.procedure-output/release-train-runner/03-validate-integrate/handoff.md`
  (`deps_touched`, dependency files changed)
- `shared/test-commands.md` (test command lookup)

## Task
If any included PR touched dependencies, regenerate the lockfiles on the release branch and
re-run the full test suite. This stage ALWAYS runs — if no deps changed, record "no lockfile
changes" and exit cleanly.

## Steps

1. Read `deps_touched` from the stage 03 handoff.

2. **If `deps_touched: false`** → no work; write handoff with "no lockfile changes" and stop.

3. **If `deps_touched: true`**, regenerate the appropriate lockfile:
```bash
# Rails
$REMOTE_EXEC "cd $REPO_DIR && bundle install"

# Node
$REMOTE_EXEC "cd $REPO_DIR && npm install"   # or yarn install
```

4. Commit the regenerated lockfile:
```bash
$REMOTE_EXEC "cd $REPO_DIR && git add -A && git commit -m 'chore: regenerate lockfile after release train merges'"
```
   Lockfile conflicts are mechanical — regenerate, never hand-resolve.

5. Run the test suite once more after lockfile regeneration (look up the command from the repo
   CLAUDE.md / `shared/test-commands.md`):
```bash
$REMOTE_EXEC "cd $REPO_DIR && <TEST_COMMAND>"
```

6. Write handoff.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/04-lockfiles/handoff.md`

```markdown
# Stage 04: Lockfiles

## Status
lockfiles_ok: {true|false}

## Action
{regenerated: bundle install / npm install / yarn install}  OR  {no lockfile changes}

## Commit
{lockfile commit sha or "none"}

## Post-Lockfile Tests
{PASS (N examples, M baseline failures) / FAIL: reason / not run — no deps changed}
```

## Success criteria
- If deps changed: lockfile regenerated, committed, and post-regeneration tests pass → `lockfiles_ok: true`
- If no deps changed: stage runs, records "no lockfile changes" → `lockfiles_ok: true`

## Failure
- Lockfile regenerated but tests then fail and cannot be made green → `lockfiles_ok: false`,
  document reason. Orchestrator emits `status=failed` at stage 04 and stops.
