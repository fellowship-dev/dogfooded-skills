# Stage 05c: Outcomes Baseline

## Purpose
Decide whether this issue carries an explicit **causal measurement contract** — a goal, eval, or
outcome linkage the issue itself states — and only then anchor the PRD's Measurable Impact section
in real data. Pylot does not manufacture a metric for a PRD just because the outcomes API exists.

This stage never gates stage 06 and never fails the run: contract detection either finds a
contract or it doesn't, and the API call (when made) is **fail-open** — any error (unavailable,
network, 4xx/5xx, empty response) yields a placeholder baseline, never a blocked PRD.

There is no goal database, schema, or lookup service here — the contract is read straight out of
the issue text stage 01 already fetched. If Max later stands up a goal system, this stage points
at it; until then, the issue body/comments are the only source of truth.

## Inputs
- `stages/01-read-issue/output/handoff.md` — issue title, body, comments (the only place a
  contract can come from)
- `{org}` — the GitHub org owning the issue repo (from stage 01 handoff or the repo argument)
- `$PYLOT_API` — gateway base URL (env)
- `$PYLOT_DISPATCH_TOKEN` — auth token (env)

## Task

### 1. Detect a causal measurement contract
Read the issue body and comments from the stage 01 handoff. A contract exists **only if all
three** are present, explicitly, in the issue text (not inferred, not assumed):

1. **A named metric** — a specific metric name (e.g. `pr_merged`, `time_to_merge_hours`, or
   another metric the issue names explicitly).
2. **An explicit numeric target or threshold** for that metric, stated by the issue author (e.g.
   "target: pr_merged >= 85%", "reduce time_to_merge_hours by 20%", "should push X to Y"). A
   target the agent would have to compute or estimate does not count.
3. **Explicit causal/goal framing** tying this issue's work to that metric — language like
   "Goal:", "Success metric:", "Eval:", or a plain statement that this work is expected to move
   the named metric.

If all three are present → **contract = linked-metric**. Extract the metric name and the target
text verbatim (quote it, do not paraphrase or round it).

If any is missing → **contract = none**. Do not call the outcomes API — there is nothing to look
up, and calling it would only tempt a generic baseline into filling the gap.

### 2. Fetch a scoped baseline (linked-metric contract only)
```bash
curl -sf -w "\n__STATUS__:%{http_code}" \
  "${PYLOT_API}/outcomes/summary?scope=pr&org=${ORG}" \
  -H "Authorization: Bearer ${PYLOT_DISPATCH_TOKEN}" \
  2>/dev/null
```
where `ORG` is the GitHub org (e.g. `fellowship-dev`). From the response, pull out **only the
named metric** from step 1 — ignore every other metric the API returns, even if present.

- Curl fails (non-zero exit), HTTP status is not `200`, or the named metric is absent / has no
  samples (`sample_count == 0`) → `baseline = "not yet measured"`, `status = placeholder`.
- Otherwise → format the one metric's baseline, carrying every field needed to source it:
  **source** (`GET /outcomes/summary?scope=pr&org=<org>`), **window** (`window_days`), **cohort**
  (`scope=pr, org=<org>`), **sample size** (`sample_count`), and the **mean**.

**Formatting example** — issue named `time_to_merge_hours`, API returns:
```json
{"time_to_merge_hours":{"mean":4.2,"unit":"hours","window_days":30,"sample_count":142}}
```
→ `baseline = "time_to_merge_hours: 4.2h"`, with source/window/cohort/sample size carried
separately into the handoff fields below (not collapsed into one string).

### 3. Target and eval rule (linked-metric contract only)
Never compute or suggest a target — copy the one the issue already stated, verbatim, from step 1.
The eval/regression rule is derived from that same explicit target, e.g.: "Regression triggers
auto-issue if `<metric>` regresses past `<the issue's stated target>`." Do not invent a threshold
percentage (no "+5 to +10pp", no "10-20% reduction") — if the issue's stated target doesn't imply
a clear regression threshold, say so instead of guessing one.

### 4. No contract
Set `status = not-applicable`. Baseline, target, and eval criteria are all `"not applicable"`.
Do not fetch, format, or mention any generic metric — `pr_merged` and `time_to_merge_hours` do
not appear anywhere in this stage's output unless the issue itself named them.

## Output: handoff.md

```markdown
# Stage 05c: Outcomes Baseline

## Contract
[linked-metric | none]

## Metric
[metric name from the issue, or "none"]

## Source Text
[verbatim quote from the issue establishing the goal/target, or "none"]

## Status
[fetched | placeholder | not-applicable]

## Baseline
[metric: value, or "not yet measured", or "not applicable"]

## Baseline Source
[source endpoint / window_days / cohort (scope+org) / sample_count, or "not applicable"]

## Target
[the issue's stated target, copied verbatim, or "not applicable"]

## Eval Criteria
[regression rule derived from the issue's stated target, or "not applicable"]
```

## Success criteria
- Handoff always written — never error, never exit early, never re-throw
- `Contract` is `none` unless all three signals (named metric, explicit target, causal framing)
  are present in the issue text
- No outcomes API call when `Contract: none`
- When `Contract: linked-metric` and the API succeeds: baseline carries source, window, cohort,
  and sample size — not just a bare number
- Target and eval criteria are always either the issue's own verbatim words or `"not applicable"`
  — never an agent-computed number
