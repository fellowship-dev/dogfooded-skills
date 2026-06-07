# Stage 05: Report (inline)

## Inputs
- `.procedure-output/flowchad-runner/01-preflight/handoff.md`
  (read `flow_name`, `repo`, `pr_number`, `report_date`, `report_path`, `transcript_path`,
  `target_url`)
- `.procedure-output/flowchad-runner/03-walk-flows/handoff.md` (per-flow + step results)
- `.procedure-output/flowchad-runner/04-upload-evidence/handoff.md` (evidence URLs)

## Task
Aggregate all flow results, post results to GitHub, create issues on failure, write the local
report file, and emit the outcome marker. **This stage runs INLINE in the orchestrator — do
NOT spawn a Task.** The `[pylot] outcome=...` marker MUST come from here.

> NO Quest. There is no Quest POST, no `127.0.0.1:4242`, no `quest.fellowship.dev`, no
> `QUEST_TOKEN`. Reporting is the GitHub surfaces + the local report file ONLY. Operators
> surface the report via the mission report.

## Steps

### 1. Aggregate
Read stages 01/03/04 handoffs. Compute overall status: PASSED if every flow passed, else
FAILED. Build the per-step results table per flow, attaching evidence URLs from stage 04.

### 2. Post results to GitHub (if pr_number set)
```bash
gh pr comment $PR_NUMBER --repo $REPO --body "## FlowChad Results: ${FLOW_NAME}
**Status**: PASSED / FAILED
**Date**: ${REPORT_DATE}
**Browser**: Playwright headless / Navvi (auto-switched)

### Step Results
| Step | Status | Timing | Browser | Notes |
|------|--------|--------|---------|-------|
| step-1 | pass | 1.2s | playwright | |
| step-2 | pass | 3.1s | navvi | CAPTCHA auto-switch |

[GIF embedded if available]

_Run by flowchad-runner_"
```

### 3. On FAILURE — create a GitHub issue per failing flow
```bash
gh issue create --repo $REPO \
  --title "FlowChad failure: ${FLOW_NAME} — ${REPORT_DATE}" \
  --label "ready-to-work" \
  --body "Flow ${FLOW_NAME} failed during automated walk on ${REPORT_DATE}.

**Failed steps:**
{list of failed steps with error messages}

**Evidence:**
{GIF and screenshot links}

This issue was auto-created by flowchad-runner. Fix the flow or the code, then re-run to verify."
```
This is the **closed-loop trigger** — the `ready-to-work` label + issue body gives speckit
enough context to investigate and fix.

### 4. Write the local report file
Write to `report_path` (`reports/${REPORT_DATE}-flowchad-${FLOW_SLUG}.md`):
```markdown
# FlowChad Run: ${FLOW_NAME} in ${REPO}
**Status**: PASSED / FAILED
**Date**: ${REPORT_DATE}
**Browser**: Playwright / Navvi (auto-switched at step N)
**Transcript**: ${TRANSCRIPT}

## Steps
| Step | Status | Timing | Browser | Screenshot |
|------|--------|--------|---------|-----------|
| ... | pass/fail | Ns | playwright/navvi | [link] |

## Failures
[details if any]

## Evidence
Snapshot dir: .flowchad/snapshots/${REPORT_DATE}-${FLOW_SLUG}/
GIF: [link if uploaded]
```

> Stop here. Do NOT POST the report anywhere. The local file is the deliverable; the mission
> report surfaces it.

### 5. Emit outcome marker (from the orchestrator, never a subagent)
```
# all passed
[pylot] outcome="flowchad ${FLOW_NAME} on ${REPO}: all flows passed" status=success

# one or more failed (issues already created in step 3)
[pylot] outcome="flowchad ${FLOW_NAME} on ${REPO}: {N} flow(s) failed" status=failed
```

## Success criteria
- Local report file written at `report_path`.
- If `pr_number` set, PR comment posted.
- On any flow failure, a `ready-to-work` issue created and `status=failed` emitted.
- `[pylot] outcome=...` marker emitted in the orchestrator session.

## Failure
- GitHub comment/issue API errors → log and continue; the report file + outcome marker are
  the primary signals and must still be produced.
