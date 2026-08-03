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
| Chat/Slack conversation (`--conversation`) | *(omit)* | 30 days | inline |

**Rule: anything embedded in a PR, issue, or verdict comment MUST pass
`--evidence-class visual`.** A receipt that expires in 30 days is not evidence —
[fellowship-dev/pylot#2063](https://github.com/fellowship-dev/pylot/pull/2063)'s
screenshots are already unreadable for exactly this reason.

Conversely, **do not** pass `--evidence-class` on the `--conversation` path: an
evidence-classed image is served as an attachment by `GET /assets/:id` too, so it
would stop rendering inline in the thread — which is the whole point of that path.

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
