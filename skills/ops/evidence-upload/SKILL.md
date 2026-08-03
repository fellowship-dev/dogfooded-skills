---
name: evidence-upload
description: Upload an image/GIF/video to the pylot assets backend and return a stable public URL, optionally attaching it to a chat conversation. Use whenever you need to embed visual evidence in a PR, issue, or report, or to make an image appear in a conversation thread.
argument-hint: "[--evidence-class <class>] [--conversation <conversation-id>] [--alt <text>]"
user-invocable: true
allowed-tools: Bash
---

# evidence-upload

Upload a local file to the pylot assets backend (org-fenced S3) and get a stable, camo-safe public URL. `$PYLOT_GATEWAY_URL` and `$PYLOT_DISPATCH_TOKEN` are already in every operator/worker env — no static AWS keys needed.

Optionally, pass `--conversation <conversation-id>` (and `--alt "<text>"`) to also attach the published asset to a chat conversation — it renders inline in the thread and Claude sees it on the conversation's next turn. See [Attaching to a conversation](#attaching-to-a-conversation---conversation) below; without the flag, the flow is exactly the 4 steps that follow.

## Pick the retention mode FIRST — `--evidence-class`

The default upload produces a capability URL that **410s after 30 days**
(`PYLOT_PUBLIC_TOKEN_TTL_DAYS`, #2622 M7). That is fine for a chat message and
fatal for anything written into a permanent record.

| Destination | Flag | URL lifetime | Rendering |
|---|---|---|---|
| **PR body, issue body, review/verdict comment, report** | `--evidence-class visual` | **permanent** | served `Content-Disposition: attachment` (see caveat) |
| Chat/Slack conversation (`--conversation`) | *(omit)* | 30 days | `Content-Disposition: inline` |

**Rule: anything embedded in a PR, issue, or verdict comment MUST pass
`--evidence-class visual`.** A receipt that expires in 30 days is not evidence —
[fellowship-dev/pylot#2063](https://github.com/fellowship-dev/pylot/pull/2063)'s
screenshots are already unreadable for exactly this reason.

Conversely, **do not** pass `--evidence-class` on the `--conversation` path: an
evidence-classed image is served as an attachment by `GET /assets/:id` too, so it
would stop rendering inline in the thread — which is the whole point of that path.

Measured on the prod gateway, 2026-08-03, asset `06050daf-…` (unpublished after) —
unauthenticated `GET /a/<token>` on an **unclassed** PNG:

```
HTTP/2 302  → location: …&response-content-disposition=inline&response-content-type=image%2Fpng
HTTP/1.1 200  Content-Type: image/png  Content-Disposition: inline
```

Same request on an evidence-classed PNG returns `Content-Disposition: attachment`
(child 6's measurement, asset `919c7786-…`). That single header is the whole fork:
it decides whether a renderer — the chat UI, or Slack's link unfurler — shows a
picture or offers a download.

**One image with two destinations is two uploads.** A screenshot that belongs in a
PR body *and* in the requesting thread cannot be one asset today: the PR copy needs
the class (permanence) and the thread copy needs the absence of it (inline). Upload
the file twice — same bytes, two asset ids — rather than trading one requirement for
the other. This collapses to a single classed upload the moment
[fellowship-dev/pylot#2834](https://github.com/fellowship-dev/pylot/issues/2834)
child 14 makes disposition MIME-driven; when it lands, delete the second upload and
reuse the classed `public_url` in both places.

### What the flag changes

Two request fields, verified live against the prod gateway (2026-08-03, asset
`919c7786-…`, unpublished after):

- **Step 1** gains `"evidence_class": "visual"`. `image/*` is a *media* MIME type,
  not an *evidence* MIME type, so `VALID_EVIDENCE_CLASSES` is not enforced against
  it — `"visual"` is accepted and stored with no schema or gateway change
  (`assets-api.mts` presign: `isEvidence = ALLOWED_EVIDENCE_TYPES.has(ct)` → false
  for PNG). At `/a/:public_token` the check is `Boolean(row.evidence_class) || …`,
  so the row is now evidence and **exempt from the 30-day 410**.
- **Step 3** gains `"override_policy": true`. `EVIDENCE_PUBLISHABLE_CLASSES` is
  unset in prod, so publishing *any* evidence-classed asset without it returns
  **403 `publish_restricted_evidence_class`**. The override is audit-logged, which
  is the right trail anyway.

> **Caveat — attachment disposition.** The same `isEvidence` flag that grants
> permanence also forces `response-content-disposition=attachment` on the S3
> redirect. Measured: `HTTP/1.1 200 / Content-Type: image/png /
> Content-Disposition: attachment`. Embed the URL as **both** an image and a
> plain link (`[![alt](URL)](URL)`) so the receipt survives whether or not the
> renderer honours the disposition. Making disposition MIME-driven instead of
> evidence-driven is tracked as the gateway-side fix in
> [fellowship-dev/pylot#2834](https://github.com/fellowship-dev/pylot/issues/2834)
> (child 14); when it lands, drop the double-link form.
>
> Note also that a *revoked* (`visibility: "org"`) asset returns **404**, not 410 —
> 404 means unpublished/never-published, 410 means TTL-expired. Do not read a 404
> as evidence of expiry.

The `pylot assets presign|publish` CLI subcommands expose **neither** field, so the
evidence-class flow must use raw `curl` as written below.

## Allowlist

| Type | MIME types | Max size |
|------|-----------|----------|
| Images | `image/png`, `image/jpeg`, `image/gif`, `image/webp` | 25 MB |
| Video | `video/mp4` | 25 MB |

Anything outside this list will get a 400 from `/assets/presign`. Capture screenshots as PNG; convert large GIFs to MP4 if they exceed 25 MB.

## The 4-step flow

```bash
# Variables you must set before running:
# FILE=/path/to/screenshot.png
# CONTENT_TYPE=image/png          # must match allowlist
# REPO=org/repo-name              # scopes the org fence
# EVIDENCE_CLASS=visual           # from --evidence-class; EMPTY for the conversation path

BYTES=$(wc -c < "$FILE")

# 1. Presign — returns asset_id + a short-lived S3 upload URL
PRESIGN_BODY=$(REPO="$REPO" CONTENT_TYPE="$CONTENT_TYPE" BYTES="$BYTES" \
  EVIDENCE_CLASS="${EVIDENCE_CLASS:-}" python3 -c "
import json, os
b = {'repo': os.environ['REPO'],
     'content_type': os.environ['CONTENT_TYPE'],
     'size': int(os.environ['BYTES'])}
if os.environ.get('EVIDENCE_CLASS'):
    b['evidence_class'] = os.environ['EVIDENCE_CLASS']
print(json.dumps(b))")
PRESIGN=$(curl -sS -X POST "$PYLOT_GATEWAY_URL/assets/presign" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PRESIGN_BODY")
ASSET_ID=$(echo "$PRESIGN" | python3 -c "import sys,json; print(json.load(sys.stdin)['asset_id'])")
UPLOAD_URL=$(echo "$PRESIGN" | python3 -c "import sys,json; print(json.load(sys.stdin)['upload_url'])")

# 2. Direct PUT to S3 (no auth header — the presigned URL carries credentials)
curl -sS -X PUT "$UPLOAD_URL" \
  --data-binary @"$FILE" \
  -H "Content-Type: $CONTENT_TYPE"

# 3. Publish → stable public URL (camo-proxied, safe to embed in GitHub).
#    override_policy is REQUIRED whenever evidence_class is set, else 403.
PUBLISH_BODY=$(EVIDENCE_CLASS="${EVIDENCE_CLASS:-}" python3 -c "
import json, os
b = {'visibility': 'public'}
if os.environ.get('EVIDENCE_CLASS'):
    b['override_policy'] = True
print(json.dumps(b))")
PUBLIC_URL=$(curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PUBLISH_BODY" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['public_url'])")

# 4. Embed in PR / issue / report body. Image + link, per the attachment caveat:
echo "[![evidence]($PUBLIC_URL)]($PUBLIC_URL)"

# Optional — revoke public access when no longer needed:
# curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
#   -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
#   -H "Content-Type: application/json" \
#   -d '{"visibility":"org"}'
```

## Attaching to a conversation (`--conversation`)

**Requires a gateway with [fellowship-dev/pylot#1950](https://github.com/fellowship-dev/pylot/pull/1950) deployed** — older gateways 400 on the extra fields (see error handling for the fallback). The plain 4-step flow above is unaffected either way.

When invoked with `--conversation <conversation-id>` (and optionally `--alt "<text>"`), run steps 1–2 as above, then **replace step 3** with:

```bash
# Extra variables from the invocation args:
# CONVERSATION_ID=<conversation-id>   # from --conversation
# ALT="short image description"       # from --alt (optional; omitted → server stores null)

BODY=$(CONVERSATION_ID="$CONVERSATION_ID" ALT="${ALT:-}" python3 -c "
import json, os
b = {'visibility': 'public', 'conversation_id': os.environ['CONVERSATION_ID']}
if os.environ.get('ALT'):
    b['alt'] = os.environ['ALT']
print(json.dumps(b))")

RESPONSE=$(curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY")
PUBLIC_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['public_url'])")
MESSAGE_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conversation_message_id',''))")
ATTACHED=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('attached',''))")
```

The gateway idempotently appends a `{"type":"image","asset_id","alt","mime_type"}` user-message block to the conversation — it renders inline in the chat UI, and Claude sees the image on the conversation's next turn. No assistant turn is triggered by the append.

**Report both attach fields alongside the URL**, e.g. `attached to conversation <id> — message <MESSAGE_ID> (attached: <ATTACHED>)`:

- `conversation_message_id` — id of the appended (or pre-existing) conversation message
- `attached` — `True` on a fresh append; `False` means the asset was already attached to this conversation (idempotent re-publish — not an error, don't retry)

## Reaching the requesting owner (`--conversation` + the Slack thread)

When your mission was **requested from a conversation**, the owner is reading that
thread — not the PR. Put the picture where they are. This is
[fellowship-dev/pylot#2542](https://github.com/fellowship-dev/pylot/issues/2542)
Phase 3's delivery half; it never replaces the PR/issue copy, it is in addition to it.

### 1. Find the conversation — do not guess

```bash
CONV=$(curl -sS "$PYLOT_GATEWAY_URL/missions/$PYLOT_JOB_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("dispatched_by_conv") or "")')
```

`dispatched_by_conv` is the canonical field and the **only** one an operator can read:
`mission_conversations` (the back-traced linkage for rule-triggered missions) has no
HTTP read route. Some dispatchers also echo the same id at
`context.context.conversation_id`; treat that as a fallback, not the source of truth.

**Empty `CONV` is the normal case and means STOP.** Cron- and automation-dispatched
missions have no requester in a thread — there is nobody to deliver to, and posting
anyway is spam. The whole hop below is conditional on a non-empty `CONV`.

(`PYLOT_CONVERSATION_ID` is a *different* thing: it is set only for
conversation-owned drive workers, never for mission operators. Do not look for it.)

### 2. Attach the unclassed copy — the guaranteed half

Upload the file again **without** `--evidence-class` and publish it with
`conversation_id` (the `--conversation` flow above). The gateway appends a
`{"type":"image","asset_id",…}` user block to the conversation, which:

- renders inline in the web UI exactly like a human composer upload, and
- is resolved to base64 for Claude on the conversation's next turn (#1931), so the
  assistant can actually *see* what the factory produced.

Both of those are guaranteed by code paths that exist today. No assistant turn is
triggered by the append.

### 3. Post it into the Slack thread — the best-effort half

The conversation append is a pure DB write: **nothing mirrors it into Slack.** Every
outbound Slack message in the gateway goes through `chat.postMessage`, and there is
no `files.upload` call anywhere (the bot's OAuth scopes do not include `files:write`)
and no Block Kit `image` builder. The only inline rendering available today is
**Slack's own link unfurl** of the capability URL — which is exactly why this copy
must be unclassed (`inline`, not `attachment`).

Post the URL through the existing `slack-post` route:

```bash
curl -sS -X POST "$PYLOT_GATEWAY_URL/conversations/$CONV/slack-post" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json,os
print(json.dumps({'text': 'Empty state after the fix:\n\n' + os.environ['PUBLIC_URL']}))")"
```

**Put the bare URL on a line of its own. Never use markdown image syntax here.**
The gateway runs every outbound message through `gfmToMrkdwn`, measured:

| You write | Slack receives |
|---|---|
| `<URL>` bare, own line | `<URL>` — byte-identical, unfurlable ✅ |
| `![alt](URL)` | `<URL\|alt>` — image syntax destroyed, labeled link |
| `[![alt](URL)](URL)` | `<URL\|<URL\|alt>>` — **nested, malformed mrkdwn** |

That last row matters: `[![alt](URL)](URL)` is the correct form for a *PR comment*
(it survives the attachment disposition). Copying a PR/verdict body straight into
`slack-post` produces broken output. Render the Slack message separately.

Responses (from the `slack-post` skill): `{"ok":false,"reason":"no_slack_thread"}`
means the conversation is web-only — **benign, expected, do not retry**. The step 2
attach already delivered to the web UI; that is the whole job for a web-only owner.

**Budget: one post, at most one or two images.** `slack-post` is for inflection
points, not narration. If you produced eight screenshots, post the one that carries
the finding and link the PR/issue for the rest.

### What is and is not guaranteed

| | Status |
|---|---|
| Image inline in the web UI thread | **guaranteed** (#1881 append + existing renderer) |
| Claude sees the image next turn | **guaranteed** (#1931 `enrichHistoryImages`) |
| Image inline in the Slack thread | **best-effort** — depends on Slack unfurling the URL; not verified end-to-end |
| Image as a native Slack file/Block Kit image | **not available** — needs a gateway change + `files:write` scope; tracked on pylot#2550 |

Say which one you got. "Posted to the thread" when the unfurl did not fire is the
same lie as a swallowed upload error.

> Known edge: a capability token containing **two** `__` sequences is mangled by the
> mrkdwn bold rule (`…/a/AA__BB__CC` → `…/a/AA*BB*CC`). Rare, but if a Slack URL
> comes back dead while the same asset works elsewhere, this is why — re-presign to
> get a different token.

## Error handling

- **400 from presign** → file type or size outside allowlist. Convert or compress before retrying.
- **403 from presign** → token doesn't have access to this repo's org. Check `$REPO` matches the org the token belongs to.
- **Non-200 from PUT** → S3 presigned URL expired (valid 15 min). Re-run presign and try again.
- **403 `publish_restricted_evidence_class` from publish** → you set `evidence_class` but omitted `override_policy: true`. Add it; do not silently drop the class to get a 200, that trades permanence for a green step.
- **Non-200 from publish** → retry once; if it persists, skip evidence (never block the PR on upload failure). **Report the failure explicitly** — a swallowed upload error reads as "no screenshots were needed", which is how a missing receipt becomes invisible.

Attach-specific (only when `--conversation` was given — check the response `error` code):

- **400 from publish with `conversation_id`** → the target gateway predates pylot#1950. Re-run step 3 in its plain form (`{"visibility":"public"}`) so the public URL is still produced, and report that conversation attach is unsupported on this gateway.
- **404 `conversation_not_found`** → no such conversation on this gateway. Check the id for typos and that `$PYLOT_GATEWAY_URL` points at the environment the conversation lives in (staging vs prod). Fall back to plain publish so the URL isn't lost.
- **403 `conversation_org_mismatch`** → the conversation belongs to a different org than the asset. The `$REPO` used in step 1 must be in the same org as the conversation — re-run the flow from step 1 with the right repo.
- **409 `asset_not_uploaded`** → the S3 PUT (step 2) never completed, so there is nothing to attach. Re-run step 2, then retry the attach publish.

A failed attach must never lose the evidence: always finish with a successful publish (plain if necessary) and report the `public_url`.

## When to skip

Skip evidence upload (and note "N/A" in the PR body) if:
- The change is backend-only, CLI-only, config/infra, or test-only with no visible output.
- Capture would take more than 120 s.
- The file exceeds 25 MB after compression.

Evidence is a bonus, never a gate.
