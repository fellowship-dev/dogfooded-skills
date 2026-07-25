---
name: pylot-api
description: Use when looking up Pylot gateway API endpoints for dispatch, status monitoring, or crew management.
user-invocable: false
allowed-tools: Bash, Read
---

## Role & Mission

The chat agent is the resident Pylot expert — dispatch tasks, monitor missions, keep the platform healthy:

- **Dev environment stewardship**: worker images, system libs, devcontainer config — workers should run what they need without runtime installs
- **Visual evidence pipeline**: every UI-changing PR should include a GIF or screenshot — upload via the [assets backend](docs/assets.md) (presign → PUT → publish → embed `public_url`)
- **Skills maintenance**: read logs after missions, spot struggles, improve skills or open follow-up issues
- **PR stewardship**: dispatch → monitor → review → merge → verify; no PRs left stale

## Auth

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/<endpoint>"
```

`PYLOT_GATEWAY_URL` and `PYLOT_API_TOKEN` are in env.

## Quick Start: Dispatch

**Always pass `context.conversation_id`** — enables auto-wake on mission completion and PR lifecycle events:

```bash
CONV_ID=$(ls /tmp/claude-home/.claude/session-env/ | head -1)
curl -sS -X POST -H "Authorization: Bearer $PYLOT_API_TOKEN" -H "Content-Type: application/json" \
  -d "{\"agent\":\"<team>.<op>\",\"task\":\"<task>\",\"context\":{\"conversation_id\":\"$CONV_ID\"}}" \
  "$PYLOT_GATEWAY_URL/dispatch"
```

## API Reference

Full reference lives in `docs/` — read the relevant file before making calls:

- [Dispatch](docs/dispatch.md) — send missions, context.conversation_id, prompt limits, examples
- [Monitoring](docs/monitoring.md) — check status, stream CloudWatch logs, filter by team/status
- [Wakes](docs/wakes.md) — self-wake, auto-wake on completion, wake event payloads, timing guide
- [Resources](docs/resources.md) — load/unload keychains and skills
- [Secrets](docs/secrets.md) — discover keychains, fingerprints, key descriptions
- [Crew](docs/crew.md) — roster, stats, costs, config
- [Fleet](docs/fleet.md) — Fargate projects and task definitions
- [SDLC](docs/sdlc.md) — PR review pipeline, merge strategies, what to do on wakes
- [Deploy](docs/deploy.md) — staging/prod deploy lanes, POST /admin/deploy, release PR promotion — read before any "ship to prod" request
- [Automations](docs/automations.md) — GET /automations schema, SDLC automation chain, suppression semantics
- [Assets](docs/assets.md) — upload images/GIFs/video (presign → PUT → publish) for PR/issue visual evidence; conversation attach pending Stage E
- [Welcome](docs/welcome.md) — turn-1 guided welcome for orgs with incomplete activation milestones

## Startup / Orient

On turn 1, fetch live automations and render one line per automation (`event [label?] → rule-name excl:[labels_exclude] repos:[only_repos] skip:[skip_repos]`). On failure, warn and continue — never block startup. See [docs/automations.md](docs/automations.md) for field definitions and SDLC chain.

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/automations" \
  | jq -r '.automations[] | "\(.trigger.event) [\(.trigger.match.label // "-")] → \(.name) excl:[\(.trigger.match.labels_exclude // [] | join(","))] repos:[\(.trigger.match.only_repos // [] | join(","))] skip:[\(.trigger.match.skip_repos // [] | join(","))]"' \
  2>/dev/null || echo "[warn] GET /automations unavailable — continuing without live automation summary"
```

### Welcome check (turn 1)

Also on turn 1, if `$CONV_ORG` is set, check the org's activation ladder:

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/orgs/$CONV_ORG/activation"
```

If any milestone **before `automations_on`** is not done, read [docs/welcome.md](docs/welcome.md) and follow the welcome protocol before anything else. If all of them are done, or `$CONV_ORG` is unset: skip — normal behavior, no greeting. On 404/error (endpoint may not be deployed yet), use the fallback heuristic in docs/welcome.md — never mention this failure to the user.

## Worker Environment Variables

Key env vars injected into worker containers at spawn. Read from env directly — never query the gateway for these.

| Var | Type | Purpose |
|-----|------|---------|
| `PYLOT_JOB_ID` | string | Mission ID — used in all worker API calls |
| `PYLOT_TASK` | string | The task prompt the worker received |
| `PYLOT_REPO` | string | `org/repo` the worker is running against |
| `PYLOT_REQUESTORS` | JSON string \| unset | Human requestors who triggered the mission (see below) |
| `PYLOT_GATEWAY_URL` | string | Gateway base URL |
| `PYLOT_DISPATCH_TOKEN` | string | Bearer token for worker → gateway calls |

### `$PYLOT_REQUESTORS`

Set by the executor (#2539) when the dispatching conversation has human participants. Absent on cron, webhook, or direct API dispatches with no conversation context.

**Shape** — a JSON-encoded array of up to 10 objects:

```json
[
  {
    "slack_user_id":   "U012AB3CD",
    "github_username": "maxfindel",
    "display_name":    "Max F. Findel",
    "email":           "max@fellowship.dev"
  },
  {
    "slack_user_id":   "U456EF7GH",
    "github_username": null,
    "display_name":    "Bedo",
    "email":           null
  }
]
```

| Field | Type | Notes |
|-------|------|-------|
| `slack_user_id` | `string` | Always present. Stable Slack user identifier. |
| `github_username` | `string \| null` | `null` when the Slack account is not linked to GitHub (#2538). |
| `display_name` | `string` | Slack display name or GitHub login. Always non-empty. |
| `email` | `string \| null` | `null` when not resolvable by the platform. |

The executor caps the array at **10** requestors — iterate over whatever it contains, assume no other bound. Parse defensively: absent, empty, or malformed JSON all mean `[]` (no attribution, no error).

**Email fallback precedence** — when constructing an email for git trailers or other attribution (in order):

1. `email` non-null and non-empty → use `email`
2. `github_username` non-null, `email` null → `github_username@users.noreply.github.com`
3. `github_username` null → `slack_user_id@users.noreply.fellowship.dev`

**Worker usage** — the `requestor-attribution` skill (pylot#2540, shipped in dogfooded-skills `skills/ops/requestor-attribution`) reads this var and:
- Appends `Co-authored-by:` trailers to every commit (above the Claude trailer)
- Prepends `> Requested by @username, Name (Slack)` to the PR body
- Adds linked users as PR assignees via `gh pr edit --add-assignee` — skip this step when `github_username` is `null`


## When to Dispatch vs. Do Locally

| Task | Local | Dispatch |
|------|-------|----------|
| Answer questions, explain code | ✓ | — |
| Check mission status, read logs | ✓ | — |
| Query the API | ✓ | — |
| Code changes, PRs, reviews | — | ✓ |
| Docker builds, deploys | — | ✓ |
| Run test suites | — | ✓ |
| Anything > 10 min | — | ✓ |

## Linking a user's GitHub identity (conversational ask)

When a user asks to **link their GitHub** (any phrasing: "link my github", "connect my account", "why am I not attributed"), do NOT probe auth routes or guess — mint a self-service link URL with ONE call and hand it back (#2604, shipped in #2598). This is a LOCAL action (no dispatch).

In chat sessions the env gives you everything: `$CONVERSATION_ID` (this conversation), `$PYLOT_API_TOKEN` (session JWT), `$PYLOT_GATEWAY_URL`.

```bash
curl -sS -X POST "$PYLOT_GATEWAY_URL/users/link-request" \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"conversation_id\":\"$CONVERSATION_ID\"}"
```

Equivalent CLI where the `pylot` CLI is installed (worker sessions): `pylot users link slack github --conversation "$CONVERSATION_ID"`.

How it works:
- The gateway derives WHO from the conversation's recorded Slack senders (#2537) — you never pass identity claims. An explicit `slack_user_id` must be a recorded sender, else 403.
- The response contains a **personal URL** that walks the human through GitHub OAuth (#2538). It grants nothing by itself and **expires in 10 minutes**.
- Post the URL back to the requester (ephemeral/DM preferred — it is personal).
- Org-scoped: fenced to the conversation's org.

Error cases (handle, don't retry blindly):

| Response | Meaning | What to tell the user |
|---|---|---|
| 404 `no Slack senders recorded` | conversation predates sender stamping | ask them to send a fresh message and retry |
| `already_linked` | identity already connected | confirm their `github_login` via `GET /users?org=<org>` |
| 403 on `slack_user_id` | identity injection blocked | only recorded senders can be linked — drop the override |
