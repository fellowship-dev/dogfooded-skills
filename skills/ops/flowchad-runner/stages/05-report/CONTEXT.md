# Stage 05: Report (inline)

## Inputs
- `.procedure-output/flowchad-runner/01-preflight/handoff.md`
  (read `flow_name`, `repo`, `pr_number`, `report_date`, `report_path`, `transcript_path`,
  `target_url`, `target_kind`, `target_sha`, `result_state`)
- `.procedure-output/flowchad-runner/03-walk-flows/handoff.md` (per-flow + step results,
  `worker_id`)
- `.procedure-output/flowchad-runner/04-upload-evidence/handoff.md` (`upload_ok`, `uploaded`
  counts, per-step evidence URLs)

## Task
Aggregate all flow results, post results to GitHub, create/dedupe issues on failure, write the local
report file, and emit the outcome marker. **This stage runs INLINE in the orchestrator — do
NOT spawn a Task.** The `[pylot] outcome=...` marker MUST come from here.

> NO Quest. There is no Quest POST, no `127.0.0.1:4242`, no `quest.fellowship.dev`, no
> `QUEST_TOKEN`. Reporting is the GitHub surfaces + the local report file ONLY. Operators
> surface the report via the mission report.

## Steps

### 1. Aggregate
Read stages 01/03/04 handoffs. Compute overall status: `N/A` if preflight selected no affected
flow; otherwise `BLOCKED` if any required flow was blocked; otherwise `PASSED` if every flow
passed; otherwise `FAILED`. Build the per-step results table per flow, attaching evidence URLs.
Never compute `PASSED` unless every interactive flow records real browser evidence.

### 2. Post results to GitHub (if pr_number set)

**A flow-walk verdict without receipts is testimony, not evidence.** Every step that produced
a screenshot gets its URL embedded in the comment — not a footnote, not "evidence available in
the snapshot dir". Take the per-step URLs from the stage 04 handoff and put them in the table.

Embed each screenshot as **image-wrapped-in-link** — `[![alt](URL)](URL)`. Evidence-class
assets are served `Content-Disposition: attachment`, so the image may not inline-render in
every surface; the wrapping link guarantees the receipt is at least reachable, and it is
permanent (see evidence-upload's retention section). Do not strip the link form back to a bare
`![](URL)` until the gateway's disposition fix lands.

```bash
gh pr comment $PR_NUMBER --repo $REPO --body "## FlowChad Results: ${FLOW_NAME}
**Status**: PASSED / FAILED / BLOCKED / N/A
**Date**: ${REPORT_DATE}
**Browser**: Playwright headless (worker devbox) / Navvi (auto-switched)
**Evidence**: ${UPLOADED}/${TOTAL} uploaded (${UPLOAD_OK})

### Step Results
| Step | Status | Timing | Browser | Screenshot | Notes |
|------|--------|--------|---------|------------|-------|
| step-1 | pass | 1.2s | playwright | [![step-1](URL)](URL) | |
| step-2 | pass | 3.1s | navvi | [![step-2](URL)](URL) | CAPTCHA auto-switch |
| step-3 | fail | 0.4s | playwright | [![step-3](URL)](URL) | expect not met: … |

### Walkthrough
[![${FLOW_NAME}](GIF_URL)](GIF_URL)

_Run by flowchad-runner_"
```

**Evidence-status line — always present, never omitted.** Read `upload_ok` and `uploaded` from
the stage 04 handoff and state them:

| stage 04 `upload_ok` | Line in the comment |
|---|---|
| `true` | `**Evidence**: 12/12 uploaded` |
| `partial` | `**Evidence**: ⚠️ 7/12 uploaded — 5 failed (publish). Screenshots below are incomplete.` |
| `false` | `**Evidence**: ⚠️ upload failed ({reason}) — screenshots were captured but could not be published. This verdict is unwitnessed.` |
| `skipped` | `**Evidence**: backend `none` — uploads disabled for this repo.` |

Never render a `false`/`partial` upload as a clean pass. A `PASSED` status with no receipts and
no warning is indistinguishable from a run that never opened a browser — which is the exact
failure this stage exists to prevent.

If the run is `BLOCKED` on capture host (no worker, no browser), say so plainly and name the
missing capability rather than implying the UI was inspected.

### 2b. Backstop: stop a leaked worker

Stage 04 owns the `stop` call for the stage 03 capture worker. If the stage 03 handoff carries
a `worker_id` and the stage 04 handoff does not report `worker_stopped: true`, stop it here:

```bash
curl -s --max-time 30 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API:-$PYLOT_GATEWAY_URL}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
```

### 3. On FAILURE — create or update a GitHub issue per failing flow

Build a stable fingerprint from repository + environment + flow + failed expectation. Search
open issues before creating one, especially in cron mode:

```bash
FINGERPRINT=$(printf '%s|%s|%s|%s' "$REPO" "$TARGET_KIND" "$FLOW_NAME" "$FAILED_EXPECTATION" \
  | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')
EXISTING_ISSUE=$(gh issue list --repo "$REPO" --state open \
  --search "flowchad:${FINGERPRINT} in:body" --json number --jq '.[0].number // empty')
```

When found, comment with the new date, target SHA, failing steps, and browser evidence URLs.
Otherwise create the issue and include `<!-- flowchad:${FINGERPRINT} -->` in its body:
```bash
gh issue create --repo $REPO \
  --title "FlowChad failure: ${FLOW_NAME} — ${REPORT_DATE}" \
  --label "ready-to-work" \
  --body "Flow ${FLOW_NAME} failed during automated walk on ${REPORT_DATE}.

**Failed steps:**
{list of failed steps with error messages}

**Evidence:**
{GIF and screenshot links}

<!-- flowchad:${FINGERPRINT} -->

This issue was auto-created by flowchad-runner. Fix the flow or the code, then re-run to verify."
```
This is the **closed-loop trigger** — the `ready-to-work` label + issue body gives speckit
enough context to investigate and fix.

### 4. Write the local report file
Write to `report_path` (`reports/${REPORT_DATE}-flowchad-${FLOW_SLUG}.md`):
```markdown
# FlowChad Run: ${FLOW_NAME} in ${REPO}
**Status**: PASSED / FAILED / BLOCKED / N/A
**Date**: ${REPORT_DATE}
**Browser**: Playwright / Navvi (auto-switched at step N)
**Transcript**: ${TRANSCRIPT}

## Steps
| Step | Status | Timing | Browser | Screenshot |
|------|--------|--------|---------|-----------|
| ... | pass/fail | Ns | playwright/navvi | [permanent URL] |

## Failures
[details if any]

## Evidence
upload_ok: {true|partial|false|skipped} — {uploaded}/{total}
Snapshot dir: .flowchad/snapshots/${REPORT_DATE}-${FLOW_SLUG}/ (on worker ${WID}, ephemeral)
GIF: [permanent URL if uploaded]
Failures: {file → reason, or "none"}
```

> The snapshot dir lives on a worker devbox that is stopped at the end of the run — it is not
> a durable reference. The published asset URLs are the only surviving evidence, which is why
> the upload accounting matters more than the local paths.

> Stop here. Do NOT POST the report anywhere. The local file is the deliverable; the mission
> report surfaces it.

### 5. Emit outcome marker (from the orchestrator, never a subagent)
```
# all passed
[pylot] outcome="flowchad ${FLOW_NAME} on ${REPO}: all flows passed" status=success

# one or more failed (issues already created in step 3)
[pylot] outcome="flowchad ${FLOW_NAME} on ${REPO}: {N} flow(s) failed" status=failed

# browser/deploy/credential capability missing
[pylot] outcome="flowchad blocked: ${BLOCK_REASON}" status=blocked

# irrelevant PR; no preview created
[pylot] outcome="flowchad N/A: no affected interactive flow" status=success
```

## Success criteria
- Local report file written at `report_path`.
- If `pr_number` set, PR comment posted.
- **Every step with an uploaded screenshot has that URL embedded in the PR comment**, and the
  evidence-status line reflects the stage 04 `upload_ok`/counts verbatim.
- On any flow failure, a `ready-to-work` issue created and `status=failed` emitted.
- Cron failures update a matching open issue instead of creating duplicates.
- `BLOCKED` and `N/A` are reported explicitly and cannot be converted to `PASSED`.
- No capture worker is left running.
- `[pylot] outcome=...` marker emitted in the orchestrator session.

## Failure
- GitHub comment/issue API errors → log and continue; the report file + outcome marker are
  the primary signals and must still be produced.
