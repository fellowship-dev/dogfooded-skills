# Stage 05c: Outcomes Baseline

## Purpose
Fetch real outcome metrics to anchor the PRD's Measurable Impact section in actual data.
This stage is **fail-open**: any error (API unavailable, network, 4xx/5xx, empty response)
yields placeholder values — PRD generation never blocks or throws on outcomes unavailability.

## Inputs
- `{org}` — the GitHub org owning the issue repo (from stage 01 handoff or the repo argument)
- `$PYLOT_API` — gateway base URL (env)
- `$PYLOT_DISPATCH_TOKEN` — auth token (env)

## Task

### 1. Fetch outcomes summary

Run the following, capturing both the HTTP status and body:

```bash
curl -sf -w "\n__STATUS__:%{http_code}" \
  "${PYLOT_API}/outcomes/summary?scope=pr&org=${ORG}" \
  -H "Authorization: Bearer ${PYLOT_DISPATCH_TOKEN}" \
  2>/dev/null
```

where `ORG` is the GitHub org (e.g. `fellowship-dev`).

### 2. Parse and format

- If the curl call fails (non-zero exit) → `baseline = "not yet measured"`; `baseline_detail = "API unavailable"`.
- If HTTP status is not `200` → same placeholder.
- If body is empty or `{}` or `{"metrics":{}}` or similar empty metrics object → same placeholder.
- Otherwise: format the returned metrics as a short human-readable string.

**Formatting example** — if the API returns:
```json
{"pr_merged":{"mean":0.78,"unit":"rate","window_days":30,"sample_count":142},
 "time_to_merge_hours":{"mean":4.2,"unit":"hours","window_days":30,"sample_count":142}}
```
→ `"pr_merged: 78% (30d avg, n=142) | time_to_merge_hours: 4.2h (30d avg, n=142)"`

Only include metrics with a non-null `mean`. Skip metrics with no samples (`sample_count == 0`).
If the API returns a flat object (metric names as keys, values as objects), apply the same logic.
If the shape is completely unexpected (not parseable as metrics), treat as empty → placeholder.

### 3. Agent-suggested target
Based on the baseline, generate a reasonable improvement target:
- For rate metrics (0–1 or percentage): suggest +5 to +10 percentage-point improvement.
- For duration metrics (hours, days): suggest 10–20% reduction.
- If baseline is placeholder: `"TBD — establish baseline first"`

### 4. Eval criteria
Generate one or two eval criteria statements based on the metric types found, for example:
- `"Regression triggers auto-issue if pr_merged drops >5pp or time_to_merge increases >20%"`
- If baseline is placeholder: `"Define eval criteria once baseline is established"`

## Output: handoff.md

```markdown
# Stage 05c: Outcomes Baseline

## Status
[fetched | placeholder]

## Baseline
[formatted baseline string, or "not yet measured"]

## Baseline Detail
[human-readable note about data source, date range, or error reason]

## Target
[agent-suggested target string]

## Eval Criteria
[agent-generated eval criteria string]
```

## Success criteria
- Handoff always written — never error, never exit early, never re-throw
- If API succeeds and returns metrics: baseline contains real values
- If API fails or returns empty: baseline is `"not yet measured"`, status is `placeholder`
- Target and eval criteria are always populated (placeholder values if no data)
