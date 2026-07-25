# Conversation Resources

Load resources (keychains, skills) into a conversation — secrets inject as env vars, skills sync into workspace on the next turn.

## Derive Conversation ID

```bash
CONV_ID=$(ls /tmp/claude-home/.claude/session-env/ | head -1)
```

## Load a Keychain

**Always discover before loading** — see [Secrets](secrets.md) for the discovery pattern.

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "secret", "ref": "pylot/infra", "config": {}}' \
  "$PYLOT_GATEWAY_URL/conversations/$CONV_ID/resources"
```

**Type semantics**:
- `type: secret` + `ref: pylot/<path>` — load an ASM keychain by its exact path. **Canonical pattern.** Response `env` field contains resolved secrets for immediate use; also injected on subsequent turns.
- `type: team` — resolves a team bundle by declared keys; may not inject all secrets reliably. Prefer `type: secret`.

**Ref format**: `pylot/<scope>` — validated against ASM keychains at load time (404 if not found).

## Load a Skill

Skills load on the *next* turn. Self-wake bridges this gap:

```bash
# 1. Load the skill
curl -sS -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "skill", "ref": "vercel-deploy"}' \
  "$PYLOT_GATEWAY_URL/conversations/$CONV_ID/resources"

# 2. Immediately schedule wake — skill will be in workspace on that turn
curl -sS -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"in_seconds": 60, "content": "Run /vercel-deploy"}' \
  "$PYLOT_GATEWAY_URL/conversations/$CONV_ID/wakes"
```

## List & Unload

```bash
# List loaded resources
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/conversations/$CONV_ID/resources"

# Unload by ID
curl -sS -X DELETE \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/conversations/$CONV_ID/resources/<resourceId>"
```
