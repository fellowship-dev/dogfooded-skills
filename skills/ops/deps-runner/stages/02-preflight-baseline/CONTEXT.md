# Stage 02: Preflight Baseline (subagent)

## Inputs
- `.procedure-output/deps-runner/01-scan-context/handoff.md`

## Task
Verify the environment is healthy on `main` BEFORE touching any PR branch, record the baseline,
and sync the booster remote if this is a downstream booster-pack site. If preflight fails,
the environment is broken — record the blocker; downstream stages must not merge anything.

## Steps

Use `ENV_ID` from the input handoff. If it was "none", spin up an Ona environment first
(via the `ona-gitpod` skill) and record the new ID.

### 1. Verify main compiles
```bash
ENV_ID="<ona-environment-id>"

gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git stash; git checkout main && git pull"
```
(`git stash` first — devcontainer lifecycle may leave modified files, e.g. devcontainer.json.)

### 2. Install deps & build (baseline)
```bash
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm install && npm run build"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle install && bundle exec rails assets:precompile"
```

### 3. Run test suite (baseline)
```bash
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm test"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle exec rspec"
```
Record the baseline: number of passing tests, build time, any existing warnings. This is the
reference point for stage 04.

> Python repo with NO test suite but a `container/Dockerfile`: skip the test-suite baseline.
> Stage 04 verifies via `docker build container/` instead.

### 4. Booster remote sync (downstream sites only)
```bash
# Check for booster remote
HAS_BOOSTER=$(gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git remote | grep -c '^booster$'" || echo "0")

if [ "$HAS_BOOSTER" = "1" ]; then
  echo "==> booster remote detected — syncing booster/main before deps run"
  MERGE_RESULT=$(gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git fetch booster && git merge booster/main --no-edit 2>&1"; echo "EXIT:$?")

  if echo "$MERGE_RESULT" | grep -q "EXIT:0"; then
    echo "==> booster/main merged successfully"
    BOOSTER_SYNC_STATUS="synced"
  else
    echo "==> booster/main merge CONFLICT — aborting"
    gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git merge --abort 2>/dev/null || true"
    gh issue create --repo $ORG_REPO \
      --title "deps-runner: booster/main merge conflict on $(date +%Y-%m-%d)" \
      --body "The deps-runner detected a merge conflict when syncing \`booster/main\` into \`main\` on \`$ORG_REPO\`.

**Action required**: Resolve the conflict manually, then re-run deps.

\`\`\`
$MERGE_RESULT
\`\`\`

Deps run aborted." \
      --label "conflict,deps"
    echo "==> Issue filed. Skipping deps run for this repo."
    BOOSTER_SYNC_STATUS="conflict-aborted — issue filed"
    # STOP — do not process any PRs (record this in handoff; orchestrator routes to report)
  fi
else
  echo "==> No booster remote — skipping sync"
  BOOSTER_SYNC_STATUS="skipped (no booster remote)"
fi
```

### 5. Write handoff.

## Output: handoff.md

Path: `.procedure-output/deps-runner/02-preflight-baseline/handoff.md`

```markdown
# Stage 02: Preflight Baseline

## Status
preflight_ok: {true|false}
env_id: {ENV_ID}

## Baseline
- Build: {pass / FAILED: reason}
- Tests: {N passing / N failing  |  "n/a — docker-build repo"}
- Build time: {duration}
- Warnings: {existing warnings, or none}

## Booster Sync
{synced | skipped (no booster remote) | conflict-aborted — issue filed}

## Blockers
{list, or "none"}

## Proceed
{true — continue to risk-eval | false — preflight broken, route to report}
```

## Success criteria
- `preflight_ok: true` only if main compiles AND (tests pass OR docker-build repo)
- env_id recorded
- Booster sync status recorded

## Failure
- Main does not compile / baseline tests fail → `preflight_ok: false`, `proceed: false`. STOP
  fixing nothing — the orchestrator routes straight to 06-report (blocked).
- Booster conflict → issue filed, `proceed: false`, route to report.
