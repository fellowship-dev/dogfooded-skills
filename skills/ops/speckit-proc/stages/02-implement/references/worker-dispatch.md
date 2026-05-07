# Worker Dispatch

How to construct the worker prompt and dispatch for speckit tasks.

## Prompt Template

The worker runs inside the target repo with full tool access. It has speckit skills mounted (`/speckit-specify`, `/speckit-plan`, etc.) and `GH_TOKEN` for GitHub operations.

```
You are a dev worker implementing issue #{{ISSUE}} in {{REPO}}.

## Context from triage
{{TRIAGE_SUMMARY}}

## Instructions
Run `/speckit-runner {{ISSUE}} {{REPO}}` to implement this issue end-to-end.

The speckit-runner skill handles: pre-flight data gathering, specify, plan, tasks,
implement, review, and PR creation. Follow it completely.
```

Replace `{{ISSUE}}`, `{{REPO}}`, and `{{TRIAGE_SUMMARY}}` with values from the triage output.

## Environment Variables

The spawn script inherits these from the operator environment:

| Variable | Purpose |
|----------|---------|
| `PYLOT_SESSION_ID` | Worker session tracking |
| `PYLOT_JOB_ID` | Mission log aggregation |
| `PYLOT_MODEL` | Worker model (default from crew.yml) |
| `GH_TOKEN` | GitHub API access in the worker |
| `PYLOT_FARGATE_CLUSTER` | ECS cluster for Fargate dispatch |
| `PYLOT_WORKER_TASK_DEF` | ECS task definition for worker image |

## Branch Discovery

The worker's speckit-specify phase creates the feature branch. Do NOT pre-create branches. The operator discovers the branch name after completion by listing open PRs or reading the worker log.

## Retry on Stall

If `wait-for-worker.sh` exits with code 2 (no log activity for 9 minutes):
1. Read last 30 lines of worker log to understand where it stalled
2. Re-spawn with the same prompt (the worker starts fresh)
3. Maximum 3 total attempts before reporting failure
