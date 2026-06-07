# Stage 07: Report + Outcome Marker (inline)

## Inputs
- All upstream handoffs under `.procedure-output/release-train-runner/`:
  - `00-claim-compute/handoff.md` (compute, REPO, RELEASE_DATE)
  - `01-preflight/handoff.md` (manifest, default branch, preflight skips)
  - `02-release-branch/handoff.md` (release branch name)
  - `03-validate-integrate/handoff.md` (per-PR log, conflict log, test results, skips)
  - `04-lockfiles/handoff.md` (lockfile action + post-lockfile tests)
  - `05-push-release-pr/handoff.md` (release PR number + URL)
  - `06-release-env/handoff.md` (teardown status)
- `shared/report-template.md` (report structure)

## Task
Write the durable local report file, then emit the outcome marker. This stage runs inline in the
orchestrator — do NOT spawn a Task — and the `[pylot] outcome=...` marker MUST come from here,
never from a subagent. **NO QUEST** — the local report file is the only reporting sink.

## Steps

1. Read every upstream handoff.

2. Compose the report from `shared/report-template.md`, filling: source-PR table (with merge/test/
   status per PR), conflict log, after-each-merge test results, combined manual test plan, and the
   verdict.

3. Write the report file (the ONLY reporting sink — no Quest POST follows it):
```
reports/YYYY-MM-DD-release-train-ORG-REPO.md
```
   Replace `/` with `-` in the repo name (e.g. `Lexgo-cl/rails-backend` → `Lexgo-cl-rails-backend`).

4. Emit the outcome marker from the orchestrator (inline):
   - Success: `[pylot] outcome="release train ready: N PRs merged into release/YYYY-MM-DD" status=success`
   - If the chain reached here only because of a non-fatal teardown issue, still success — note the
     dangling env in the report.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/07-report/handoff.md`

```markdown
# Stage 07: Report

## Status
report_ok: true

## Report File
reports/{YYYY-MM-DD}-release-train-{ORG-REPO}.md

## Summary
- Included: {count} PRs
- Skipped: {count} PRs
- Release PR: #N — {url}
- Final tests: {PASS (N examples, M baseline)}

## Outcome Marker Emitted
[pylot] outcome="release train ready: N PRs merged into release/YYYY-MM-DD" status=success
```

## Success criteria
- Local report file written under `reports/` with the correct `ORG-REPO` slug
- Report contains the source-PR table, conflict log, test results, and combined manual test plan
- Outcome marker emitted by the orchestrator (inline), not a subagent
- No Quest call anywhere

## Failure
- This stage does not fail the train; if a prior stage emitted a failed/blocked outcome, that
  marker already stopped the chain before reaching here.
