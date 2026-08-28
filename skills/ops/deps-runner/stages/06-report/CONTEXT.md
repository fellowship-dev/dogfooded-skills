# Stage 06: Report & Release (inline)

## Inputs
- `.procedure-output/deps-runner/01-scan-context/handoff.md`
- `.procedure-output/deps-runner/02-preflight-baseline/handoff.md` (if it ran)
- `.procedure-output/deps-runner/03-risk-eval/handoff.md` (if it ran)
- `.procedure-output/deps-runner/04-build-test/handoff.md` (if it ran)
- `.procedure-output/deps-runner/05-merge-decision/handoff.md` (if it ran)
- `../../shared/report-template.md` (the local report-file template)

## Task
Stop the worker, synthesize all stage handoffs into the local report file(s), and emit the
outcome marker. This stage runs inline in the orchestrator — do NOT spawn a Task.

**NO QUEST.** Write the local report file only. There is no Quest DB POST, no `127.0.0.1:4242`,
no `quest.fellowship.dev`, no `QUEST_TOKEN`. Operators surface the file via the mission report.

This stage runs even on a blocked/failed run (preflight failure, no devbox image, zero PRs) so
a report always exists.

## Steps

### 1. Stop the worker — FIRST action, before writing anything else
Read `worker_id` from the latest handoff that has one (05, or 04/03/02, or 01 if the run was
blocked before spawning progressed further). If stage 01 recorded `devbox_ready: false`, there
is no worker to stop — skip to step 2.
```bash
pylot workers stop "$WID" --mission "$PYLOT_JOB_ID" --force
```
`--force` is mandatory — the CLI refuses the stop without it. Stop is idempotent, so calling it
even on an already-idle/never-driven worker is safe. Do NOT skip this — a leaked worker keeps
burning Fargate compute until manually stopped or reaped.

**Confirm terminal state — a successful `stop` call only means the request was accepted, not
that the Fargate task has actually wound down.** Poll for confirmation on a bounded budget (5
attempts, 5 s apart, ~25 s total — the same order of magnitude as the documented boot window,
never open-ended). Two response shapes count as a confirmed stop for the matched `worker_id`
(never a differently-numbered worker's record):

- (a) `ecs_status == "STOPPED"` — the classic shape.
- (b) `ecs_status` is `null`/absent AND `status == "stopped"` (exact string) AND `stopped_at` is
  present/non-empty — the shape observed on canary mission
  `1787880706-tooling.cto-deps-runner-fellowship-dev-claude-buddy-intended-environment-canary-for-fellowsh-80ab49`
  (worker 9073): `workers list` returned `status=stopped`, a non-empty `stopped_at`, and
  `last_exit_code=0`, but `ecs_status=null`. That is a legitimate confirmed stop, not a failure
  to reach terminal state.

Anything else is NOT confirmed — including `status == "stopped"` with `stopped_at` null/empty,
`ecs_status` set to a live/contradicting value (e.g. `RUNNING`, `PROVISIONING`) while `status`
also disagrees, a missing `status` field, or a worker_id that never matches in the list response.
Those cases keep polling (or exhaust the bound and surface as `unconfirmed`), exactly as before.
```bash
CONFIRMED=false
for i in 1 2 3 4 5; do
  RESULT=$(pylot workers list --mission "$PYLOT_JOB_ID" | \
    python3 -c 'import sys,json
try:
    for w in json.load(sys.stdin):
        if w.get("worker_id") == "'"$WID"'":
            ecs_status = w.get("ecs_status")
            status = w.get("status")
            stopped_at = w.get("stopped_at")
            if ecs_status == "STOPPED":
                print("CONFIRMED:ecs_status=STOPPED")
            elif ecs_status in (None, "") and status == "stopped" and stopped_at:
                print("CONFIRMED:status=stopped,stopped_at=" + str(stopped_at))
            else:
                print("UNCONFIRMED:ecs_status=" + str(ecs_status) + ",status=" + str(status))
            break
    else:
        print("UNCONFIRMED:worker_id-not-found")
except Exception:
    print("UNCONFIRMED:parse-error")')
  case "$RESULT" in
    CONFIRMED:*) CONFIRMED=true; LAST_STATE="$RESULT"; break ;;
    *) LAST_STATE="$RESULT" ;;
  esac
  sleep 5
done
```
- `stop` call itself errors → retry once (see Failure below); if it still errors, do not poll —
  go straight to the `FAILED` handoff state.
- `stop` call accepted but `CONFIRMED` never becomes `true` within the 5-attempt budget → this is
  NOT `stopped: yes`. Record it honestly as `unconfirmed` with the last-observed `LAST_STATE`
  (or `unknown` if the poll itself never returned a record), and flag it for manual reaping —
  same as an explicit stop failure. Never write `stopped: yes` on an assumption; only on one of
  the two observed confirmed-stop shapes above.
- `CONFIRMED=true` → `stopped: yes`.

### 2. Write the local report file
Use the template at `shared/report-template.md`. One file per dependency PR processed, at:
```
reports/YYYY-MM-DD-deps-REPO-BRANCH.md
```
(Replace `/` with `-` in the repo name; use the full branch name of each PR.) The file MUST
start with the Source PRs that were picked up (from stage 01). Fill the Pre-Flight, Results Per
PR, Summary, and Lessons sections from the handoffs of stages 02–05 (or note "blocked — no
devbox image" if 02-05 never ran).

### 3. Emit the outcome marker (orchestrator only)
- Success: `[pylot] outcome="deps-runner complete: {merged}/{total} merged, {flagged} flagged" status=success`
- Failure: `[pylot] outcome="deps-runner failed at stage NN: {reason}" status=failed`
- Blocked (preflight failed, or no devbox image for the repo): `[pylot] outcome="deps-runner blocked: {reason}" status=blocked`

## Output: handoff.md

Path: `.procedure-output/deps-runner/06-report/handoff.md`

```markdown
# Stage 06: Report & Release

## Report Files Written
- reports/YYYY-MM-DD-deps-REPO-BRANCH.md
- ...

## Worker
worker_id: {the id that was (attempted to be) stopped, or "none — devbox unavailable, nothing spawned"}
stopped: {yes — confirmed via bounded poll (ecs_status==STOPPED, or status==stopped with a non-empty stopped_at) / unconfirmed — stop accepted, last observed ecs_status={ecs_status or "unknown"} status={status or "unknown"} after 5 attempts / FAILED: reason}

## Final Tally
total PRs: {N}
merged: {N}   labeled-pipeline: {N}   tests-written: {N}   flagged: {N}   blocked: {N}

## Outcome
{the [pylot] outcome=... marker emitted}
```

## Success criteria
- Worker stop confirmed via the bounded terminal-state poll — or honestly recorded as
  `unconfirmed`/`FAILED` — BEFORE the report is written. Never claim `stopped: yes` without an
  observed confirmed-stop shape (`ecs_status == STOPPED`, or `status == stopped` with a
  non-empty `stopped_at`) — or confirming there was never a worker to stop.
- At least one report file written (or a single summary file if zero PRs, or blocked)
- Report begins with the Source PRs
- `[pylot] outcome=...` marker emitted from the orchestrator (never a subagent)
- NO Quest POST anywhere

## Failure
- `pylot workers stop` errors → retry once, then still emit the outcome marker, but note the
  leaked worker in the report and flag it for manual reaping (`pylot workers list --mission
  "$PYLOT_JOB_ID"` to check its live `ecs_status`).
- `pylot workers stop` is accepted but the bounded terminal-state poll never observes either
  confirmed-stop shape within its 5-attempt budget → record `stopped: unconfirmed` with the
  last-observed status, still emit the outcome marker, and flag the worker for manual reaping
  exactly as on an explicit stop failure — an accepted-but-unconfirmed stop is not a cleanup
  success.
