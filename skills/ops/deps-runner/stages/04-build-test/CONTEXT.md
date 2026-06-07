# Stage 04: Build & Test (subagent)

## Inputs
- `.procedure-output/deps-runner/01-scan-context/handoff.md`
- `.procedure-output/deps-runner/02-preflight-baseline/handoff.md`
- `.procedure-output/deps-runner/03-risk-eval/handoff.md`

## Task
For each candidate PR, in the order from stage 03 (lowest-risk-first), verify it builds and
passes tests against the baseline. **One PR at a time. Reset to main between each.** This is the
first stage with branch-level side effects (checkout, merge main, install, build, test).

## Steps

Use `ENV_ID` from the preflight handoff. For each PR:

### 1. Decontaminate, checkout PR branch, merge main
Reset repo-level git identity first — previous runs may have set `orchestrator@fellowship.dev`,
overriding the global `~/.gitconfig` (populated from the `$GITCONFIG` personal secret):
```bash
BRANCH="<pr-branch-name>"
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && \
  git config --unset user.name 2>/dev/null; \
  git config --unset user.email 2>/dev/null; \
  git fetch origin $BRANCH && git checkout $BRANCH"

# CRITICAL: Merge main into the branch so it has latest changes
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git merge origin/main --no-edit"
```
If the merge has conflicts → record **flag for Max** (PR too stale, needs manual rebasing), set
this PR's result to `blocked`, skip to reset/next PR. Do NOT proceed for this PR.

### 2. Install & build with the new dependency
```bash
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm install && npm run build"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle install && bundle exec rails assets:precompile"
```
If build fails → record **flag for Max, do not merge**, set result `build:fail`, reset to main, next PR.

> First yarn/npm install is slow (~2min for Strapi, 860+ pkgs). Don't kill it prematurely.
> Don't pipe install through `tail` (buffered) — use no pipe or `head -50`.

### 3. Restart services if runtime dep
```bash
# Strapi / Node servers:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && pkill -f 'node.*strapi\|node.*server' 2>/dev/null; npm run develop &"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && pkill -f puma 2>/dev/null; bundle exec rails server -d"
```
Dev/build deps (linters, test tools, build plugins): no restart — just verify build passed.

### 4. Run tests
```bash
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm test"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle exec rspec"
```
Compare against the stage-02 baseline:
- Same pass count, no new failures → pass
- New failures → **flag for Max** (`tests:fail`)
- Fewer tests (tests removed?) → investigate, likely flag for Max

### 4-python) Docker build verification (Python repo, no test suite)
If `IS_PYTHON=yes` and `HAS_TESTS=0` and a `container/` dir exists, replace steps 3–4 with:
```bash
gitpod environment ssh $ENV_ID -- "cd /workspaces/$(ls /workspaces/) && docker build container/ -t dep-verify:test 2>&1"
```
- Build passes → treat as test pass.
- Build fails → flag for Max, do not merge.
- No `container/` dir → flag for Max (no verification path).

### 5. Reset for next PR
```bash
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && \
  git checkout main && git pull && \
  git config --unset user.name 2>/dev/null; \
  git config --unset user.email 2>/dev/null"
```

### 6. Write handoff (all PRs).

## Output: handoff.md

Path: `.procedure-output/deps-runner/04-build-test/handoff.md`

```markdown
# Stage 04: Build & Test

## Per-PR Results
| PR | Package | Risk | Merge-main | Build | Tests | Result |
|----|---------|------|-----------|-------|-------|--------|
| #N | name | low/med/high | clean/CONFLICT | pass/fail | pass (N/N)/fail/n-a | verified / build-fail / tests-fail / blocked(stale) |

## Notes
{build errors, test failures, conflicts, restart issues — per PR}
```

## Success criteria
- Every PR attempted in order; each has a recorded build + test result
- Reset to main performed between every PR

## Failure
- A PR's merge conflicts / build fails / tests fail → that PR is marked accordingly and
  flagged; the stage continues to the next PR. The stage only "fails" the run if the
  environment itself dies — in that case record env failure and let the orchestrator decide
  (resume_from=04-build-test after re-provisioning).
