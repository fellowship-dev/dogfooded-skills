# Dispatch

Send coding tasks to crew members via `POST /dispatch`.

## Format

```bash
CONV_ID=$(ls /tmp/claude-home/.claude/session-env/ | head -1)

curl -sS -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"agent\": \"<team>.<operator>\",
    \"task\": \"<what to do>\",
    \"repo\": \"<org/repo>\",
    \"context\": {\"conversation_id\": \"$CONV_ID\"}
  }" \
  "$PYLOT_GATEWAY_URL/dispatch"
```

**Required**: `agent` (team.operator format), `task`
**Optional**: `repo`, `context`, `priority`, `model`, `local` (boolean — skip Fargate, use for gateway restarts and host-level ops)

When `context.conversation_id` is set, the gateway creates a `mission_conversations` link and auto-wakes this conversation when the mission reaches a terminal state. Without it, auto-wake silently no-ops.

## Prompt Limits

Keep task prompts under ~4 KB. Fargate container overrides have an **8192-byte hard limit** — prompts exceeding this are silently truncated. The operator logs `"Prompt too long for container overrides. Writing a concise version."` when this happens.

**Best practice**: put the full spec in a GitHub issue comment. Workers read the issue thread during orientation. Dispatch with a short task:

```
"Implement issue #NNN. See the issue comments for the full spec. Use /visual-evidence."
```

## Teams & Operators

| Team | Key Repos | Operators | Focus |
|------|-----------|-----------|-------|
| **infra** | fellowship-dev/pylot | ops, cto, intern, dev | Gateway, Docker builds, deploys, health |
| **lexgo** | Lexgo-cl/rails-backend, lexgo-infra | cto, dev | PR reviews, speckit, deps, releases |
| **booster-pack** | 13 sites + Lexgo website | cto, qa, designer, dev | Heartbeat loop, smoke tests, design QA |
| **tooling** | dogfooded-skills, flowchad, quest, spec-kit | cto, dev | Skills, distill, entropy sweeps |
| **mtg-lotr** | fellowship-dev/mtg-lotr | cto, dev | PR reviews |
| **fry** | claude-buddy, fvl-internal | scout, lead | News, standups (disabled) |
| **inbox-angel** | inbox-angel, inbox-angel-worker | cto, marketing, scout, dev | (disabled) |
| **navvi** | navvi, navvi-benchmark | cto, dev | (disabled) |
| **clapes** | CLAPES-UC/* | cto, dev | (disabled) |

## Examples

```bash
CONV_ID=$(ls /tmp/claude-home/.claude/session-env/ | head -1)

# Deploy Pylot UI to Vercel
curl -sS -X POST -H "Authorization: Bearer $PYLOT_API_TOKEN" -H "Content-Type: application/json" \
  -d "{\"agent\":\"infra.cto\",\"task\":\"Deploy Pylot UI to Vercel using /vercel-deploy\",\"repo\":\"fellowship-dev/pylot\",\"context\":{\"conversation_id\":\"$CONV_ID\"}}" \
  "$PYLOT_GATEWAY_URL/dispatch"

# Implement an issue (short prompt, spec in issue comment)
curl -sS -X POST -H "Authorization: Bearer $PYLOT_API_TOKEN" -H "Content-Type: application/json" \
  -d "{\"agent\":\"infra.cto\",\"task\":\"Implement issue #555. See issue comments for spec. Use /visual-evidence.\",\"repo\":\"fellowship-dev/pylot\",\"context\":{\"conversation_id\":\"$CONV_ID\"}}" \
  "$PYLOT_GATEWAY_URL/dispatch"
```

## Visual Evidence Checklist

Before dispatching UI tasks:
- `AWS_BUCKET` must be in the infra team secrets (same var name across repos)
- Task prompt needs only `"use /visual-evidence"` — the skill handles upload and PR embed
- Recording instructions go in the issue comment, not the task
- After mission completes, verify GIF/screenshot landed in the PR body
