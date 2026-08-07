---
name: pylot-cli
description: Compact CLI reference for gateway work — dispatch, monitor, secrets, devbox workers, automations.
user-invocable: false
allowed-tools: Bash, Read
---

## Dispatch a Mission

```bash
CONV_ID=$(ls ~/.claude/session-env/ | head -1)
pylot dispatch "<task>" --agent <team>.<role> --repo <org/repo> --context "conversation_id=$CONV_ID"
```

Always pass `--context conversation_id=…` for auto-wake. Prompt limit: 4 KB — put full specs in issue comments.

## Monitor Missions

```bash
pylot missions list                      # recent missions
pylot missions view <job-id>             # full detail
pylot missions logs <job-id> --follow    # tail CloudWatch logs
```

Terminal statuses: `done`, `failed`, `cancelled`, `timeout`.

## Secrets Discovery

```bash
pylot secrets tree                       # full secrets tree
pylot secrets get <path>                 # bundle keys + fingerprints (no values)
```

Load into conversation: `pylot conversations resources-add <conv-id> type=secret ref=pylot/<path>`

## Workers — Spawn, Drive, Stop

A worker is a Fargate devbox running the target repo. Ownership is by scope:
`spawn` and `list` need **exactly one** of `--mission` / `--conversation`; the
per-worker verbs take `--mission` or fall back to the unscoped `/workers/:wid`
route. Verify flags with `--help` — image CLIs vary in age.

### 1. Preflight the repo

```bash
pylot devboxes project <org/repo>    # → task_def{family,revision}, required_env_ok
```

No `task_def` means no image was ever built and the spawn boots into
`CannotPullContainerError`. Build first: `pylot deploy build-worker <org/repo> --wait`
(admin credential — an operator gets 403; see §6). Spawn failures are typed:
`404 no_project`/`no_repo` (repo not in any team's devbox config), `409` mission
already terminal, `422 provider_required`, `502` ECS/secrets.

### 2. Spawn

```bash
# inside a mission — your own job
pylot workers spawn --mission "$PYLOT_JOB_ID" repo=<org/repo>
# from a conversation — name= is the human-readable pretty name (tag pylot:name)
pylot workers spawn --conversation "$CONV_ID" repo=<org/repo> name=<short-purpose>
```

201 → `{worker_id, task_arn, last_status}`. Boot runs PROVISIONING → RUNNING
(~1–2 min). Prompts are queued server-side and claimed once the in-container
daemon boots, so an early prompt is not lost; if you need RUNNING confirmed,
`pylot workers list --mission "$PYLOT_JOB_ID"` carries live `ecs_status` (the
single-worker `view` does not). `name=` is honoured on the conversation path only.

### 3. Drive

```bash
pylot workers prompt <wid> --mission "$PYLOT_JOB_ID" "<text>"     # 202 {turn_seq} | 409 busy|stopped
pylot workers prompt <wid> --mission "$PYLOT_JOB_ID" --wait --timeout 3600 "<text>"
pylot workers view   <wid> --mission "$PYLOT_JOB_ID"              # turn_state, turn_seq, last_result, last_exit_code
pylot workers output <wid> --mission "$PYLOT_JOB_ID"              # result text only
pylot workers logs   <wid> --mission "$PYLOT_JOB_ID"              # CloudWatch tail (--mission required)
```

The turn is done when `turn_state` is `idle`/`error`/`reaped` **and** `turn_seq` ≥
the seq the prompt returned. Only trust `last_result` then. `--wait` polls every
5 s up to 900 s (override with `--timeout`) and exits non-zero on a non-`idle`
terminal state; `--follow` streams container logs to stderr and requires `--wait`.
A devbox that dies mid-turn is reaped with `last_exit_code: -1`, so the loop
cannot hang forever. Between phases, read the output before sending the next
prompt — a failed phase should not be built on.

If `--wait` / `--follow` / `output` are absent from `pylot workers prompt --help`,
this container's CLI predates them: poll `view` on a sleep loop, or use §7.

In a chat/Lambda runtime there is no budget to block on `--wait` — never busy-poll.
Prompt, then schedule a wake (see Async Wake Pattern) and re-check `view` next turn.

### 4. Stop (destructive) and resume

```bash
pylot workers stop   <wid> --mission "$PYLOT_JOB_ID" --force
pylot workers resume <wid> --mission "$PYLOT_JOB_ID"
```

`--force` is mandatory — the CLI refuses the stop without it. Ask a human before
stopping a box someone is working in. Stop is idempotent; always stop a mission
worker when the skill finishes (harvest-on-complete is the backstop, not the plan).
Conversation-owned devboxes snapshot on stop and `resume` restores that snapshot
with `session_id` preserved; mission-worker snapshots are opt-in and OFF by default
(cost control), so treat a mission worker's stop as final unless you know the flag
is on.

### 5. Multi-box work — you are the message bus

Boxes never talk to each other. Preflight and spawn one per repo with distinct
purpose names, then relay by hand: `workers view` A → extract the load-bearing
evidence (request id, stack trace, payload shape) → `workers prompt` B with it.
Keep relayed context small and factual; never pass secrets between boxes — each
box already carries its own bundle as env. Two boxes burn budget twice as fast,
so only spawn a second when both repos genuinely need code or log access.

### 6. What your credential can call

The capability gate fires **only** on the operator JWT a mission container runs on
(`PYLOT_OPERATOR_TOKEN`, aliased to `PYLOT_DISPATCH_TOKEN`). Operators hold every
operator capability, so the gate reduces to one question: is the route mapped at
all? Mission-scoped worker routes are; unscoped ones are not.

**Exception — session JWT (`$PYLOT_API_TOKEN`)**: the following conversation-scoped routes
ARE mapped at `org:member` tier (`route-capability.mts:224-229`) and ARE reachable
with a session JWT — the capability gate passes them through, and each handler enforces
its own authorization server-side:

| Route | Since | Auth boundary |
|---|---|---|
| `POST /conversations/:id/slack-post` | #2622 | handler: org member |
| `POST /conversations/:id/slack-pickup` | #2622 | handler: org member |
| `POST /conversations/:id/admin-action` | #2891 | handler: org-admin check via turn-trigger |
| `POST /conversations/:id/admin-action/confirm` | #2891 | handler: org-admin check via turn-trigger |

These are the only conversation-scoped routes that accept a session JWT. All other
conversation-scoped routes and all `/admin/*` routes remain 403 for session JWTs — by design.

| Call | Mission operator | Devbox worker · local `pylot auth login` |
|---|---|---|
| `workers spawn`/`list`/`view`/`prompt`/`output`/`stop`/`resume`/`logs` **with `--mission`** | yes | yes |
| the same verbs **without** `--mission` (unscoped `/workers/:wid`) | **403** | yes |
| `workers spawn`/`list --conversation` | **403** | yes |
| `devboxes projects`, `devboxes project <org/repo>` | yes | yes |
| `devboxes spawn`/`view`/`connect`/`delete`/`list` | **403** | yes |
| `deploy build-worker`, `deploy promote` | **403** | yes |
| `deploy status <build_id>` | yes | yes |

A gate 403 reads `{"error":"forbidden","reason":"capability_required","capability":"unknown"}`.
Nothing outside the operator JWT is capability-gated, but handler-level org fences
still apply to org-scoped tokens. **Inside a mission, always pass
`--mission "$PYLOT_JOB_ID"`** — that one habit avoids every operator 403 above.

### 7. Fallback when there is no usable CLI

Only for containers whose image carries no `pylot` or one too old for the verb you
need. `PYLOT_JOB_ID`, `PYLOT_API`/`PYLOT_GATEWAY_URL` and `PYLOT_DISPATCH_TOKEN` are
set in both operator and mission-worker containers.

```bash
AUTH=(-H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json")
BASE="${PYLOT_API:-$PYLOT_GATEWAY_URL}/missions/${PYLOT_JOB_ID}/workers"

WID=$(curl -s --max-time 90 -X POST "${AUTH[@]}" -d "{\"repo\":\"$REPO\"}" "$BASE" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))')
SEQ=$(curl -s --max-time 30 -X POST "${AUTH[@]}" -d "{\"prompt\":\"$PROMPT\"}" "$BASE/$WID/prompt" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))')
# poll GET "$BASE/$WID" until turn_state=idle AND turn_seq=$SEQ, then read last_output
curl -s --max-time 30 -X POST "${AUTH[@]}" "$BASE/$WID/stop" >/dev/null 2>&1 || true
```

Same routes, same semantics as §2–4. Prefer the CLI wherever it exists — one
transport, one source of truth.

## Org Setup From a Conversation (admin-action)

> **Requires [pylot#2978](https://github.com/fellowship-dev/pylot/issues/2978)** —
> `pylot convo admin-action` must be present in the worker image before workers are
> directed here. Verify: `pylot convo admin-action --help` must succeed in the container.

Session JWTs carry scopes `[dispatch, missions:read, heartbeat]` — `/admin/*` routes
always 403 by design. `/conversations/:id/admin-action` is a separate authorization
boundary (see §6 exception table) that accepts session JWTs; the endpoint enforces
org-admin authorization server-side via the turn's triggering message sender.

### Primary path

```bash
# auto-detects $CONVERSATION_ID from environment
pylot convo admin-action <op> [key=value ...]

# explicit conversation id override
pylot convo admin-action <op> --conversation <id> [key=value ...]

# confirm a staged (confirm-tier) operation after org admin replies
pylot convo admin-confirm <code>

# reject a pending confirm-tier operation
pylot convo admin-confirm <code> --reject
```

### Operations

Op list is **closed** — any value not in this table returns 400.
**Never pass credentials or API keys in op args** — the gateway returns 400 and
nothing is stored (hard boundary: credential-looking args are explicitly rejected).

| op | tier | effect |
|---|---|---|
| `setup-status` | read (any conversation member) | onboarding state: App install, teams, repo bindings + worker-image presence, goals, operators/skills, provider chain, budget |
| `team-create` | immediate (org admin requester) | create a team in this org |
| `team-rename` | immediate (org admin requester) | rename a team |
| `repos-add` | immediate (org admin requester) | bind a repo to a team; response includes worker-image presence |
| `goals-set` | immediate (org admin requester) | set team goals (the store auto-pylot stage 00 reads) |
| `operator-add` | immediate (org admin requester) | create an operator on a team |
| `skill-assign` | immediate (org admin requester) | assign a skill to an operator |
| `instructions-set` | immediate (org admin requester) | set operator instructions |
| `org-update` | **confirm** | org settings (Slack default team, max_concurrent, …) |
| `budget-set` | **confirm** (spend) | team daily budget cap |
| `provider-assign` | **confirm** (model/spend routing) | attach an existing platform provider chain to org/team |

### Confirm-tier flow

Confirm-tier ops (`org-update`, `budget-set`, `provider-assign`) are staged first,
then approved by an org admin's reply — the approver's identity is proven by their
own conversation turn, not supplied by the worker.

1. `pylot convo admin-action <confirm-op> [args]` → gateway returns `202 {code, summary}`
2. Worker relays to the user: *"An org admin must reply `confirm <CODE>` within 10 minutes."*
   (`summary` describes exactly what will change — relay it verbatim.)
3. The org admin sends a reply; the approval turn's own message sender proves their identity.
4. `pylot convo admin-confirm <CODE>` (called in the approval turn) → `200`, executed.
5. Rejected or expired: `pylot convo admin-confirm <CODE> --reject` kills the pending action;
   an expired code (>10 min) returns `410` and never executes.

### Errors

| error | meaning | user-facing guidance |
|---|---|---|
| `no_human_trigger` | Turn has no human sender (scheduled wake-up, automation) | Retry from a conversation turn triggered by a human message |
| `unlinked_slack` | Sender's Slack account is not linked to a GitHub account | Ask the user to link their GitHub account in the Slack app settings |
| `not_org_admin` | Linked GitHub account is not an admin of this org | Immediate ops need an org admin in the thread; confirm-tier: anyone can stage, an org admin must confirm |
| `terminal_only` | Op would require a credential or secret value | Use the terminal CLI — credentials cannot transit the conversation |
| `code_expired` | Confirm code is older than 10 minutes | Re-run the original op to get a fresh code |

### Transition-window curl fallback (pre-#2978 images only)

Use this only if the container image predates `pylot convo admin-action`.
`$CONVERSATION_ID` is set in chat-worker containers. **Use `$PYLOT_API_TOKEN`
(session JWT) — NOT `$PYLOT_DISPATCH_TOKEN`** (operator token 403s this endpoint
by design; using it here is the exact mis-behavior pylot#2979 corrects).

```bash
# immediate op
curl -s -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"op\":\"$OP\"}" \
  "${PYLOT_API:-$PYLOT_GATEWAY_URL}/conversations/$CONVERSATION_ID/admin-action"

# confirm a staged op (after org admin replies with the code)
curl -s -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"code\":\"$CODE\"}" \
  "${PYLOT_API:-$PYLOT_GATEWAY_URL}/conversations/$CONVERSATION_ID/admin-action/confirm"
```

## Automations

```bash
pylot automations list           # inventory with run stats
pylot automations get <name>     # single rule detail
```

Per-repo coverage: filter `only_repos`/`skip_repos` from list output.

## Async Wake Pattern

Dispatch with `--context conversation_id=…` → auto-wake on mission terminal + PR lifecycle.
Self-wake fallback: `pylot conversations wakes-add <conv-id> in_seconds=300 content="check X"`
One wake at a time; re-schedule rather than stack.

## Dispatch vs. Local

| Do locally | Dispatch |
|------------|----------|
| Answer questions, check status, query API | Code changes, PRs, reviews |
| Read logs, explain code | Docker builds, deploys |
| Quick lookups (< 2 min) | Test suites, anything > 10 min |
