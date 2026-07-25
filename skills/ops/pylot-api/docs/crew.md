# Crew & Stats

## Full Crew Roster

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/crew"
```

Returns teams, operators, cron schedules, budgets, and merge strategies.

## Mission & Cost Metrics

```bash
# Aggregated mission + cost metrics
curl -sS "$PYLOT_GATEWAY_URL/stats"

# Per-team spend rollup
curl -sS "$PYLOT_GATEWAY_URL/costs/summary"
```

## Update Team Config

```bash
curl -sS -X PATCH \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"worker_images": {...}}' \
  "$PYLOT_GATEWAY_URL/admin/crew/<team>"
```

Note: `PATCH /admin/crew/:team` replaces `worker_images` entirely.

## Skills Catalog

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/admin/skills"
```
