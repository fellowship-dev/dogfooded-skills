# Prototype-variants mission brief

> Passed verbatim as the `--context` of the mission dispatched by stage 05b.
> It must stay self-contained: the receiving operator carries `prototype`, but **not**
> `issue-to-prd`, and today's only holder (`pylot.architect`) carries neither `visual-evidence`,
> `playwright`, nor `evidence-upload` — so every recipe it needs is inlined here.
> Placeholders `{org/repo}`, `{number}`, `{slug}` are substituted at dispatch time.

## Your job

Issue {org/repo}#{number} describes a UI surface nobody has decided the shape of yet. Build
**three materially different bootable takes** on it, screenshot them, and post them on the issue as
options the owner can pick from. Nothing you build will be merged. You are buying a decision, not
shipping a feature.

The reference artifact is [pylot PR #2063](https://github.com/fellowship-dev/pylot/pull/2063)
(2026-07-06): three variations of an add-LLM flow — single page, guided wizard, conversational — a
mock API, boot instructions, screenshots, and an explicit *"THROWAWAY — will not merge"* contract.
The owner replied *"Owner decision: variation B"* and B became the real implementation. Reproduce
that shape.

## Hard constraints

1. **No browser in this container.** The operator image (`Dockerfile.operator`) ships no chromium,
   no `libnss3`, no ffmpeg. Everything — build, boot, screenshot — runs on a **worker devbox**,
   driven through the `pylot-cli` § Workers API (spawn → prompt → poll-to-idle → stop). Do not try to
   install a browser here.
2. **Branches only. Do not open pull requests.** Three PRs would fire `review-pr-on-opened` three
   times, then `double-check`, then FlowChad, then CTO review — a full review pipeline spent on
   code that will be deleted. Push branches; the issue comment is the deliverable.
3. **Never merge, never touch the default branch**, and never delete a branch — the losing ones are
   listed for deletion in the PRD, and the owner or the implementing PR removes them.
4. **Uploads must be evidence-class.** `/a/<token>` capability URLs return `410 gone` after
   `PYLOT_PUBLIC_TOKEN_TTL_DAYS` (30) unless the asset carries an `evidence_class` (pylot #2622
   M7). See step 4 — it is *not* the default upload flow.
5. **Exactly one comment, at the very end**, whatever the outcome. Not one per variant, not one on
   start. See step 6. (A conversation this was dispatched from gets at most one Slack post as well
   — step 6b — never a substitute for the issue comment.)
6. **Three variants. Not two, not five.** Two reads as a binary the owner has already implicitly
   made; five is a survey, not a decision.

## Step 1 — name the surface and pick three theses

Read the issue and every comment. Write down, in one sentence each, three approaches that a person
would **answer differently**, not three arrangements of the same layout.

Good (from #2063): *single page — everything visible at once, expert-fast* · *guided wizard — one
decision per screen, no wrong turns* · *conversational — the app asks, you answer in prose*.

Bad: two-column vs one-column · modal vs drawer · tabs vs accordion. If your three sentences differ
only in where things sit, you have one variant with three stylesheets — go back and find the real
axis of disagreement.

Every variant must be **complete enough to judge**: it renders the same states, handles the same
inputs, and reaches the same end. A variant that only mocks the happy path while another handles
errors is not a fair comparison — you will have decided the outcome yourself.

## Step 2 — build, on the worker

Spawn a worker devbox for `{org/repo}` and drive it. For each variant `a`, `b`, `c`:

- Branch off the repo's default branch: `git checkout -b proto/{number}-a origin/<default>`
- One route, same path in all three: `/proto/{slug}` (for a Next.js app router repo,
  `<ui>/src/app/proto/{slug}/page.tsx`). Same route in every branch means the boot instructions
  differ by exactly one word.
- A banner at the top of the page, in every variant:
  `THROWAWAY PROTOTYPE — variant A — issue #{number} — will not be merged`.
- **Mock the data.** One clearly-named `mock-api.ts` next to the page, with a comment saying it is
  a prototype fixture. **No backend changes, no migrations, no new dependencies, no edits to any
  existing file** outside the new `proto/` directory. If a variant cannot be built without touching
  shared code, that is a finding — say so in the comment rather than reaching outside the fence.
- Commit once per branch. Conventional commit:
  `proto({slug}): variant A — <thesis> (refs #{number})`.

Get the dev command from the repo's playbook (`pylot teams playbook {org/repo}` → *How to Run
Tests* / *Frontend*), not from memory.

## Step 3 — boot and screenshot each variant (on the worker)

Install Playwright once on the worker, then shoot each branch in turn:

```bash
cd /tmp && npm install playwright >/dev/null 2>&1 && \
  npx playwright install-deps chromium >/dev/null 2>&1 && \
  npx playwright install chromium >/dev/null 2>&1 && echo PW_READY
```

```javascript
// /tmp/screenshot.mjs
import { chromium } from '/tmp/node_modules/playwright/index.mjs';
const [url, output] = process.argv.slice(2);
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
await page.screenshot({ path: output, fullPage: true });
await browser.close();
```

One PNG per variant, 1280×720, `fullPage`, of the surface's **primary state** — the screen that
carries the thesis. If a variant's argument only becomes visible in a second state (a wizard's step
3, an error), take that one too; cap the whole mission at **6 images**.

Sanity-check every file before uploading: non-zero size, and not a blank or error page. An app that
fails to compile produces a perfectly valid screenshot of a Next.js error overlay, and you will
have "proved" the wrong thing. Compare the three: if two are byte-identical, you built one variant
twice.

## Step 4 — upload as evidence-class

Run this per file. Deliberately raw `curl`: workers have the gateway env vars but no `pylot` CLI,
and the CLI's `assets presign` has no `--evidence-class` flag.

```bash
FILE=/tmp/variant-a.png; CONTENT_TYPE=image/png; REPO={org/repo}
BYTES=$(wc -c < "$FILE")

# 1. presign — evidence_class is what exempts the capability URL from the 30-day 410
PRESIGN=$(curl -sS -X POST "$PYLOT_GATEWAY_URL/assets/presign" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "{\"repo\":\"$REPO\",\"content_type\":\"$CONTENT_TYPE\",\"size\":$BYTES,\"evidence_class\":\"visual\"}")
ASSET_ID=$(echo "$PRESIGN" | python3 -c 'import sys,json; print(json.load(sys.stdin)["asset_id"])')
UPLOAD_URL=$(echo "$PRESIGN" | python3 -c 'import sys,json; print(json.load(sys.stdin)["upload_url"])')

# 2. PUT the bytes (presigned URL carries its own credentials — no auth header)
curl -sS -X PUT "$UPLOAD_URL" --data-binary @"$FILE" -H "Content-Type: $CONTENT_TYPE"

# 3. publish. `override_policy` is REQUIRED: every evidence class is publish-restricted until it
#    is listed in the gateway's EVIDENCE_PUBLISHABLE_CLASSES, which is currently unset. Without
#    it you get 403 publish_restricted_evidence_class. The override is audit-logged, which is the
#    correct trail for "the factory published a screenshot into a public issue".
PUBLIC_URL=$(curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d '{"visibility":"public","override_policy":true}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["public_url"])')

echo "$PUBLIC_URL"   # https://<gateway>/a/<token> — camo-safe, embed directly
```

Errors:

- `400` from presign → type/size outside the allowlist (PNG/JPEG/GIF/WEBP/MP4, 25 MB).
- `403` from presign → `$REPO` is not in your token's org.
- non-200 from PUT → the presigned URL expired (15 min); re-presign.
- `403 publish_restricted_evidence_class` → you dropped `override_policy`.

The screenshots outliving the mission is the point. Historical prototype evidence on PR #2063 is
already unreadable because it was published without an evidence class; do not repeat that.

## Step 4b — if somebody asked for this in a thread, deliver there too

Options nobody sees are not options. If this mission was dispatched **from a conversation**, the
owner who has to pick a variant is reading that thread — put the three variants in front of them
there, not only on the issue.

```bash
CONV=$(curl -sS "$PYLOT_GATEWAY_URL/missions/$PYLOT_JOB_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("dispatched_by_conv") or "")')
```

**Empty `CONV` → skip step 4b and the second half of step 6 entirely.** A label-triggered or
automation-dispatched run has no requester in a thread; posting anyway is spam.

When `CONV` is set, upload each variant's primary screenshot a **second** time with **no**
`evidence_class`, and publish it with `conversation_id`:

```bash
# presign exactly as in step 4 but WITHOUT the "evidence_class" field, PUT the same bytes, then:
CONV_URL=$(curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "{\"visibility\":\"public\",\"conversation_id\":\"$CONV\",\"alt\":\"variant A\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["public_url"])')
```

**Do not reuse the step-4 URL for this and do not add `evidence_class` here.** The two copies exist
because they need opposite things: the issue copy must be permanent (class → served
`Content-Disposition: attachment`), the thread copy must render (no class → served `inline`).
Measured on the prod gateway 2026-08-03. The gateway appends the image to the conversation, so it
renders inline in the web UI and the assistant can see it on the next turn.

Errors here are cosmetic: a failed conversation copy is reported in step 6 and **never** blocks the
issue comment, which is the real deliverable.

## Step 5 — push the branches

```bash
git push origin proto/{number}-a proto/{number}-b proto/{number}-c
```

Prototype code is not production code and will fail a repo's corpus/lint gate. If a pre-push hook
blocks the push, `--no-verify` is correct here and only here — say so in the comment. Never run a
pre-push hook from a git worktree (it corrupts `GIT_DIR`); push from the main checkout.

If a push is rejected for permissions, stop and report it in step 6. Do not retry with a different
token.

## Step 6 — one comment, then stop

Post **exactly one** comment on the issue. This is the deliverable:

````markdown
## Prototype variants — pick one

Three bootable takes on <the surface>. **Nothing here will be merged.** The one you pick becomes
the design basis for the PRD; the other two branches get deleted.

| | Variant | Thesis | Boot |
| --- | --- | --- | --- |
| ![variant A](<public_url_a>) | **A — <name>** | <one line> | `git fetch origin proto/{number}-a && git checkout proto/{number}-a`<br>`<dev command>` → <http://localhost:PORT/proto/{slug}> |
| ![variant B](<public_url_b>) | **B — <name>** | <one line> | …`proto/{number}-b`… |
| ![variant C](<public_url_c>) | **C — <name>** | <one line> | …`proto/{number}-c`… |

**How to choose:** reply on this issue with a single line — `variant: B`. That is all the next
`issue-to-prd` pass reads. You do not have to boot anything; the screenshots are there so you can
decide from the thread.

Mocked data only, no backend touched, `/proto/{slug}` route only. Built by the factory at
<ISO-8601> from `<base-sha>`.
<!-- pylot:prototype-options issue={number} job=proto-{number} variants=a,b,c base=<sha> -->
````

The trailing marker is load-bearing: it is how the next `issue-to-prd` pass knows the variants
exist, finds the pick, and does not dispatch a second run. Keep it byte-for-byte.

On failure — partial or total — post the one comment in this form instead, and **never** fake a
screenshot, embed a placeholder, or describe a variant you did not build:

```markdown
## Prototype variants — failed

Tried: <what you built and where you booted it>. Failed at: <the specific step and error>.
Branches pushed: <list, or none>. What would unblock it: <the concrete missing thing>.
<!-- pylot:prototype-options issue={number} job=proto-{number} variants=none status=failed -->
```

### Step 6b — and one Slack post, only if `CONV` was set in step 4b

One call, after the issue comment lands, never instead of it:

```bash
python3 - <<'PY' > /tmp/proto-slack.json
import json, os, sys
text = (f"Three prototype variants for #{os.environ['N']} are up — reply `variant: B` on the issue "
        f"to pick.\n\nA — {os.environ['THESIS_A']}\n{os.environ['CONV_URL_A']}\n\n"
        f"B — {os.environ['THESIS_B']}\n{os.environ['CONV_URL_B']}\n\n"
        f"C — {os.environ['THESIS_C']}\n{os.environ['CONV_URL_C']}\n\n"
        f"Boot instructions: {os.environ['ISSUE_URL']}")
json.dump({"text": text}, sys.stdout)
PY
curl -sS -X POST "$PYLOT_GATEWAY_URL/conversations/$CONV/slack-post" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  --data-binary @/tmp/proto-slack.json
```

**Each URL bare, on its own line.** The gateway rewrites outbound markdown to Slack mrkdwn:
`![alt](URL)` becomes `<URL|alt>` and `[![alt](URL)](URL)` becomes the malformed `<URL|<URL|alt>>`.
A bare URL passes through byte-identical, which is the only form Slack can unfurl into a picture.
Never paste the issue comment's markdown table into this call.

`{"ok":false,"reason":"no_slack_thread"}` means the conversation is web-only — **benign, do not
retry**; step 4b already attached the images to the web thread. Inline rendering in Slack depends
on Slack unfurling the URL and is best-effort: report that you posted, not that it rendered.

Stop the worker (`POST /missions/$PYLOT_JOB_ID/workers/<id>/stop`) before emitting the outcome
marker:

```text
[pylot] outcome="3 prototype variants posted on {org/repo}#{number}" status=success
```
