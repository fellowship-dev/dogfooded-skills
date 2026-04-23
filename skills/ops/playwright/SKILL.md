---
name: playwright
description: Browser automation using Playwright CLI over CDP. Navigate, screenshot, fill forms, extract data, test web apps. Activates on "browser", "screenshot", "navigate to", "playwright", "web automation", "UI testing". Uses playwright-core ESM + Chromium CDP — no MCP required.
allowed-tools: Bash, Read, Write, Glob, Grep
---

# Playwright Web Automation

Browser automation via Chromium + playwright-core over CDP. No MCP server needed — scripts run as `.mjs` files.

## Prerequisites

```bash
# Install playwright-core (no browser download — uses existing Chromium)
npm install playwright-core

# Verify Chromium exists
which chromium || ls /Applications/Chromium.app/Contents/MacOS/Chromium
```

## Launch Chromium with CDP

```bash
# Kill any existing debug instance
pkill -f "remote-debugging-port=9222" 2>/dev/null

# Launch headless (cron/CI) or headed (interactive)
chromium --remote-debugging-port=9222 \
  --user-data-dir="/tmp/playwright-profile" \
  --disable-blink-features=AutomationControlled \
  --no-first-run --no-default-browser-check \
  --headless=new \
  "about:blank" > /tmp/chromium.log 2>&1 &

# macOS: use full path /Applications/Chromium.app/Contents/MacOS/Chromium
# Linux: chromium-browser or chromium

# Wait for CDP
sleep 3 && curl -sf http://localhost:9222/json/version > /dev/null && echo "CDP ready"
```

## Connect via Playwright (ESM)

Write scripts as `.mjs` files:

```javascript
// run: node script.mjs
import { chromium } from 'playwright-core';

const browser = await chromium.connectOverCDP('http://localhost:9222');
const ctx = browser.contexts()[0];
const page = ctx.pages()[0] || await ctx.newPage();

await page.goto('https://example.com', { waitUntil: 'domcontentloaded', timeout: 15000 });
await page.waitForTimeout(2000);
await page.screenshot({ path: '/tmp/screenshot.png' });

await browser.close(); // disconnects, doesn't kill Chromium
```

**IMPORTANT:** Always use `.mjs` extension — playwright-core is ESM-only.

## Key Patterns

### Screenshot & Inspect
```javascript
await page.screenshot({ path: '/tmp/screen.png' });
// Read /tmp/screen.png in Claude to see it visually
```

### Fill Forms & Click
```javascript
// Inspect inputs first
const inputs = await page.evaluate(() =>
  Array.from(document.querySelectorAll('input')).map(i => ({
    name: i.name, type: i.type, placeholder: i.placeholder
  }))
);
console.log(JSON.stringify(inputs, null, 2));

await page.fill('input[name="email"]', 'user@example.com');
await page.click('button:has-text("Submit")');
await page.waitForTimeout(2000);
```

### Extract Page Content
```javascript
const text = await page.evaluate(() => document.body.innerText);
const html = await page.content();
const title = await page.title();
```

### Wait for Navigation
```javascript
await Promise.all([
  page.waitForNavigation({ waitUntil: 'networkidle' }),
  page.click('button:has-text("Login")')
]);
```

### SPA / Client-Side Rendered Data
SPAs may not hydrate fully in headless. Use data endpoints if available:
```javascript
const data = await page.evaluate(async () => {
  const res = await fetch('/api/data', { credentials: 'include' });
  return res.json();
});
```

### Multi-Page Flow
```javascript
await page.goto('https://app.example.com/login');
await page.fill('#email', 'user@example.com');
await page.fill('#password', 'password');
await page.click('button[type="submit"]');
await page.waitForNavigation({ waitUntil: 'networkidle' });
await page.screenshot({ path: '/tmp/after-login.png' });

// Continue to next page
await page.click('a:has-text("Dashboard")');
await page.waitForLoadState('networkidle');
await page.screenshot({ path: '/tmp/dashboard.png' });
```

### Record Video
```javascript
// Must create a NEW context for video recording
const ctx = await browser.newContext({
  recordVideo: { dir: '/tmp/videos/', size: { width: 1280, height: 720 } }
});
const page = await ctx.newPage();
await page.goto('https://example.com');
// ... do things ...
await ctx.close(); // video saved to /tmp/videos/*.webm
```

### Console & Network Monitoring
```javascript
page.on('console', msg => console.log(`[${msg.type()}] ${msg.text()}`));
page.on('response', res => {
  if (res.status() >= 400) console.log(`[${res.status()}] ${res.url()}`);
});
```

## Selectors (prefer in this order)

1. `data-testid="foo"` — `page.click('[data-testid="foo"]')`
2. Role — `page.getByRole('button', { name: 'Submit' })`
3. Text — `page.click('button:has-text("Submit")')`
4. CSS — `page.click('.submit-btn')` (fragile, last resort)

## Cleanup

```bash
pkill -f "remote-debugging-port=9222"
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| CDP not responding | Wait longer, check `curl http://localhost:9222/json/version` |
| Port 9222 in use | `pkill -f "remote-debugging-port=9222"` then relaunch |
| ESM import error | Use `.mjs` extension, not `.js` |
| Page not loading | Increase timeout, use `waitUntil: 'domcontentloaded'` |
| Screenshots blank | Add `page.waitForTimeout(2000)` before capture |
| CSS not loaded | Use `waitUntil: 'networkidle'` or wait for a visible element |
| Form submit fails | Check if element is visible: `await el.isVisible()` |
