# Assets — visual evidence & images

Pylot has a first-class **assets** backend: an org-fenced S3 bucket with presigned-URL upload/download and opt-in public "capability" URLs. Use it to attach **screenshots, GIFs, and recordings** to PRs, issues, and reports — and (soon) to conversations.

`$PYLOT_GATEWAY_URL` and `$PYLOT_API_TOKEN` are already in env. Allowed types: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `video/mp4`. Max 25 MB.

## In an operator/worker mission — LIVE

Use this to put a screenshot into a PR or issue body. The simplest path is the **`evidence-upload`** skill (dogfooded-skills), which wraps these calls. The raw flow:

```bash
# 1. presign — `repo` (org/name) sets the org fence and where it's filed
PRESIGN=$(curl -sS -X POST "$PYLOT_GATEWAY_URL/assets/presign" \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" -H "Content-Type: application/json" \
  -d "{\"repo\":\"$ORG/$REPO\",\"content_type\":\"image/png\",\"size\":$(wc -c < shot.png)}")
ASSET_ID=$(echo "$PRESIGN" | jq -r .asset_id)
UPLOAD_URL=$(echo "$PRESIGN" | jq -r .upload_url)

# 2. PUT the bytes straight to S3
curl -sS -X PUT "$UPLOAD_URL" --data-binary @shot.png -H "Content-Type: image/png"

# 3. publish → a stable, camo-safe public URL (GitHub's image proxy fetches anonymously)
PUBLIC_URL=$(curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"visibility":"public"}' | jq -r .public_url)

# 4. embed in the PR / issue / report body:
#    ![before](<PUBLIC_URL>)
# revoke later if needed:  PATCH /assets/<id> {"visibility":"org"}
```

Notes:
- The `public_url` (`$PYLOT_GATEWAY_URL/a/<token>`) is **stable** — it 302-redirects to a fresh presign on every fetch, so it never expires out of an issue. The token is unguessable and revocable; treat a published asset as readable by anyone with the link.
- For an org-internal view (not embedding), `GET /assets/<id>` returns a short-lived presigned URL instead.

## In a conversation — PENDING (Stage E)

Attaching an `image` block to the **current conversation message** (so a human sees it inline, or an agent reads it as a vision input) needs the chat-worker attach/multimodal helper, which is **Stage E of #1618 and not built yet**. Don't hand-roll it — it's coming with Stage E. Until then, use the operator/PR path above for evidence.

## See also
- `evidence-upload` skill (dogfooded-skills) — the ready-made wrapper for the upload flow.
- Endpoint reference: `pylot/docs/gateway.md` (assets endpoints) and `pylot/docs/assets.md` (architecture).
