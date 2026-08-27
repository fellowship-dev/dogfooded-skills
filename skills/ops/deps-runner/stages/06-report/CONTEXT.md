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
worker_id: {the id that was stopped, or "none — devbox unavailable, nothing spawned"}
stopped: {yes / FAILED: reason}

## Final Tally
total PRs: {N}
merged: {N}   labeled-pipeline: {N}   tests-written: {N}   flagged: {N}   blocked: {N}

## Outcome
{the [pylot] outcome=... marker emitted}
```

## Success criteria
- Worker stopped (or confirmed there was never one to stop) BEFORE the report is written
- At least one report file written (or a single summary file if zero PRs, or blocked)
- Report begins with the Source PRs
- `[pylot] outcome=...` marker emitted from the orchestrator (never a subagent)
- NO Quest POST anywhere

## Failure
- `pylot workers stop` errors → retry once, then still emit the outcome marker, but note the
  leaked worker in the report and flag it for manual reaping (`pylot workers view "$WID"
  --mission "$PYLOT_JOB_ID"` to check its live status).
