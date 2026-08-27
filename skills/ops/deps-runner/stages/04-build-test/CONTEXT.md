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

Read `worker_id` from the stage 03 handoff. For each PR:

### 1. Decontaminate, checkout PR branch, merge main
Reset repo-level git identity first — a previous run's targeted-test step may have set
`orchestrator@fellowship.dev`, overriding the global `~/.gitconfig` (populated from the
`$GITCONFIG` personal secret):
```bash
WID="<worker_id from stage 03 handoff>"
BRANCH="<pr-branch-name>"

pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: git config --unset user.name 2>/dev/null; git config --unset user.email 2>/dev/null; git fetch origin $BRANCH && git checkout $BRANCH. Report the exact output and exit code."

# CRITICAL: Merge main into the branch so it has latest changes
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: git merge origin/main --no-edit. Report the exact output and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
If the merge has conflicts → record **flag for Max** (PR too stale, needs manual rebasing), set
this PR's result to `blocked`, skip to reset/next PR. Do NOT proceed for this PR.

### 2. Install & build with the new dependency
```bash
# Node/JS:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 600 \
  "Run: npm install && npm run build. Report the exact output and exit code."
# Rails:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 600 \
  "Run: bundle install && bundle exec rails assets:precompile. Report the exact output and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
If build fails → record **flag for Max, do not merge**, set result `build:fail`, reset to main, next PR.

> First yarn/npm install is slow (~2min for Strapi, 860+ pkgs). Use `--timeout 900` for large
> repos rather than killing the prompt prematurely.

### 3. Restart services if runtime dep
The worker-prompt instruction is executed by the worker's own agent, not a raw SSH shell — a
plain trailing `&` only backgrounds correctly if that agent's shell tool returns control
immediately after launching the process rather than blocking until it exits. Do NOT rely on
`--wait --timeout 60` racing an indefinitely-running foreground dev server; if the shell tool
waits for the command to complete, a `develop &`/`server -d` process that never exits will hang
the prompt until the 60s timeout fires. Instead, explicitly instruct the worker to detach the
process (`nohup ... & disown`) and print a fixed sentinel string as soon as the backgrounding
command itself returns, and treat that sentinel text — not the `--wait` call completing on its
own — as the "it started" signal:
```bash
# Strapi / Node servers:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: pkill -f 'node.*strapi\|node.*server' 2>/dev/null; nohup npm run develop > /tmp/deps-runner-dev.log 2>&1 & disown; echo started. Confirm the shell returned control immediately after backgrounding (did not block on the dev server process), then report the 'started' line and exit code."
# Rails:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: pkill -f puma 2>/dev/null; nohup bundle exec rails server -d > /tmp/deps-runner-dev.log 2>&1 & disown; echo started. Confirm the shell returned control immediately after backgrounding (did not block on the dev server process), then report the 'started' line and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
Treat the `started` sentinel text in the reported output as the signal that backgrounding
succeeded. If the prompt instead times out at 60s with no `started` sentinel reported, treat
that as evidence the worker's shell tool blocked on the foreground process rather than a
transient timeout — flag for Max rather than retrying with a longer timeout, since a longer
timeout would still eventually hit an indefinitely-running process.

Dev/build deps (linters, test tools, build plugins): no restart — just verify build passed.

### 4. Run tests
```bash
# Node/JS:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 900 \
  "Run: npm test. Report the exact pass/fail counts and exit code."
# Rails:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 900 \
  "Run: bundle exec rspec. Report the exact pass/fail counts and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
Compare against the stage-02 baseline:
- Same pass count, no new failures → pass
- New failures → **flag for Max** (`tests:fail`)
- Fewer tests (tests removed?) → investigate, likely flag for Max

### 4-python) Docker build verification (Python repo, no test suite)
If `IS_PYTHON=yes` and `HAS_TESTS=0` and a `container/` dir exists, replace steps 3–4 with:
```bash
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 900 \
  "Run: docker build container/ -t dep-verify:test. Report the exact output and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
- Build passes → treat as test pass.
- Build fails → flag for Max, do not merge.
- No `container/` dir → flag for Max (no verification path).

### 5. Reset for next PR
```bash
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: git checkout main && git pull; git config --unset user.name 2>/dev/null; git config --unset user.email 2>/dev/null. Report the exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```

### 6. Write handoff (all PRs).

## Output: handoff.md

Path: `.procedure-output/deps-runner/04-build-test/handoff.md`

```markdown
# Stage 04: Build & Test

## Worker
worker_id: {forwarded from stage 03}

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
- `worker_id` forwarded unchanged

## Failure
- A PR's merge conflicts / build fails / tests fail → that PR is marked accordingly and
  flagged; the stage continues to the next PR. The stage only "fails" the run if the worker
  itself dies (`pylot workers view` shows `stopped`/`reaped` mid-stage) — in that case respawn
  a replacement, record the new `worker_id`, and continue from the current PR; if the respawn
  also fails, record the worker failure and let the orchestrator decide
  (`resume_from=04-build-test` after the devbox recovers).
