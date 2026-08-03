---
name: pylot-workers
description: DEPRECATED — worker spawn/drive/stop moved into pylot-cli. Read pylot-cli instead; this skill is a pointer and carries no instructions.
user-invocable: false
---

# pylot-workers — DEPRECATED, use `pylot-cli`

**Superseded by [`pylot-cli`](../pylot-cli/SKILL.md) on 2026-08-03 (pylot #2833 / epic #2834).**
This skill is kept only so the name stays resolvable for anything that still
references it. It carries no instructions — do not follow it, do not add to it.

## Why

`pylot-workers` existed because it was the *injected baseline* skill on every
operator, so it was the only reliable place to document the worker API. Since
pylot #2833 step 3 the injected baseline is `pylot-cli`, and `pylot-cli` absorbed
the full worker lifecycle. Two documents describing the same API is how they
drift, so there is now one.

## Where it went

| You wanted | Now read |
|---|---|
| spawn a worker | `pylot-cli` § Workers → **2. Spawn** |
| queue a prompt / drive a turn | `pylot-cli` § Workers → **3. Drive** |
| poll to idle | `pylot-cli` § Workers → **3. Drive** (`--wait`, or poll `view` until `turn_state` is terminal **and** `turn_seq` ≥ the prompt's seq) |
| stop / resume | `pylot-cli` § Workers → **4. Stop (destructive) and resume** |
| the raw `curl` drive loop | `pylot-cli` § Workers → **7. Fallback when there is no usable CLI** — same routes, same semantics |
| what a mission operator's token may call | `pylot-cli` § Workers → **6. What your credential can call** |

`pylot-cli` covers ground this skill never did: repo preflight before spawn
(`pylot devboxes project`), typed spawn failures, the mission-scope rule
(`--mission "$PYLOT_JOB_ID"` inside a mission, or 403), multi-box relay, and
never busy-polling in a chat/Lambda runtime.

## If you are here from a skill or an assignment row

Update the reference to `pylot-cli`. `pylot-cli` is the injected baseline on
every operator, so it is always loaded — no assignment row is needed for it.
