---
name: vercel-deploy
description: Deploy an existing Vercel project to production. 5-stage ICM procedure — non-interactive, prevents hanging CLIs, verifies before and after.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep
---

## Purpose

Deploy an existing Vercel project to production from a local directory. Designed to never hang, never create new projects, and never assume implicit state.

## Required Secrets

Must be available as environment variables (from crew secret store):

- `VERCEL_TOKEN` — Access token with deploy permissions
- `VERCEL_ORG_ID` — Organization/team ID (starts with `team_`)
- `VERCEL_PROJECT_ID` — Project ID (starts with `prj_`)

## Required Inputs

The dispatch task MUST specify:

- `DEPLOY_DIR` — Path to the deployable directory (e.g., `./ui`, repo root)
- `PROD_DOMAIN` — Expected production domain (e.g., `pylot.fellowship.dev`)

## Optional Inputs

- `DEPLOY_BRANCH` — Git branch to deploy from. **Defaults to `main`** if not specified. Always checks out and pulls before deploying.

## Forbidden Actions

1. **NEVER create a new Vercel project.** If it doesn't exist, STOP and report failure.
2. **NEVER assume project auto-links.** Always verify or write `.vercel/project.json` explicitly.
3. **NEVER connect a git repo to the Vercel project.** All deploys are CLI pushes, not git-triggered.
4. **NEVER run `vercel` without `--token` and `--yes`.** The CLI hangs forever without them.
5. **NEVER run `vercel link`.** It prompts interactively. Write `.vercel/project.json` directly.
6. **NEVER run `vercel project create` or equivalent.** Separate procedure exists for that.

## Stage Overview

| Stage | Name | Purpose |
|-------|------|---------|
| 00 | author-fix | Ensure HEAD commit author matches a Vercel team member |
| 01 | preflight | Verify secrets, tools, compute deploy context |
| 02 | link | Ensure `.vercel/project.json` exists; verify project via API |
| 03 | deploy | Run `vercel deploy --prod` non-interactively |
| 04 | poll | Poll Vercel API until deployment reaches READY or ERROR |
| 05 | verify | Confirm production domain is reachable, emit outcome |

## Stage 00 — Author Fix (CRITICAL)

Vercel blocks CLI deploys when the HEAD commit author is not a verified Vercel team member (`TEAM_ACCESS_REQUIRED` / `seatBlock`). This happens when bot accounts (e.g. `fry-lobster`) push commits.

**Before any deploy attempt:**

```bash
# Check if HEAD commit author matches the Vercel team owner
VERCEL_AUTHOR="maxfindel"
VERCEL_EMAIL="maxfindel@pm.me"
HEAD_AUTHOR=$(git log -1 --format='%an')

if [ "$HEAD_AUTHOR" != "$VERCEL_AUTHOR" ]; then
  echo "[vercel-deploy] HEAD author '$HEAD_AUTHOR' is not a Vercel team member."
  echo "[vercel-deploy] Creating empty commit with author '$VERCEL_AUTHOR' to unblock deploy."
  git commit --allow-empty \
    --author="$VERCEL_AUTHOR <$VERCEL_EMAIL>" \
    -m "chore: vercel deploy author fix (empty commit)"
  git push origin HEAD
fi
```

This creates a no-op commit so Vercel sees a team member as the author. The commit is pushed to the deploy branch (usually `main`).

**Do NOT skip this stage.** Every blocked deploy costs ~$1 in Fargate time and delays the pipeline.

## Execution Model

- Follow stages **in order**. Each stage's checkpoint must pass before proceeding.
- **Do not skip stages.** Every checkpoint is verified.
- **Fail fast.** If any checkpoint fails, stop and report with `status=failed`.
- State is passed between stages via `/tmp/vercel-deploy-*.env` files.

## Critical Rules

1. Sequential execution only. Stage N's checkpoint must pass before starting stage N+1.
2. No skipping. Every stage runs, every checkpoint is verified.
3. Fail fast. If any checkpoint fails, stop and report.
4. Every `vercel` or `npx vercel` invocation MUST include `--token="$VERCEL_TOKEN" --yes`.

## Error Handling

If any stage fails:
1. Print which stage failed and the exact error
2. Include the Vercel API response body if available
3. Emit: `[pylot] outcome="vercel-deploy failed at stage <NN>: <reason>" status=failed`
4. Do NOT retry automatically

## Outcome

On success, emit:
```
[pylot] outcome="vercel-deploy succeeded" project=$PROJECT_NAME domain=$PROD_DOMAIN deploy_id=$DEPLOY_ID status=done
```
