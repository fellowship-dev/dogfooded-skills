# Automation Schema Reference

Automations define which GitHub events trigger which missions. They are declared in `event-rules.yml` and managed via the `/rules` API. The event-router reads this file on every 60-second cycle — changes take effect without a gateway restart.

## Full Schema

```yaml
- name: my-automation           # kebab-case, unique (required)
  description: "Human-readable explanation"
  event: issues.labeled         # single event type (use OR events: [...] for multi)
  # events:                     # alternative: list of event types
  #   - pull_request.opened
  #   - pull_request.reopened
  match:                        # all match fields are optional
    label: ready-to-work        # label that triggered the event (exact)
    labels_include:             # ALL must be present
      - approved
    labels_exclude:             # NONE may be present
      - dependencies
      - automated
    only_repos:                 # whitelist — null means org-wide
      - fellowship-dev/pylot
    skip_repos:                 # blacklist — skip these repos
      - fellowship-dev/test
    merge_strategy: auto        # match repos with this merge_strategy in crew.yml
    pr_state: open              # open | closed | merged
    files:                      # fire if any changed file matches a glob (PR events)
      - "gateway/**"
    files_exclude:              # skip if any changed file matches a glob
      - "*.md"
  dispatch:                     # required
    task_template: "Run /speckit-runner on {repo}#{number} — {title}"
    context_template: "Event: {event}. Labels: {labels}. Issue: {url}. Actor: {actor}."
    dedup_prefix: "speckit-{number}"
    agent: infra.dev            # override team-resolved agent
```

## Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | kebab-case string | yes | Unique identifier — used in logs and API paths |
| `description` | string | no | Human-readable explanation |
| `event` | string | one of event/events | Single GitHub event type (e.g. `issues.labeled`, `pull_request.opened`) |
| `events` | string[] | one of event/events | Multiple event types — mutually exclusive with `event` |
| `match.label` | string | no | Exact label that triggered the event |
| `match.labels_include` | string[] | no | ALL listed labels must be present |
| `match.labels_exclude` | string[] | no | NONE of these labels may be present |
| `match.only_repos` | string[] | no | Restrict to these repos; null = org-wide |
| `match.skip_repos` | string[] | no | Skip these repos |
| `match.merge_strategy` | string | no | Match only repos with this strategy in crew.yml |
| `match.pr_state` | enum | no | `open`, `closed`, or `merged` |
| `match.files` | string[] | no | Fire only if a changed file matches any glob (PR events only) |
| `match.files_exclude` | string[] | no | Skip if a changed file matches any glob (PR events only) |
| `dispatch.task_template` | string | yes | Mission task — template variables substituted before dispatch |
| `dispatch.context_template` | string | no | Extra context appended to the task |
| `dispatch.dedup_prefix` | string | no | Dedup key — prevents re-firing while a matching job is active |
| `dispatch.agent` | string | no | Override team-resolved agent (e.g. `infra.dev`) |

## Template Variables

Available in `task_template`, `context_template`, and `depends_on_match_running` criteria values:

| Variable | Resolves to |
|----------|-------------|
| `{repo}` | Full `org/repo` string |
| `{number}` | Issue or PR number |
| `{title}` | Issue or PR title |
| `{url}` | Full GitHub URL |
| `{event}` | Event type string |
| `{labels}` | Comma-separated label list |
| `{actor}` | GitHub username that triggered the event |

## `dedup_prefix` — Deduplication

When `dispatch.dedup_prefix` is set, the event router checks for any existing job whose filename contains `<dedup_prefix>` across all state directories (`pending/`, `running/`, `done/`, `failed/`). If a match exists, the automation silently skips dispatch.

This provides a natural cooldown: once `/speckit-runner` is dispatched for issue #42, it won't fire again while any job with `speckit-42` in its name exists in any state directory. The cooldown lifts when those archives are rotated.

Use case: prevent re-triggering `/speckit-runner` on every label added to an issue already in the queue.

```yaml
dispatch:
  task_template: "Run /speckit-runner on {repo}#{number}"
  dedup_prefix: "speckit-{number}"   # blocks re-dispatch for this issue number
```

## `labels_exclude` — Suppression

The gateway drops events with `dependencies` or `automated` labels before they reach the event router. Automations can add further suppression via `match.labels_exclude`:

```yaml
match:
  labels_exclude:
    - reviewed        # don't re-review already-reviewed PRs
    - dependencies    # redundant with gateway filter, but safe to include
```

The automation will not fire if **any** of the listed labels are present on the issue or PR at the time of the event.

## API Endpoints

```bash
# List all automations
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/rules"

# Get a single automation
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/rules/<name>"

# Create or update an automation
curl -sS -X PUT \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-automation","event":"issues.labeled","match":{"label":"ready-to-work"},"dispatch":{"task_template":"Run task for {repo}#{number}"}}' \
  "$PYLOT_GATEWAY_URL/rules/my-automation"

# Delete an automation
curl -sS -X DELETE \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/rules/my-automation"

# DB parity check (diff DB vs YAML during dual-write mode)
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/rules/_db"
```

See the `/pylot-automations` skill for inventory, per-repo coverage inspection, onboarding workflows, and missed-automation diagnosis.
