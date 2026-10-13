---
name: visual-evidence
description: Use when capturing Playwright screenshots or GIF recordings for PR evidence — before/after comparisons and feature demos.
allowed-tools: Read, Write, Bash, Glob, Grep
metadata:
  version: 2.0.0
---

# visual-evidence

Capture browser screenshots and GIF recordings using Playwright headless Chromium. Upload them to the public evidence bucket (via **evidence-upload**) for embedding in PRs and reports.

## When to Use

- After implementing a bug fix (before/after comparison)
- After implementing a feature (demo key flows)
- During PR review to verify visual changes
- Interaction/timing bugs (double-click, loading states, race conditions) → use GIF recording

## When NOT to Use

- Backend-only changes, config/infra, test-only, CLI tools, APIs without UI
- Skip if Playwright install fails — visual evidence is best-effort, never blocks the pipeline

## Prerequisites

Install Playwright and Chromium in the remote environment:

```bash
cd /tmp && npm install playwright 2>&1 | tail -3 && \
  npx playwright install-deps chromium 2>&1 | tail -3 && \
  npx playwright install chromium 2>&1 | tail -3 && \
  echo PW_READY
```

For GIF recording, also install ffmpeg:

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg 2>&1 | tail -1 && echo FFMPEG_READY
```

## Workflow

### 1. Screenshot Capture

Create `/tmp/screenshot.mjs`:

```javascript
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
const [url, output] = process.argv.slice(2);
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
console.log(`Navigating to ${url}...`);
await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
const title = await page.title();
console.log(`Page title: ${title}`);
await page.screenshot({ path: output, fullPage: true });
console.log(`Screenshot saved: ${output}`);
await browser.close();
```

Usage:
```bash
node /tmp/screenshot.mjs http://localhost:3000 /tmp/evidence-home.png
node /tmp/screenshot.mjs http://localhost:3000/admin /tmp/evidence-admin.png
```

### 2. GIF Recording (Interaction Evidence)

Create `/tmp/record.mjs`:

```javascript
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
const [url, output, ...actions] = process.argv.slice(2);
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1280, height: 720 },
  recordVideo: { dir: '/tmp/videos', size: { width: 1280, height: 720 } }
});
const page = await context.newPage();
console.log(`Navigating to ${url}...`);
await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });

// Execute actions passed as JSON array
if (actions[0]) {
  const steps = JSON.parse(actions[0]);
  for (const step of steps) {
    if (step.action === 'click') {
      console.log(`Clicking ${step.selector}...`);
      await page.click(step.selector);
    } else if (step.action === 'dblclick') {
      console.log(`Double-clicking ${step.selector}...`);
      await page.click(step.selector);
      await page.waitForTimeout(200);
      await page.click(step.selector);
    } else if (step.action === 'wait') {
      console.log(`Waiting ${step.ms}ms...`);
      await page.waitForTimeout(step.ms);
    } else if (step.action === 'fill') {
      console.log(`Filling ${step.selector}...`);
      await page.fill(step.selector, step.value);
    } else if (step.action === 'screenshot') {
      console.log(`Snapshot: ${step.label}`);
      await page.screenshot({ path: `/tmp/evidence-${step.label}.png` });
    }
  }
}

await page.waitForTimeout(500);
await page.close();
await context.close();
await browser.close();

// Convert to GIF
const { execSync } = await import('child_process');
const webm = execSync('ls -t /tmp/videos/*.webm | head -1').toString().trim();
console.log(`Video: ${webm}`);
execSync(`ffmpeg -y -i "${webm}" -vf "fps=10,scale=1280:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" -loop 0 "${output}" 2>&1 | tail -3`);
console.log(`GIF saved: ${output}`);
```

Usage:
```bash
node /tmp/record.mjs http://localhost:3000/form /tmp/evidence-before.gif \
  '[{"action":"click","selector":".submit-btn"},{"action":"wait","ms":2000}]'
```

### 3. Upload to the Evidence Bucket

Use the **evidence-upload** skill. It uploads straight to the public evidence S3 bucket and
needs the `EVIDENCE_*` env secret; without it, it exits with *"not configured for this
environment"* — log that and skip (best-effort).

```bash
UPLOAD="<evidence-upload skill dir>/scripts/upload_evidence.sh"
"$UPLOAD" --alt "Before" /tmp/evidence-before.png
"$UPLOAD" --alt "After" /tmp/evidence-after.png
```

Each file prints its public URL and a ready-to-paste Markdown line; use those in Step 4.
Private repos do not render repo-relative images — that is why evidence goes to the bucket.
**Everything uploaded is public by URL:** capture staging or synthetic data, never secrets,
customer PII or production data.

### 4. PR Embedding

**Before/After (bug fixes):**
```markdown
## Visual Evidence

<details>
<summary>Before / After</summary>

**Before (bug present on default branch):**
![before](<before-url>)

**After (fix applied):**
![after](<after-url>)

</details>
```

**Interaction demo (GIF):**
```markdown
## Visual Evidence

<details>
<summary>Interaction demo</summary>

![demo](<demo-url>)
*Caption: what this demonstrates*

</details>
```

## Decision Table: Screenshot vs GIF

| Scenario | Format |
|----------|--------|
| Visual layout change | Screenshot (PNG) |
| New page / feature | Screenshot (PNG) |
| Button disable on click | **GIF** |
| Loading spinner / skeleton | **GIF** |
| Double-click prevention | **GIF** |
| Form validation feedback | **GIF** |
| Transition / animation | **GIF** |
| Error → retry flow | **GIF** |

## Error Handling

Visual evidence is **best-effort**. Never block the pipeline.

- Playwright install fails → log, skip evidence, proceed
- Dev server won't start → log, skip evidence, proceed
- Screenshot fails (404, timeout) → log, skip evidence, proceed
- Upload fails (EVIDENCE_* secret not configured, upload or verify error) → log, skip evidence, proceed
- **Hard timeout: 120 seconds** for the entire evidence phase. If exceeded, kill and proceed.

## Critical Rules

- **Never block the pipeline** — evidence is best-effort
- **120 second hard timeout** — kill and move on
- **Only embed URLs printed by evidence-upload** — it verifies each one returns HTTP 200
- **Public by URL** — never capture secrets, customer PII or production data
- Screenshots in `/tmp/` are ephemeral — they disappear when the environment stops
