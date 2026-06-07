# Stage 03: Validate + Integrate (subagent) — THE SEQUENTIAL LOOP

## Inputs
- `.procedure-output/release-train-runner/00-claim-compute/handoff.md` (REMOTE_EXEC, REPO_DIR)
- `.procedure-output/release-train-runner/01-preflight/handoff.md` (valid merge list in order)
- `.procedure-output/release-train-runner/02-release-branch/handoff.md` (RELEASE_BRANCH)
- `shared/test-commands.md` (per-project test command lookup)

## Task
Integrate the valid PRs into the release branch **ONE AT A TIME, in the provided merge order**,
running the full test suite after each merge. This is the isolated critical-judgement stage:
PR validation, conflict resolution, and merge/skip verdicts all happen here in one clean context.

## CRITICAL — sequential, in-order, NO fan-out

Each merge changes the conflict surface for every later PR. A PR that is clean against the base
may conflict once an earlier PR lands. Therefore you MUST process PRs in a single sequential
loop, in the order from the valid merge list. **Do NOT spawn per-PR subagents. Do NOT parallelize.
Do NOT reorder.** Review each PR's diff in cohesion (whole diff, all dimensions together) — never
split a PR across files or dimensions.

## Steps — loop over the valid merge list, in order

For each PR (in order), do the following before moving to the next PR:

### 3.1 Merge (`--no-ff`)
```bash
$REMOTE_EXEC "cd $REPO_DIR && \
  git fetch origin $PR_BRANCH && \
  git merge origin/$PR_BRANCH --no-ff -m 'Merge PR #$PR_NUMBER: $PR_TITLE'"
```

### 3.2 Handle conflicts
If the merge conflicts:
1. List conflicting files: `git diff --name-only --diff-filter=U`
2. Read each conflicting file to understand both sides.
3. Resolve:
   - **Lockfiles** (Gemfile.lock, yarn.lock, package-lock.json) → leave for stage 04; re-run the
     package manager after all merges rather than hand-resolving.
   - **Adjacent line changes** → keep both.
   - **Same function modified differently** → attempt an intelligent merge, log the decision.
   - **Truly irreconcilable** → skip this PR: `git merge --abort`, log the reason, continue with
     the NEXT PR (do not abort the train).
4. After resolution: `git add . && git commit --no-edit`
5. Record every conflict and its resolution for the release PR description.

### 3.3 Run the test suite
Look up the test command from the repo CLAUDE.md (see `shared/test-commands.md`):
```bash
$REMOTE_EXEC "cd $REPO_DIR && <TEST_COMMAND>"
```

If tests fail after merging PR #N:
1. Determine whether the failure is from this PR or a conflict with a previously merged PR.
2. If it is a pre-existing (baseline) failure, note it and continue.
3. If this merge introduced the failure:
   - Attempt a simple fix (missing import, type error, obvious conflict residue).
   - If fixable: commit as `fix: resolve merge conflict in [file] between PR #X and #Y`.
   - If not fixable: **revert this PR's merge** (`git revert HEAD --no-edit`), log it as skipped,
     continue with the next PR.
4. Re-run tests to confirm green before proceeding to the next PR.

### 3.4 Log result for this PR
Record: merge status (clean / conflicts resolved / skipped / reverted), conflicts (files +
resolution strategy), test result (pass / fail with details). Then move to the next PR.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/03-validate-integrate/handoff.md`

```markdown
# Stage 03: Validate + Integrate

## Status
integrate_ok: {true|false}   # true if ≥1 PR landed and the train tip is green

## Per-PR Log (in merge order)
| # | PR | Branch | Merge | Conflicts | Tests | Outcome |
|---|-----|--------|-------|-----------|-------|---------|
| 1 | #N | ref | Clean | none | Pass | Included |
| 2 | #M | ref | Conflicts resolved | file:strategy | Pass | Included |
| 3 | #K | ref | Irreconcilable | aborted | — | Skipped |

## Conflict Log
### PR #X + PR #Y — `path/to/file`
- Type: {adjacent / same function / lockfile}
- Resolution: {what was kept/changed}

## Test Results (after each merge)
- After #N: PASS
- After #M: PASS (2 conflicts resolved)
- After #K: reverted/aborted — skipped

## Dependencies Touched
deps_touched: {true|false}   # true if any included PR modified Gemfile/package.json/etc.
{list the dependency manifest files changed}

## Included PRs
{space-separated, in order}

## Skipped PRs
- PR #K — {reason} (or "none")
```

## Success criteria
- Every valid PR processed exactly once, strictly in order
- Tests run after each merge (not batched)
- At least one PR included and the train tip is green → `integrate_ok: true`
- `deps_touched` flag set for stage 04
- All conflicts and skip/revert decisions logged

## Failure
- Every PR skipped/reverted (nothing landed) → `integrate_ok: false`. Orchestrator emits
  `status=failed` at stage 03 and stops (no release worth pushing).
