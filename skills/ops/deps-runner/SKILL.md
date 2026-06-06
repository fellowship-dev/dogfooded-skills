---
name: deps-runner
description: Run dependency update PRs through an Ona-based verification pipeline. Checkout branch, verify build, run tests, classify risk, auto-merge safe ones with [skip ci], flag complex ones for manual review.
user-invocable: true
argument-hint: "[org/repo] [container-name]"
---

Run the deps-runner pipeline for repo `$0` using container `$1`.

Read the repo CLAUDE.md and team CLAUDE.md for container setup, deps-runner compatibility, and project caveats.

Start by fetching all candidate dependency PRs with `gh pr list`. Process them one at a time following the pipeline phases.

Write the report to `reports/YYYY-MM-DD-deps-$0.md` (replace `/` with `-` in the repo name). The report MUST start with the source PRs that were picked up.

---

# Deps Runner

End-to-end dependency PR verification and merge pipeline. Runs inside an Ona (Gitpod) environment.

## Prerequisites

- Ona environment running for the target project (use `ona-gitpod` skill to spin up)
- Environment must compile and pass tests on `main` BEFORE starting (pre-flight)
- GitHub tokens configured as Ona project secrets (no local tokens needed)
- Claude Code token for writing targeted tests if needed

## Pipeline

### Phase 1: Pre-flight (on main branch)

Verify the environment is healthy before touching any PR branch. If pre-flight fails, STOP -- fix the environment first.

```bash
ENV_ID="<ona-environment-id>"

# Verify main branch compiles
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git checkout main && git pull"

# Install deps & build
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm install && npm run build"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle install && bundle exec rails assets:precompile"

# Run test suite (baseline)
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm test"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle exec rspec"
```

Record baseline: number of passing tests, build time, any existing warnings. This is your reference point.

### Phase 1b: Booster remote sync (downstream sites only)

After pre-flight baseline, check if the repo is a downstream booster-pack site. If it has a `booster` remote, pull the latest template changes before running deps — this makes the "booster-pack first" guarantee mechanical rather than discipline-based.

```bash
# Check for booster remote
HAS_BOOSTER=$(gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git remote | grep -c '^booster$'" || echo "0")

if [ "$HAS_BOOSTER" = "1" ]; then
  echo "==> booster remote detected — syncing booster/main before deps run"

  # Fetch and merge on main
  MERGE_RESULT=$(gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git fetch booster && git merge booster/main --no-edit 2>&1"; echo "EXIT:$?")

  if echo "$MERGE_RESULT" | grep -q "EXIT:0"; then
    echo "==> booster/main merged successfully"
    BOOSTER_SYNC_STATUS="synced"
  else
    echo "==> booster/main merge CONFLICT — aborting"
    gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git merge --abort 2>/dev/null || true"

    # File a GitHub issue flagging the conflict
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
    # STOP — do not process any PRs
    exit 0
  fi
else
  echo "==> No booster remote — skipping sync"
  BOOSTER_SYNC_STATUS="skipped (no booster remote)"
fi
```

### Phase 2: Decontaminate, checkout PR branch, and merge main

Dependency PRs are often stale (created weeks/months ago). They need to incorporate any changes pushed to main since they were created -- especially new dependencies or build fixes.

First, reset repo-level git identity — previous runs may have set `orchestrator@fellowship.dev` which overrides the global `~/.gitconfig` (populated from the `$GITCONFIG` personal secret):

```bash
BRANCH="<pr-branch-name>"
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && \
  git config --unset user.name 2>/dev/null; \
  git config --unset user.email 2>/dev/null; \
  git fetch origin $BRANCH && git checkout $BRANCH"

# CRITICAL: Merge main into the branch so it has latest changes
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git merge origin/main --no-edit"
```

If the merge has conflicts -> **flag for Max**, do not proceed. The dep PR is too stale and needs manual rebasing.

### Phase 3: Classify the dependency

Determine what kind of update this is:

**a) Check the diff -- what changed?**
```bash
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && git diff main..HEAD --name-only"
```
Look at: package.json, Gemfile, requirements.txt -- what package, what version bump?

**b) Is it a compile-time or runtime dependency?**
```bash
# Node: check if it's in dependencies vs devDependencies
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && cat package.json | python3 -c \"
import sys,json; p=json.load(sys.stdin)
pkg='<PACKAGE_NAME>'
if pkg in p.get('dependencies',{}): print('RUNTIME')
elif pkg in p.get('devDependencies',{}): print('DEV/BUILD')
else: print('TRANSITIVE')
\""

# Rails: check if it's in Gemfile with group
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && grep -A2 '<gem_name>' Gemfile"
```

**c) Is it used directly in the codebase?**
```bash
gitpod environment ssh $ENV_ID -- \
  "cd /workspaces/\$(ls /workspaces/) && grep -r '<package-name>' --include='*.{js,ts,jsx,tsx,rb,py}' -l | grep -v node_modules | grep -v vendor"
```

**d) Classify risk:**

| Bump type | Direct import? | Dep type | Risk |
|-----------|---------------|----------|------|
| Patch (x.x.1->x.x.2) | No (transitive) | Any | Low |
| Patch | Yes | Dev/build | Low |
| Patch | Yes | Runtime | Low |
| Minor (x.1->x.2) | No | Any | Low |
| Minor | Yes | Dev/build | Medium |
| Minor | Yes | Runtime | Medium |
| Major (1.x->2.x) | No | Any | Medium |
| Major | Yes | Dev/build | Medium |
| Major | Yes | Runtime | High |
| Any bump on core framework (rails, strapi, react, etc.) | -- | -- | High |

### Phase 4: Install & build with new dependency

```bash
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm install && npm run build"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle install && bundle exec rails assets:precompile"
```

If build fails -> **STOP. Flag for Max. Do not merge.** Reset to main.

### Phase 5: Restart services if needed

If the dependency is a **runtime** dep, services that use it need a restart to pick up the new version.

```bash
# Strapi / Node servers:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && pkill -f 'node.*strapi\|node.*server' 2>/dev/null; npm run develop &"

# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && pkill -f puma 2>/dev/null; bundle exec rails server -d"
```

For **dev/build** deps (linters, test tools, build plugins): no restart needed, just verify build passed.

### Phase 6: Run tests

```bash
# Node/JS:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && npm test"
# Rails:
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && bundle exec rspec"
```

Compare results against pre-flight baseline:
- Same pass count, no new failures -> pass
- New failures -> **STOP. Flag for Max.**
- Fewer tests (tests removed?) -> investigate, likely flag for Max

### Phase 7: Merge decision

| Build | Tests | Risk | Action |
|-------|-------|------|--------|
| pass | pass | Low | **Auto-merge with [skip ci]** (or label if `merge_strategy: label-only`) |
| pass | pass | Medium (no direct usage) | **Auto-merge with [skip ci]** (or label if `merge_strategy: label-only`) |
| pass | pass | Medium (direct usage) | **Write targeted tests first** (Phase 7b) |
| pass | pass | High | **Flag for Max** with analysis |
| fail | any | any | **Flag for Max** |
| any | fail | any | **Flag for Max** |

### Phase 7b: Write targeted tests (medium with direct usage)

Delegate to Claude Code inside the environment:

```bash
gitpod environment ssh $ENV_ID -- \
  "cd /workspaces/\$(ls /workspaces/) && claude -p --dangerously-skip-permissions --verbose \
  'The dependency <package> was bumped from <old> to <new>. It is used in these files: <files>. Write a focused test that exercises the specific functionality we use from this library. Run the test and confirm it passes. Do NOT commit -- just create the test file and show results.'"
```

- If targeted tests pass -> **flag for manual review** (Max should see the new tests and decide)
- If targeted tests fail -> **flag for Max** with failure details
- Do NOT auto-merge PRs that needed new tests -- Max reviews those

### Phase 8: Merge or label (safe PRs only)

**Pipeline enforcement:** Before merging, verify the full review pipeline has run.
Check for `reviewed` and `double-checked` labels. If missing, apply `reviewed` label
to trigger the pipeline (double-check -> cto-review -> merge). Do NOT merge directly
without these labels -- the CTO is responsible for the final merge decision.

```bash
PR_NUMBER=<number>
ORG_REPO="<org>/<repo>"

# Check current labels on the PR
LABELS=$(gh pr view $PR_NUMBER --repo $ORG_REPO --json labels --jq '.labels[].name' 2>/dev/null)

HAS_REVIEWED=$(echo "$LABELS" | grep -c "^reviewed$" || true)
HAS_DOUBLE_CHECKED=$(echo "$LABELS" | grep -c "^double-checked$" || true)

# Check merge_strategy (default: auto)
MERGE_STRATEGY=$(python3 -c "
import yaml
with open('$PYLOT_DIR/crew.yml') as f:
    data = yaml.safe_load(f)
for team, cfg in data.get('crew', {}).items():
    if not isinstance(cfg, dict): continue
    for r in cfg.get('repos', []):
        if r.lower() == '$ORG_REPO'.lower():
            print(cfg.get('merge_strategy', 'auto'))
            exit()
print('auto')
" 2>/dev/null || echo "auto")

if [ "$MERGE_STRATEGY" = "label-only" ]; then
  # Label instead of merging -- human merges manually
  gh label create "ready-to-merge" --repo $ORG_REPO --color "0e8a16" --description "Agent-verified, Max merges" 2>/dev/null || true
  gh pr edit $PR_NUMBER --repo $ORG_REPO --add-label "ready-to-merge"
elif [ "$HAS_REVIEWED" = "0" ]; then
  # Pipeline not started -- apply 'reviewed' to trigger double-check -> cto-review chain
  gh label create "reviewed" --repo $ORG_REPO --color "1d76db" --description "First-pass review complete" 2>/dev/null || true
  gh pr edit $PR_NUMBER --repo $ORG_REPO --add-label "reviewed"
  # Do NOT merge. The event router will trigger double-check, then cto-review, then CTO merges.
elif [ "$HAS_DOUBLE_CHECKED" = "0" ]; then
  # Reviewed but not double-checked -- pipeline in progress, do not merge yet
  echo "PR has 'reviewed' but not 'double-checked'. Waiting for pipeline to complete."
else
  # Full pipeline complete (reviewed + double-checked) -- CTO can merge
  gitpod environment ssh $ENV_ID -- "gh pr merge $PR_NUMBER --repo $ORG_REPO --squash -t 'chore(deps): merge #$PR_NUMBER [skip ci]' -b 'Auto-merged dependency update. Build and tests verified in Ona container. Pipeline: reviewed + double-checked.'"
fi
```

### Phase 9: Reset for next PR

```bash
gitpod environment ssh $ENV_ID -- "cd /workspaces/\$(ls /workspaces/) && \
  git checkout main && git pull && \
  git config --unset user.name 2>/dev/null; \
  git config --unset user.email 2>/dev/null"
```

Repeat from Phase 2 for the next PR.

### Phase 10: Release environment

After ALL PRs are processed (or no more candidates), stop the Ona environment:

```bash
gitpod environment stop $ENV_ID
```

**Do not skip this step.** Leaked environments burn Ona credits until manually stopped or reaped.

## Report (REQUIRED)

Every deps run produces a report at `reports/YYYY-MM-DD-deps-REPO-BRANCH.md` (use the full branch name of each PR -- one report per dependency PR processed).

Before starting, fetch all candidate PRs -- the report begins with what was picked up:

```bash
gh pr list --repo $REPO --label dependencies --json number,title,author,createdAt,headRefName,url
```

### Report Template

```markdown
# Deps Run: [org/repo]

**Date:** YYYY-MM-DD
**Repo:** [org/repo]
**Ona Environment:** [ENV_ID]
**Baseline:** [N tests passing on main, build time]

## Source PRs

| PR | Title | Author | Created | Age |
|----|-------|--------|---------|-----|
| #N | [title] | @[bot] | YYYY-MM-DD | [N days] |
| ... | ... | ... | ... | ... |

[Total: N PRs picked up for processing]

## Pre-Flight

- **Main branch:** [compiles: yes/no, tests: N passing / N failing]
- **Environment health:** [services running, database seeded]
- **Booster sync:** [synced / skipped (no booster remote) / conflict-aborted — issue filed]
- **Blockers:** [any issues found before starting]

## Results Per PR

### PR #N -- [title]

- **Package:** [name] [old] -> [new] ([bump type])
- **Dep type:** [runtime / devDep / transitive]
- **Direct usage:** [yes (N files) / no]
- **Risk:** [low/medium/high]
- **Build:** [pass / fail -- error summary if failed]
- **Tests:** [pass (N/N) / fail -- failure summary]
- **Action:** [auto-merged / flagged for Max / needs tests / blocked]
- **Notes:** [any issues encountered]

[Repeat for each PR processed]

## Summary

Merged [skip ci]:
- #N [package] [old]->[new] ([risk] [dep type])

Needs Max (with tests written):
- #N [package] [old]->[new] ([risk], new test at [path])

Needs Max (complex/failed):
- #N [package] [old]->[new] ([risk], [reason])

Skipped:
- #N [package] -- [reason skipped]

## Lessons

[Anything new learned -- dependency gotchas, environment issues, patterns to add]
```

## Important Notes

- **Pre-flight is mandatory.** If main doesn't compile, nothing else matters.
- **One PR at a time.** Reset to main between each PR.
- **Never auto-merge high risk.** Always flag for Max.
- **[skip ci] on all merges.** CI already ran on the PR branch.
- **PRs that needed new tests -> manual review.** Even if tests pass, Max sees them first.

## Lessons Learned (2026-02-16, Farmesa run)

- **Stash local changes before checkout** -- devcontainer lifecycle may leave modified files (e.g., devcontainer.json). Run `git stash` on main before switching branches.
- **Dependabot doesn't bump companion packages** -- react without react-dom, @strapi/strapi without @strapi/plugin-*. These cause version mismatches that fail builds. Classify as high risk and flag.
- **Lockfile-only PRs are still worth merging** -- after merging a package, its companion PR may become lockfile-only (transitive dep updates). Still verify build and merge.
- **First yarn install is slow (~2min for Strapi)** -- 860+ packages. Don't kill it prematurely. Check `ps aux | grep yarn` and module count to verify progress.
- **Don't pipe yarn install through `tail` during debugging** -- yarn buffers output. Use no pipe or `head -50` to see progress. Only use `tail` for final result capture.
- **Process PRs lowest-risk first** -- frontend devDeps (patches) before backend runtime deps. Builds confidence and catches environment issues early on safe PRs.

## Python Repos: Docker Build Verification

For Python repos that have **no test suite** but have a `container/Dockerfile` (e.g., navvi), use docker build as the verification step instead of running tests.

### Detect Python repo without test suite

```bash
# Python repo = requirements.txt or pyproject.toml exists
IS_PYTHON=$(gitpod environment ssh $ENV_ID -- "cd /workspaces/$(ls /workspaces/) && [ -f requirements.txt ] || [ -f pyproject.toml ] && echo yes || echo no")

# No test suite = no test_*.py files
HAS_TESTS=$(gitpod environment ssh $ENV_ID -- "cd /workspaces/$(ls /workspaces/) && find . -name 'test_*.py' -o -name '*_test.py' | grep -v node_modules | head -1 | wc -l")
```

If `IS_PYTHON=yes` and `HAS_TESTS=0`: use docker build verification below. Skip Phases 1 and 6.

### Docker build verification (replaces test suite)

After Phase 4 (install), if a `container/` directory exists:

```bash
gitpod environment ssh $ENV_ID -- "cd /workspaces/$(ls /workspaces/) && docker build container/ -t dep-verify:test 2>&1"
```

- **Build passes** → treat same as test pass. Apply Phase 7 merge decision.
- **Build fails** → STOP. Flag for Max. Do not merge.
- **No `container/` dir** → flag for Max (no verification path available).

### Merge decision for Python repos

| Docker build | Risk | Action |
|-------------|------|--------|
| pass | Low | Auto-merge with [skip ci] |
| pass | Medium (no direct usage) | Auto-merge with [skip ci] |
| pass | Medium/High | Flag for Max |
| fail | any | Flag for Max |

## Lessons Learned (2026-04-14, navvi run)

- **Python dep PRs (fastapi, uvicorn) require docker build** — no test suite means standard verify flow doesn't apply. Use `docker build container/` in a Codespace.
- **Provision Codespace for Python deps runs** — Codespace with Docker daemon is the most reliable environment for this verification.
