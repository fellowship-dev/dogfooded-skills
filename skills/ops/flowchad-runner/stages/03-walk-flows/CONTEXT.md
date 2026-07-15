# Stage 03: Walk Flows — SEQUENTIAL loop (subagent)

## Inputs
- `.procedure-output/flowchad-runner/01-preflight/handoff.md`
  (read `target_url`, `navvi_available`, `navvi_persona`, `transcript_path`, `report_date`)
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

## Steps

Iterate the walk order sequentially: `for FLOW in <walk order>; do … done`. Finish one flow
completely (including stopping its recording) before starting the next.

### 2a. Choose browser & connect (per flow)

**Decision logic — per flow:**
1. Read the stage 02 `interactive`, `captcha`, and `prefers` classification.
2. If captcha/headed found AND `navvi_available=true` → use Navvi.
3. Otherwise → use headless Playwright (fast path).
4. If the required browser cannot connect, set the flow to `blocked`. Static/curl diagnostics
   may be captured separately but cannot execute or pass the flow.

**Headless Playwright (default):**
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

## Per-flow results
| Flow | Status | Steps (pass/total) | Browser | CAPTCHA switch | Snapshot dir | results.json |
|------|--------|--------------------|---------|----------------|--------------|--------------|
| {name} | pass/fail/blocked | M/N | playwright/navvi/none | yes@step K / no / blocked | .flowchad/snapshots/{date}-{slug}/ | {path} |

## Step-level detail (per flow)
{for each flow: a table of step | status | timing | browser | error/note}

## Transcript
path: {transcript_path}

## Evidence to upload
{list of snapshot dirs + gif/png paths produced, for stage 04}
```

## Success criteria
- Every flow in the walk order was attempted, sequentially, one at a time.
- Each attempted flow has results.json and a flow-level pass/fail/blocked verdict. Browser-driven
  attempts also have a snapshot directory; capability blocks record why no snapshot exists.
- Every `pass` includes real-browser screenshots/video plus a browser identifier in results.json.
- Transcript appended for every step.

## Failure
- A flow that errors mid-walk is still recorded (broken step = finding). If no required browser
  can be driven, set affected flows `blocked` with the connection/capability error and still write
  the handoff so stage 05 can report. Static analysis cannot replace the missing evidence.
