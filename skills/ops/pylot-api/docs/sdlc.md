# SDLC — Chat Agent Perspective

Once a PR is open, the review pipeline runs automatically. Do not ask the user to review — just monitor and report the outcome.

## Default Pipeline

```
PR opened
  └─► review-pr      — first-pass diff review, adds "reviewed" label
  └─► double-check   — deeper check, adds "double-checked" label
  └─► cto-review     — approves + merges, OR requests rework
          └─ rework ──► double-check ──► cto-review  (repeats until merge)
```

**Merge is not the end of the line for backend changes.** A merge to `develop`
auto-deploys **staging only**; prod runs `main` and requires the release-PR
promotion plus an explicit `POST /admin/deploy` — see [Deploy](deploy.md).

## Pipeline Variations

The pipeline is driven by event rules configured per team and repo. Check `GET /crew` for a team's actual config:

| Config | Effect |
|--------|--------|
| `merge_strategy: auto` (default) | Merger role merges automatically after approval |
| `merge_strategy: label-only` | Merger role applies `ready-to-merge`; a human merges manually |
| QA skill enabled | QA step runs between double-check and final review |
| `dependencies` / `build-train` PRs | Skip review-pr and double-check entirely |

## What the Chat Agent Should Do

1. **Dispatch with `context.conversation_id`** — auto-wake fires on PR open, PR merge, and mission terminal state (see [Wakes](wakes.md))
2. **On `pr_opened` wake**: tell the user the PR is up, pipeline is running — no action needed
3. **On `pr_merged` wake**: tell the user it merged, include the PR URL
4. **On `done` wake with no PR**: report outcome from mission logs
5. **Never ask the user to review** — the pipeline handles it automatically
6. **Asked to ship to prod**: follow [Deploy](deploy.md) — release PR develop→main (owner merges), then `POST /admin/deploy`. Never prescribe local `cdk deploy`

## Rescheduling When Condition Not Met

If you wake and the PR is not yet open (worker still running), check the last log line and schedule one more wake using the timing guide in [Wakes](wakes.md). Do not stop silently.

## Full SDLC Reference

See `docs/sdlc.md` in the repo for the complete stage table, event rule chain, parallel tracks (entropy, deps, distill), and gap analysis.
