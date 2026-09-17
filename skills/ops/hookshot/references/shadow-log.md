# Gate shadow log

`scripts/gate.py` appends one JSON line per run to `<HOOKSHOT_STATE_DIR>/hookshot/gate-shadow.jsonl` (default `<cwd>/.state/hookshot/gate-shadow.jsonl`; gitignore `.state/`). It never writes the assistant message, the transcript, or anything from the environment beyond `cwd`.

## Line kinds

| `kind` | When | `would_block` |
|---|---|---|
| `gate` | a contract was found and diffed | `true` when any deterministic miss exists |
| `no_contract` | no pointer for this session id, or the pointer target is missing | `false` (chat sessions land here) |
| `error` | stdin was not JSON or the gate hit an internal error | `false` |

Nothing is written when `stop_hook_active` is true.

## `gate` fields

```json
{"ts": "2026-09-16T21:40:12-0300", "client": "claude-code", "mode": "shadow",
 "session_id": "…", "cwd": "/repo", "kind": "gate",
 "contract": "/repo/specs/contracts/2026-09-16-005-x.md", "format": "structured", "contract_mode": "Deliver",
 "status_word": "DELIVERED", "judge": "native", "judge_items": 4,
 "misses": [{"type": "claim_without_evidence", "item": 3, "evidence": "reports/out.md", "check": "path_missing"}],
 "would_block": true}
```

- `client`: `claude-code`, `codex`, or `codex-exec` (runner-invoked after a non-interactive session).
- `mode`: `shadow` logs only; `enforce` also returns a block decision when `would_block` is true.
- `format`: `structured` or `loose` (see `contract-format.md`).
- `judge`: `native` when the client runs an LLM judge hook and a packet was written to `<state>/hookshot/judge/<session_id>.json`; `none` otherwise. `judge_items` counts what the judge would have to answer.
- `misses`: deterministic misses only. Types: `no_status_word`, `claim_without_evidence`, `short_count`, `bare_status`, `work_still_running`.

## Reading it

Would-be refusals over the shadow window:

```bash
jq -c 'select(.kind=="gate" and .would_block)' .state/hookshot/gate-shadow.jsonl
```

How much needs a judge that no client provides:

```bash
jq -c 'select(.kind=="gate" and .judge=="none" and .judge_items>0) | {client, format, judge_items}' .state/hookshot/gate-shadow.jsonl
```

A false positive is a `would_block: true` line whose session did deliver. Fix the contract shape or the parser before flipping `HOOKSHOT_GATE_MODE` to `enforce`.
