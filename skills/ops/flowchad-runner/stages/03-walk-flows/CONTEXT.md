# Stage 03: Walk Flows — SEQUENTIAL loop (subagent)

## Inputs
- `.procedure-output/flowchad-runner/01-preflight/handoff.md`
  (read `target_url`, `capture_host`, `navvi_available`, `navvi_persona`, `transcript_path`,
  `report_date`, `repo`)
- `.procedure-output/flowchad-runner/02-load-flows/handoff.md`
  (read the validated `walk order` and per-flow `prefers` hint)

## Task
Walk each flow in the walk order **ONE AT A TIME, in a sequential loop**. Do NOT fan out —
flows share the browser, session, and persona state and will collide if run concurrently.
For each flow: require & connect a real browser, execute every step (screenshot + expect-judgement
+ timing), handle errors and CAPTCHA→Navvi escalation, finalize video/GIF, and append to the
JSONL transcript.

> This is exactly one subagent. It loops over flows internally. There is NEVER one subagent
> per flow.

## Step 0 — resolve the browser host (do this FIRST)

**The operator image has no browser.** `Dockerfile.operator` installs no
`libnss3`/`libgbm1`/`libatk*`, so `chromium.launch()` in the operator turn fails with
*"missing system shared libraries … no sudo/apt-get available"* — measured on
[fellowship-dev/pylot#2802](https://github.com/fellowship-dev/pylot/pull/2802)
(2026-07-31), which is why that run returned `BLOCKED` with zero screenshots and the
verdict carried no receipts. The repo **devbox/worker** image
(`.devcontainer/Dockerfile`) carries exactly those libs. The dispatching automation's
own context already says *"Use qa worker."*

So there are exactly two legal capture hosts:

| `prefers` (stage 02) | Host | Why |
|---|---|---|
| `playwright` | **worker devbox** (spawned here) | only place chromium can launch |
| `navvi` | **operator turn** | Navvi is an MCP tool bound to the operator session; it cannot be reached from a worker |

Anything else is `blocked`. **Never** substitute a curl/static probe for a walk.

### Spawn the worker (only when at least one flow prefers `playwright`)

Follow the **pylot-workers** lifecycle (spawn → prompt → poll-to-idle → stop). Spawn once
and reuse it for every playwright flow; do **not** stop it here — stage 04 uploads from the
same worker and owns the `stop` call.

```bash
SPAWN_RESP=$(curl -s --max-time 90 -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"repo\": \"$REPO\"}" \
  "${PYLOT_API:-$PYLOT_GATEWAY_URL}/missions/${PYLOT_JOB_ID}/workers")
WID=$(echo "$SPAWN_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))')
[ -n "$WID" ] || { echo "BLOCKED: could not spawn a capture worker for $REPO"; }
```

If the spawn fails, every `playwright` flow is `blocked` with
`capture_host_unavailable` — record it and continue to the handoff so stage 05 still
reports. A missing browser host is `blocked`, never `pass` and never a silent skip.

### Drive the walk on the worker

Workers do **not** carry operator skills, so the prompt must be entirely self-contained:
inline the browser/step/screenshot recipe below rather than telling the worker to
"use flowchad-runner". First prompt provisions the browser, since the image ships the
system libs but not the browser binaries:

```
cd <repo checkout> && npx --yes playwright install chromium && npx --yes playwright --version
```

Then send one prompt per flow carrying: the flow YAML, `TARGET_URL`, the snapshot dir
(`.flowchad/snapshots/${date}-${flowName}`), and the instruction to write
`results.json` plus `step-{N}-{action}.png` for every step. Poll to idle between
prompts and read `last_output` before sending the next — a phase failure must be
detected before the next flow starts.

Evidence files stay on the worker. Record `evidence_host: worker:${WID}` per flow in the
handoff so stage 04 knows where to upload from; Navvi-driven flows record
`evidence_host: operator`.

## Steps

Iterate the walk order sequentially: `for FLOW in <walk order>; do … done`. Finish one flow
completely (including stopping its recording) before starting the next.

### 2a. Choose browser & connect (per flow)

**Decision logic — per flow:**
1. Read the stage 02 `interactive`, `captcha`, and `prefers` classification.
2. If captcha/headed found AND `navvi_available=true` → use Navvi, **in the operator turn**.
3. Otherwise → headless Playwright, **on the worker devbox spawned in step 0**.
4. If the required browser cannot connect, set the flow to `blocked`. Static/curl diagnostics
   may be captured separately but cannot execute or pass the flow.

**Headless Playwright (default) — this code runs ON THE WORKER, never in the operator turn:**
```javascript
import { chromium } from 'playwright-core';

let browser;
try {
  browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
} catch {
  browser = await chromium.launch({ headless: true });
}

const snapshotDir = `.flowchad/snapshots/${date}-${flowName}`;
const context = await browser.newContext({
  recordVideo: { dir: snapshotDir, size: { width: 1280, height: 720 } }
});
const page = await context.newPage();
```

**Navvi (for CAPTCHAs, bot detection, or authenticated flows):**
```
# Use Navvi MCP tools — connects to Camoufox headed browser
# Navvi handles fingerprinting, anti-detection, and CAPTCHA solving

# If persona is set (not "default"), load it
navvi_persona(name=NAVVI_PERSONA)   # if NAVVI_PERSONA != "default"

# Open the target URL
navvi_open(url=TARGET_URL)

# Use navvi_click, navvi_fill, navvi_scroll, navvi_screenshot for steps
# Use navvi_record_start / navvi_record_stop for video evidence
```

When using Navvi, map flow YAML actions to Navvi MCP tools:
- `navigate` → `navvi_open(url)`
- `click` → `navvi_click(selector)`
- `fill` → `navvi_fill(selector, value)`
- `scroll` → `navvi_scroll(direction)` or `navvi_scroll(selector)`
- `wait` → `navvi_find(selector)` with timeout
- `hover` → `navvi_mousemove(selector)`
- screenshot → `navvi_screenshot()`

### 2b. Execute each step from the flow YAML

For each step in the flow definition:
1. **Perform the action** — Playwright or Navvi tools depending on the browser chosen in 2a.
2. **Measure timing** — record before/after timestamps.
3. **Take screenshot** — Playwright `page.screenshot()` or `navvi_screenshot()`.
4. **Evaluate expect** — read the `expect` string from YAML (natural language), look at the
   screenshot and page state, determine if the expectation is met.
5. **Check timing threshold** — if `timing` is specified and actual > threshold, flag `slow`.

### 2c. Handle errors & auto-switch to Navvi

**A broken step is a finding, not a failure.** If a step throws:
- Catch the error, take a screenshot of current state.
- Log error, record status as `error`.
- **Continue to next step** — collect full evidence before stopping.

If step has `optional: true` and fails, record but don't flag as critical, except CAPTCHA in
production/cron: the contract validator blocks optional CAPTCHA before the walk.

**CAPTCHA auto-detection and Navvi escalation:**

If a step fails and the error or screenshot indicates a CAPTCHA challenge (Cloudflare
Turnstile, reCAPTCHA, Arkose, or similar bot detection):

1. If `navvi_available=true` and currently using headless Playwright:
   - Log: "CAPTCHA detected at step N — switching to Navvi"
   - Close the headless browser
   - Start Navvi: `navvi_start()` if not already running
   - Load persona: `navvi_persona(name=NAVVI_PERSONA)` (or default)
   - Navigate to the current page URL via `navvi_open(url)`
   - **Retry the failed step** using Navvi tools
   - **Continue remaining steps** with Navvi (don't switch back mid-flow)
2. If `navvi_available=false`:
   - Record status as `blocked` with note "CAPTCHA detected — Navvi not available"
   - Capture any static diagnostics separately and stop this flow; never roll it up as passed

CAPTCHA detection patterns (check error message AND screenshot):
- Cloudflare Turnstile: `cf-turnstile`, "Verify you are human", "Please complete the verification"
- reCAPTCHA: `g-recaptcha`, "I'm not a robot"
- Arkose: `arkoselabs`, "Verify your identity"
- Generic: any visible challenge iframe or "bot detection" text

### 2d. Stop recording, smart trim, GIF conversion

Close page to finalize video. Use ffmpeg for smart trim (cut dead frames using the action
log) and palette-optimized GIF conversion. See the flow-walk skill for the full ffmpeg
pipeline. If using Navvi: `navvi_record_stop()` to finalize, then process the output file.

**Output files per flow:**
- `step-{N}-{action}.png` — per-step screenshots
- `{flow-name}-full.webm` — raw recording
- `{flow-name}-trimmed.mp4` — action-only cut (if trim saves >20%)
- `{flow-name}.gif` — palette-optimized GIF
- `results.json` — structured results (steps, timing, pass/fail, evidence URLs)

### 2e. Log to JSONL transcript

Append every operation to the transcript file (`transcript_path` from stage 01):
```json
{"ts":"ISO8601","elapsed_ms":N,"phase":"walk","flow":"flow-name","step":"step-name","status":"pass|fail|skip","browser":"playwright|navvi","screenshot":null,"error":null}
```

### After the loop

A flow is `pass` only if all non-optional steps passed in a real browser and the evidence records
the browser session. Steps in `error`/`skipped`/`slow` roll up to `fail` when the browser ran and
demonstrated a defect. Missing required capability rolls up to `blocked`, never `fail` or `pass`.
Write the handoff aggregating all flows walked.

## Output: handoff.md

Path: `.procedure-output/flowchad-runner/03-walk-flows/handoff.md`

```markdown
# Stage 03: Walk Flows

## Summary
flows_walked: N
flows_passed: N
flows_failed: N
flows_blocked: N

## Capture host
worker_id: {WID or "none"}          # stage 04 uploads from here and owns the stop call
worker_spawn_ok: {true|false|n/a}
browser_provisioned: {true|false|n/a}

## Per-flow results
| Flow | Status | Steps (pass/total) | Browser | Evidence host | CAPTCHA switch | Snapshot dir | results.json |
|------|--------|--------------------|---------|---------------|----------------|--------------|--------------|
| {name} | pass/fail/blocked | M/N | playwright/navvi/none | worker:{WID} / operator / none | yes@step K / no / blocked | .flowchad/snapshots/{date}-{slug}/ | {path} |

## Step-level detail (per flow)
{for each flow: a table of step | status | timing | browser | screenshot file | error/note}

## Transcript
path: {transcript_path}

## Evidence to upload
{for each flow: evidence_host, then the absolute snapshot dir + every gif/png path produced,
 each tagged with the step it belongs to so stage 05 can embed per-step. Stage 04 needs the
 step association — a flat list of files cannot be placed back into the results table.}
```

## Success criteria
- Every flow in the walk order was attempted, sequentially, one at a time.
- Each attempted flow has results.json and a flow-level pass/fail/blocked verdict. Browser-driven
  attempts also have a snapshot directory; capability blocks record why no snapshot exists.
- Every `pass` includes real-browser screenshots/video plus a browser identifier in results.json.
- Every produced evidence file is listed with its `evidence_host` and its owning step.
- Transcript appended for every step.

## Failure
- A flow that errors mid-walk is still recorded (broken step = finding). If no required browser
  can be driven, set affected flows `blocked` with the connection/capability error and still write
  the handoff so stage 05 can report. Static analysis cannot replace the missing evidence.
