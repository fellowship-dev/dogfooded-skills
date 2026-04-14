---
name: visual-evidence
description: Capture Playwright screenshots and GIF recordings for PR evidence — before/after comparisons, feature demos, interaction bugs. Runs headless in any CI/remote environment.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# visual-evidence

Capture browser screenshots and GIF recordings using Playwright headless Chromium. Upload to cloud storage for embedding in PRs and reports.

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

### 3. Upload to Cloud Storage

Upload screenshots and GIFs to your configured storage. Example with S3:

```bash
aws s3 cp /tmp/evidence-<label>.png \
  s3://<bucket>/assets/evidence/<repo>/<branch>/<label>.png \
  --acl public-read --region <region>
```

For GIFs, add `--content-type image/gif`.

Verify upload:
```bash
curl -s -o /dev/null -w '%{http_code}' "$IMAGE_URL"
```

### 4. PR Embedding

**Before/After (bug fixes):**
```markdown
## Visual Evidence

<details>
<summary>Before / After</summary>

**Before (bug present on default branch):**
![before](<url>/before.png)

**After (fix applied):**
![after](<url>/after.png)

</details>
```

**Interaction demo (GIF):**
```markdown
## Visual Evidence

<details>
<summary>Interaction demo</summary>

![demo](<url>/demo.gif)
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
- Upload fails (no creds, permission denied) → log, skip evidence, proceed
- **Hard timeout: 120 seconds** for the entire evidence phase. If exceeded, kill and proceed.

## Critical Rules

- **Never block the pipeline** — evidence is best-effort
- **120 second hard timeout** — kill and move on
- **Always verify upload** before embedding URLs in PRs
- Screenshots in `/tmp/` are ephemeral — they disappear when the environment stops
