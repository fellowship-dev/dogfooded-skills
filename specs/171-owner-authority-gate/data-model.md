# Phase 1 Data Model: Owner-Authority Gate Narrows `security` Parking

No persistent storage. The only "data" is the handoff extension `02-review` writes and
`03-synthesize-act` reads — an addition to the existing `handoff.md` contract between the two
stages, not a new interface.

## Entity: `## Owner Authority (#3240)` handoff block

Written by `cto-review/stages/02-review/CONTEXT.md`'s new classifier step, into its
`handoff.md` output. Read verbatim by `03-synthesize-act` Step 2 — never re-judged, never
re-derived from the diff.

| Field | Type | Values | Notes |
|-------|------|--------|-------|
| `owner_authority_class` | enum | `none` \| `destructive-prod-data` \| `spend-above-budget` \| `secrets-handling` \| `external-send` \| `org-policy` | Closed set, six values (`none` + the five taxonomy classes). No sixth class, no catch-all (TR3). Drives the gate: only a non-`none` value applies `waiting-on-owner` (TR1b). |
| `owner_authority_evidence` | string | `file:line` + one-line verbatim quote of what the diff DOES, or `none` | Must be a quotable runtime-effect artifact — never a bare file path or file name (TR4). `none` only when `owner_authority_class: none`. |
| `owner_decision_line` | string | one closed yes/no or A-vs-B question, or `none` | Exactly one question — no compound questions, no open-ended prompts. Feeds the park-comment template's `**Decision needed:**` line (TR6). |
| `owner_answerer` | string | name/role, or `none` | The authorized human who can resolve `owner_decision_line`. Feeds the park-comment template's `**Who can answer:**` line (TR6). |

## State transitions

`owner_authority_class` has no transitions of its own — it is computed fresh every `02-review` run
from the current diff, never persisted or carried across PR revisions. The PR-level state it
feeds (`waiting-on-owner` label, applied by `03-synthesize-act`) already exists and is unchanged
by this feature except for which conditions are now allowed to set it: a human directly, or this
classifier's non-`none` result — never `security`.

## Relationships

- `owner_authority_class != none` → `03-synthesize-act` applies `waiting-on-owner` and posts the
  park-comment template populated from the other three fields.
- `owner_authority_class == none` AND no human-applied `waiting-on-owner` in the fresh label read
  → gate does not fire; `security` (if present) is informational only.
