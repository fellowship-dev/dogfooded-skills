# Monitoring Missions

```bash
# List recent missions
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/missions?limit=10" | jq '.[] | {job_id, status, agent, task}'

# Single mission detail
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/missions/<job_id>" | jq '{status, agent, task, outcome}'

# Stream logs from CloudWatch (works for running and completed missions)
curl -sS -N -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/missions/<job_id>/logs/stream" --max-time 30

# Filter by status
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/missions?status=running"

# Filter by team
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/missions?crew=infra&limit=5"

# Detailed execution trace (session JSONL)
curl -sS "$PYLOT_GATEWAY_URL/missions/<job_id>/session"
```

Terminal statuses: `done`, `failed`, `cancelled`, `timeout`

## Gateway Logs (CloudWatch)

Debug event rules, dispatches, auto-wake, cost reports, and other gateway behavior by querying Lambda CloudWatch logs directly.

```bash
# Query API Lambda logs (dispatches, cost reports, auto-wake)
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/admin/logs/api?minutes=15&grep=auto-wake" | jq '.entries[:5]'

# Query ingress logs (webhook intake, HMAC validation)
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/admin/logs/ingress?minutes=10"

# Query executor logs (mission lifecycle, Fargate spawn)
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/admin/logs/executor?minutes=30&grep=spawn"
```

**Sources**: `api`, `ingress`, `processor`, `executor`, `notifier`, `scheduler`, `chat`

**Params**: `minutes` (default 30, max 180), `grep` (CloudWatch filter pattern), `limit` (default 200, max 1000)

**Chat tool**: `get_gateway_logs` — same endpoint, available as a conversation tool.

**Common grep patterns**:
- `auto-wake` — wake scheduling on mission completion
- `event-router` — event rule matching and dispatch
- `dispatch` — mission dispatch intake
- `cost` — cost report processing
- `onMissionTerminal` — terminal state hooks

## Kill / Cancel

```bash
# Kill a running mission
curl -sS -X DELETE -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/missions/<job_id>"

# Cancel a pending mission
curl -sS -X DELETE -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/missions/pending/<job_id>"
```
