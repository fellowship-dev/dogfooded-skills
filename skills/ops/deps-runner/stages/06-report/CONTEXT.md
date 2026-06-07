# Stage 06: Report & Release (inline)

## Inputs
- `.procedure-output/deps-runner/01-scan-context/handoff.md`
- `.procedure-output/deps-runner/02-preflight-baseline/handoff.md`
- `.procedure-output/deps-runner/03-risk-eval/handoff.md`
- `.procedure-output/deps-runner/04-build-test/handoff.md`
- `.procedure-output/deps-runner/05-merge-decision/handoff.md`
- `../../shared/report-template.md` (the local report-file template)

## Task
Synthesize all stage handoffs into the local report file(s), release the Ona environment, and
emit the outcome marker. This stage runs inline in the orchestrator — do NOT spawn a Task.

**NO QUEST.** Write the local report file only. There is no Quest DB POST, no `127.0.0.1:4242`,
no `quest.fellowship.dev`, no `QUEST_TOKEN`. Operators surface the file via the mission report.

This stage runs even on a blocked/failed run (preflight failure, zero PRs) so a report always
exists.

## Steps

### 1. Write the local report file
Use the template at `shared/report-template.md`. One file per dependency PR processed, at:
```
reports/YYYY-MM-DD-deps-REPO-BRANCH.md
```
(Replace `/` with `-` in the repo name; use the full branch name of each PR.) The file MUST
start with the Source PRs that were picked up (from stage 01). Fill the Pre-Flight, Results Per
PR, Summary, and Lessons sections from the handoffs of stages 02–05.

### 2. Release the environment
After ALL PRs are processed (or the run is blocked / no candidates), stop the Ona environment:
```bash
gitpod environment stop $ENV_ID
```
Do NOT skip this — leaked environments burn Ona credits until manually stopped or reaped.

### 3. Emit the outcome marker (orchestrator only)
- Success: `[pylot] outcome="deps-runner complete: {merged}/{total} merged, {flagged} flagged" status=success`
- Failure: `[pylot] outcome="deps-runner failed at stage NN: {reason}" status=failed`
- Blocked (preflight failed): `[pylot] outcome="deps-runner blocked: preflight failed" status=blocked`

## Output: handoff.md

Path: `.procedure-output/deps-runner/06-report/handoff.md`

```markdown
# Stage 06: Report & Release

## Report Files Written
- reports/YYYY-MM-DD-deps-REPO-BRANCH.md
- ...

## Environment
released: {yes / FAILED: reason}

## Final Tally
total PRs: {N}
merged: {N}   labeled-pipeline: {N}   tests-written: {N}   flagged: {N}   blocked: {N}

## Outcome
{the [pylot] outcome=... marker emitted}
```

## Success criteria
- At least one report file written (or a single summary file if zero PRs)
- Report begins with the Source PRs
- Environment released
- `[pylot] outcome=...` marker emitted from the orchestrator (never a subagent)
- NO Quest POST anywhere

## Failure
- `gitpod environment stop` errors → still emit the outcome marker, but note the leaked
  environment in the report and flag it for manual reaping.
