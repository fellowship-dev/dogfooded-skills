---
name: pylot-api
description: Reference for Pylot executor environment variables injected at worker spawn — covers $PYLOT_REQUESTORS and related env vars available inside worker sessions.
user-invocable: false
---

# pylot-api — Pylot Executor Environment Reference

Documents the environment variables that the Pylot executor injects at worker spawn. Skills running inside worker sessions can read these vars to integrate with the Pylot platform.

---

## `$PYLOT_REQUESTORS`

### What it is

A JSON-encoded array of the human participants who triggered the current mission. Injected by the Pylot executor at worker spawn (see fellowship-dev/pylot#2539) when the dispatching conversation includes human participants.

### When it is absent

`$PYLOT_REQUESTORS` is **not set** (or empty) when the mission was dispatched without a human conversation context:

- Cron-triggered missions
- Direct API calls that do not carry a conversation ID
- Automated pipelines without a linked Slack or UI session

All skills that consume this var must treat absent/empty as a valid no-op case.

### JSON shape

Array of up to **10** objects. When there are more than 10 requestors, the array is capped at 10 entries.

```json
[
  {
    "slack_user_id":   "U01234ABCDE",
    "github_username": "maxfindel",
    "display_name":    "Max F. Findel",
    "email":           "max@fellowship.dev"
  }
]
```

| Field | Type | Notes |
|-------|------|-------|
| `slack_user_id` | `string` | Always present. Stable Slack user identifier. |
| `github_username` | `string \| null` | `null` when the Slack account is not linked to a GitHub account. |
| `display_name` | `string` | Slack display name or GitHub login. Always a non-empty string. |
| `email` | `string \| null` | `null` when the user's email is not available to the platform. |

### Email address fallback precedence

When constructing an email address for git trailers or other attribution contexts, use this three-case fallback (in order):

1. `email` is non-null and non-empty → use `email` directly
2. `github_username` is non-null, `email` is null → use `github_username@users.noreply.github.com`
3. `github_username` is null → use `slack_user_id@users.noreply.fellowship.dev`

### 10-object cap

The executor caps the array at 10 requestors. Skills must not assume a maximum length smaller or larger than 10; iterate over whatever the array contains.

---

See `requestor-attribution` skill for commit and PR attribution implementation using `$PYLOT_REQUESTORS`.

---

## Linking a user's GitHub identity (conversational ask)

When a user asks to **link their GitHub** (any phrasing: "link my github", "connect my account", "why am I not attributed"), do NOT probe auth routes or guess — mint a self-service link URL with ONE call and hand it back (#2604, shipped in #2598).

### In chat sessions

The env gives you everything: `$CONVERSATION_ID` (this conversation), `$PYLOT_API_TOKEN` (session JWT, `org:member`-capable), `$PYLOT_GATEWAY_URL`.

```bash
curl -sS -X POST "$PYLOT_GATEWAY_URL/users/link-request" \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"conversation_id\":\"$CONVERSATION_ID\"}"
```

Equivalent CLI (where the `pylot` CLI is installed, e.g. worker sessions):

```bash
pylot users link slack github --conversation "$CONVERSATION_ID"
```

### How it works

- The gateway derives WHO from the conversation's own recorded Slack senders (#2537) — you never pass identity claims. An explicit `slack_user_id` must be a recorded sender of the conversation, else 403.
- The response contains a **personal URL** that walks the human through GitHub OAuth (#2538). The URL grants nothing by itself and **expires in 10 minutes**.
- Post the URL back to the requester — ephemeral/DM preferred, it is personal.
- Org-scoped: the request is fenced to the conversation's org.

### Error cases (handle, don't retry blindly)

| Response | Meaning | What to tell the user |
|---|---|---|
| 404 `no Slack senders recorded` | conversation predates sender stamping | ask them to send a fresh message and retry |
| `already_linked` | identity already connected | confirm their `github_login` via `GET /users?org=<org>` |
| 403 on `slack_user_id` | identity injection blocked | only recorded senders can be linked — drop the override |
