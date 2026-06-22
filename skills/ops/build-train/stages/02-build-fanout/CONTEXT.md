# Stage 02: Build Fan-Out (subagent — PARALLEL wave scheduler)

## Inputs
- `.procedure-output/build-train/00-setup/handoff.md` — repo, default branch, build branch, manifest
- `.procedure-output/build-train/01-plan-order/handoff.md` — dependency edges + waves

## Task
Build every issue into a PR targeting the build branch, running builds **wave by wave**: all
builds in a wave launch as concurrent Task workers (parallel, no waiting between them within the
wave); the next wave starts only after the current wave fully joins. This honors the dependency
graph — independent builds run together, dependent builds wait for their prerequisite's output.

## Wave scheduler (the core loop)

For each wave W in order from stage 01's Waves table:

1. **Skip dependents of failed prereqs.** For each issue in W, check the sub-handoffs of its
   prerequisites (from the edges table). If any prerequisite has `status: failed`, mark this issue
   `skipped (prereq #X failed)`, write its sub-handoff, and do NOT launch it — it cannot consume
   missing output.

2. **Fan out the wave.** Launch ALL remaining issues in W as concurrent build Task workers in a
   SINGLE response. Do NOT wait between launches within the wave. Each Task drives one build (see
   "Per-build worker" below) and writes its sub-handoff.

3. **Join the wave.** Await every Task in W before starting wave W+1. A worker that errors is
   recorded `status: failed` in its sub-handoff; the wave still joins and the train continues.

4. Advance to W+1.

Builds joined by a sequential dependency edge are guaranteed to be in different waves, so a
dependent never launches before its prerequisite's PR exists.

## Per-build worker (one Task per issue)

Each build worker spawns a headless `claude -p` coding worker for its issue, then verifies the PR.

### Worker boot prompt (MUST repeat `--base $BUILD_BRANCH`)
```
You are headless. Never ask clarifying questions. Make assumptions and proceed.

CRITICAL INSTRUCTIONS — READ CAREFULLY:
1. Create your PR targeting branch "$BUILD_BRANCH" (NOT $DEFAULT_BRANCH, NOT main, NOT master)
2. Add the label "build-train" to your PR
3. Work ONLY on issue #$ISSUE_NUMBER — do not fix other issues or expand scope

To create the PR targeting the correct branch:
  gh pr create --repo $REPO --base $BUILD_BRANCH --head your-feature-branch --title "..." --body "..." --label build-train

TASK:
Fix/implement issue #$ISSUE_NUMBER on $REPO: $ISSUE_TITLE
$ISSUE_BODY_SUMMARY

EXPECTED OUTPUT:
A PR targeting $BUILD_BRANCH with the build-train label.
```

### Worker spawn (same pattern as crew-runner)
```bash
WORKER_SESSION=$(uuidgen)
WORKER_LOG="$WORKER_LOG_DIR/${WORKER_SESSION}.log"

(
  unset CLAUDECODE CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT
  cd $WORKER_DIR
  claude -p --verbose --session-id "$WORKER_SESSION" --dangerously-skip-permissions -- "$WORKER_PROMPT" </dev/null >> "$WORKER_LOG" 2>&1
) &
WORKER_PID=$!
```
Block until the local worker exits — but poll its PID in short **foreground chunks**, never
`wait "$WORKER_PID"` in one call. A worker turn can run for many minutes, and any Bash command
past the harness's ~120s tool timeout is auto-backgrounded and then **killed ~5s after your turn
ends** (pylot#1482), orphaning the work. Re-run this chunk until it prints `worker DONE`:

```bash
# ~96s chunk: poll the worker PID every 8s; exits early when it dies.
for _ in $(seq 1 12); do kill -0 "$WORKER_PID" 2>/dev/null || break; sleep 8; done
kill -0 "$WORKER_PID" 2>/dev/null && echo "worker RUNNING — run this chunk again" || echo "worker DONE"
```

(The previously-referenced `scripts/wait-for-job.sh` never existed.)

### Verify + fix the PR
1. Find the PR the worker created:
```bash
PR_NUMBER=$(gh pr list --repo $REPO --state open --label build-train --json number,headRefName \
  --jq ".[] | select(.number > $LAST_KNOWN_PR) | .number" | head -1)
```
2. **PR exists** — if not, log failure for this issue, mark `status: failed`, continue.
3. **PR targets the build branch** — fix if wrong:
```bash
BASE=$(gh pr view $PR_NUMBER --repo $REPO --json baseRefName -q .baseRefName)
if [ "$BASE" != "$BUILD_BRANCH" ]; then
  gh pr edit $PR_NUMBER --repo $REPO --base "$BUILD_BRANCH"
fi
```
4. **Has `build-train` label** — add if missing:
```bash
gh pr edit $PR_NUMBER --repo $REPO --add-label build-train
```

### On worker failure (max 2 retries per issue)
1. Read last 30 lines of the worker log.
2. If retries remain: adjust the prompt, re-dispatch the worker.
3. If exhausted: mark `status: failed (skipped)`, continue — do NOT fail the train.

### Per-build sub-handoff
Path: `.procedure-output/build-train/02-build-fanout/builds/{issue}.md`
```markdown
# Build #{issue}
status: {merged-ready | failed | skipped}
pr: #{N or none}
base: {BUILD_BRANCH}
labeled: {true|false}
notes: {retry count, failure reason, or "ok"}
```

## Output: handoff.md

Path: `.procedure-output/build-train/02-build-fanout/handoff.md`

```markdown
# Stage 02: Build Fan-Out

## Wave execution
| Wave | Issues launched | Concurrent | Joined |
|------|-----------------|------------|--------|
| 1 | #10, #15, #16 | yes (3) | ok |
| 2 | #14 | yes (1) | ok |

## Builds
| Issue | PR | Status | Base OK | Labeled | Notes |
|-------|----|--------|---------|---------|-------|
| #10 | #50 | ready | yes | yes | ok |
| #14 | #51 | ready | yes | yes | ok |
| #15 | — | failed | — | — | worker exhausted retries |

## PRs ready to merge
{#50, #51, ...}

## Skipped
{issue + reason, or "none"}
```

## Success criteria
- Every wave launched its members in parallel and fully joined before the next wave
- No dependent build started before its prerequisite's PR existed
- Every issue has a sub-handoff and a row in the Builds table
- Every successful PR verified to target the build branch and carry the build-train label

## Failure
- A single build failing → mark it `failed`, skip its dependents, continue the train
- ALL builds fail → write handoff, set no `PRs ready to merge`; stage 04 will have nothing to ship
  and the orchestrator emits the failure marker
