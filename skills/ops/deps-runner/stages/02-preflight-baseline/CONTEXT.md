# Stage 02: Preflight Baseline (subagent)

## Inputs
- `.procedure-output/deps-runner/01-scan-context/handoff.md`

## Task
Verify the worker is healthy on `main` BEFORE touching any PR branch, record the baseline,
and sync the booster remote if this is a downstream booster-pack site. If preflight fails,
the environment is broken — record the blocker; downstream stages must not merge anything.

This stage assumes stage 01 already reported `devbox_ready: true` and a live `worker_id` — if
it did not, the orchestrator does not run this stage at all (see SKILL.md Hard Rule 8).

## Steps

Read `worker_id` from the stage 01 handoff. If a drive call below reports the worker as
`stopped`/`reaped` (check with `pylot workers view "$WID" --mission "$PYLOT_JOB_ID"`),
spawn a replacement (`pylot workers spawn --mission "$PYLOT_JOB_ID" repo="$REPO" name=...`)
and use the new id for the rest of this stage and the handoff.

### 1. Verify main compiles
```bash
WID="<worker_id from stage 01 handoff>"

pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 120 \
  "Run: git stash; git checkout main && git pull. Report the exact output and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
(`git stash` first — the devbox image's lifecycle may leave modified files, e.g. lockfiles
touched by a prior boot script.)

### 2. Install deps & build (baseline)
```bash
# Node/JS:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 600 \
  "Run: npm install && npm run build. Report the exact output and exit code."
# Rails:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 600 \
  "Run: bundle install && bundle exec rails assets:precompile. Report the exact output and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```

### 3. Run test suite (baseline)
```bash
# Node/JS:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 900 \
  "Run: npm test. Report the exact pass/fail counts and exit code."
# Rails:
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 900 \
  "Run: bundle exec rspec. Report the exact pass/fail counts and exit code."
pylot workers output "$WID" --mission "$PYLOT_JOB_ID"
```
Record the baseline: number of passing tests, build time, any existing warnings. This is the
reference point for stage 04.

> Python repo with NO test suite but a `container/Dockerfile`: skip the test-suite baseline.
> Stage 04 verifies via `docker build container/` instead.

### 4. Booster remote sync (downstream sites only)
Both checks below are LLM-mediated (the worker's own agent parses and reports, rather than a
raw shell handing back a deterministic exit status), so prompt for a strict single-token/numeric
response and treat anything else as unparseable rather than loosely pattern-matching prose.
```bash
pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
  "Run: git remote | grep -c '^booster$' || echo 0. Reply with ONLY the resulting number as a bare digit — no words, no punctuation, nothing else on the line."
HAS_BOOSTER=$(pylot workers output "$WID" --mission "$PYLOT_JOB_ID" | tr -d '[:space:]')

if [ "$HAS_BOOSTER" = "1" ]; then
  echo "==> booster remote detected — syncing booster/main before deps run"
  pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 120 \
    "Run: git fetch booster && git merge booster/main --no-edit; echo \"EXIT_CODE=\$?\". Report the exact command output, then on its own final line report ONLY the text EXIT_CODE=<N> with the real numeric exit code substituted for <N> — no other words on that line."
  MERGE_RESULT=$(pylot workers output "$WID" --mission "$PYLOT_JOB_ID")

  if echo "$MERGE_RESULT" | grep -qE "EXIT_CODE=0$"; then
    echo "==> booster/main merged successfully"
    BOOSTER_SYNC_STATUS="synced"
  else
    echo "==> booster/main merge CONFLICT — aborting"
    pylot workers prompt "$WID" --mission "$PYLOT_JOB_ID" --wait --timeout 60 \
      "Run: git merge --abort. Report the exit code."
    gh issue create --repo "$REPO" \
      --title "deps-runner: booster/main merge conflict on $(date +%Y-%m-%d)" \
      --body "The deps-runner detected a merge conflict when syncing \`booster/main\` into \`main\` on \`$REPO\`.

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

## Worker
worker_id: {WID — forwarded from stage 01, or the replacement id if respawned}

## Status
preflight_ok: {true|false}

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
- `worker_id` forwarded (or a respawned replacement recorded)
- Booster sync status recorded

## Failure
- Main does not compile / baseline tests fail → `preflight_ok: false`, `proceed: false`. STOP
  fixing nothing — the orchestrator routes straight to 06-report (blocked).
- Booster conflict → issue filed, `proceed: false`, route to report.
- Worker unreachable / reaped and a respawn also fails → record as a hard blocker, `proceed:
  false`, route to report.
