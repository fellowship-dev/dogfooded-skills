---
name: pylot-cli
description: Compact CLI reference for chat workers — dispatch, monitor, secrets, workers, automations.
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

## Devboxes — Spawn + Prompt

```bash
pylot workers spawn --conversation <conv-id>     # returns worker_id
pylot workers prompt <wid> "<text>"              # send prompt (returns turn_seq)
pylot workers view <wid>                         # status + metadata
pylot workers stop <wid>                         # terminate
```

For the full poll-to-idle drive loop, Read the `pylot-workers` skill on demand.

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
