---
name: evidence-upload
description: Upload an image/GIF/video to the pylot assets backend and return a stable public URL. Use whenever you need to embed visual evidence in a PR, issue, or report.
user-invocable: false
allowed-tools: Bash
---

# evidence-upload

Upload a local file to the pylot assets backend (org-fenced S3) and get a stable, camo-safe public URL. `$PYLOT_GATEWAY_URL` and `$PYLOT_DISPATCH_TOKEN` are already in every operator/worker env — no static AWS keys needed.

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

BYTES=$(wc -c < "$FILE")

# 1. Presign — returns asset_id + a short-lived S3 upload URL
PRESIGN=$(curl -sS -X POST "$PYLOT_GATEWAY_URL/assets/presign" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"repo\":\"$REPO\",\"content_type\":\"$CONTENT_TYPE\",\"size\":$BYTES}")
ASSET_ID=$(echo "$PRESIGN" | python3 -c "import sys,json; print(json.load(sys.stdin)['asset_id'])")
UPLOAD_URL=$(echo "$PRESIGN" | python3 -c "import sys,json; print(json.load(sys.stdin)['upload_url'])")

# 2. Direct PUT to S3 (no auth header — the presigned URL carries credentials)
curl -sS -X PUT "$UPLOAD_URL" \
  --data-binary @"$FILE" \
  -H "Content-Type: $CONTENT_TYPE"

# 3. Publish → stable public URL (camo-proxied, safe to embed in GitHub)
PUBLIC_URL=$(curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"visibility":"public"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['public_url'])")

# 4. Embed in PR / issue / report body:
echo "![evidence]($PUBLIC_URL)"

# Optional — revoke public access when no longer needed:
# curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$ASSET_ID" \
#   -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
#   -H "Content-Type: application/json" \
#   -d '{"visibility":"org"}'
```

## Error handling

- **400 from presign** → file type or size outside allowlist. Convert or compress before retrying.
- **403 from presign** → token doesn't have access to this repo's org. Check `$REPO` matches the org the token belongs to.
- **Non-200 from PUT** → S3 presigned URL expired (valid 15 min). Re-run presign and try again.
- **Non-200 from publish** → retry once; if it persists, skip evidence (never block the PR on upload failure).

## When to skip

Skip evidence upload (and note "N/A" in the PR body) if:
- The change is backend-only, CLI-only, config/infra, or test-only with no visible output.
- Capture would take more than 120 s.
- The file exceeds 25 MB after compression.

Evidence is a bonus, never a gate.
