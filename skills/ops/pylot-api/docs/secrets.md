# Secrets & Credential Discovery

## Discover Available Keychains

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/admin/secrets" | jq '.asm_paths[] | {path, keys}'
```

Returns entries like:
```json
{"path": "infra", "keys": [{"key": "GH_TOKEN", "description": "Fellowship org PAT — repo + workflow scope"}]}
```

## Find the Right Keychain for GH_TOKEN

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/admin/secrets" \
  | jq '.asm_paths[] | select(.keys[]?.key == "GH_TOKEN")'
```

Only `pylot/infra` and `pylot/infra/fellowship-dev/pylot` currently have populated `keys[]` with descriptions. Other team-level keychains are opaque — discovery may not resolve them automatically.

## Add Secrets to a Project

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key": "MY_KEY", "value": "...", "description": "What this key is for"}' \
  "$PYLOT_GATEWAY_URL/admin/secrets/<project>"
```

Always include a `description` — visible in `GET /admin/secrets` output. If unknown, use `"TODO: add description"` as a placeholder rather than omitting it.

## Load After Discovery

Once you have the ref, load it as a conversation resource — see [Resources](resources.md).
