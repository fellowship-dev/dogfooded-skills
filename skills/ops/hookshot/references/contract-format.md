# Outcome contract format

The shape `scripts/gate.py` parses. A contract is a markdown file the agent writes at the start of a task session and points to from `<state>/contracts/<session_id>`. The gate reads it at Stop.

## Structured shape (deterministic checks)

```markdown
# Outcome contract: <short title>

Mode: Deliver            # any single word; recorded, not judged

## Deliverables

1. <what exists when this item is done>
   - Evidence: `path/to/file`; https://github.com/org/repo/pull/12; receipt: "exact line in the final message"
2. <next item>
   - Evidence: <free text the judge verifies>

## Standards

- <standard the task must apply>

## Non-goals

- <what this session will not do>

## Expected end state

- `DELIVERED`: <what it needs>
- `AWAITING OWNER ACTION`: <the exact owner action>
- `BLOCKED`: <the dependency>

## Result                # written at the end; `## Delivery gate receipt` is accepted too

`DELIVERED` on 2026-09-16.
- 1: DELIVERED <pointer>
- 2: BLOCKED — <dependency named>
```

Rules the parser applies:

- **Items** are numbered lines (`1.`, `2.`, …) directly under `## Deliverables` (a heading that starts with "Deliverables" is accepted). No numbered items means the contract is **loose**.
- **Evidence** is the first sub-bullet of an item that starts with `Evidence:`, or an inline `Evidence:` on the item line. Tokens are split on `;` and `,` and classified:
  - `receipt: "literal"` → the literal must appear in the final assistant message or in the Result section.
  - `https://github.com/<org>/<repo>/pull/<n>` → checked with `gh pr view`; other URLs get a HEAD request. No network, or an ambiguous failure, records `unverifiable` and goes to the judge, never a miss.
  - a backticked or bare token that looks like a file path (`a/b`, `~/x`, `name.ext`) → must exist relative to the session cwd. A bare `org/repo` is not a path.
  - anything else → a judge item.
- **Result section** (`## Result` or `## Delivery gate receipt`): the first status word found is the section status. Per-item lines `- <n>: <STATUS> <text>` give item statuses.
  - `BLOCKED` or `AWAITING OWNER ACTION` on an item exempts it from the evidence check only when the line names the dependency or the action (at least a short clause after the word). A bare status word is the `bare_status` miss.
  - When per-item lines exist, an item without one is `short_count`. When there are none, short count is a judge question.

## Loose shape (judge only)

Any contract without numbered deliverables parses as `format: loose`: the gate records the status-word check and hands the whole diff to the judge. Nothing is refused deterministically. Use this shape when writing the structured one would cost more than the task; the shadow log shows how often it happens.

## Misses

| Miss | Detected by |
|---|---|
| `no_status_word` | final message lacks `DELIVERED`, `AWAITING OWNER ACTION`, `BLOCKED` |
| `claim_without_evidence` | a path is missing, a receipt literal is absent, a URL or PR resolves to not-found |
| `short_count` | an item has no per-item Result line while others do |
| `bare_status` | a hold status with no dependency or action named |
| `work_still_running` | the Stop payload lists `background_tasks` (Claude Code); otherwise judge |
| `substitution`, `skipped_standard` | judge only |
