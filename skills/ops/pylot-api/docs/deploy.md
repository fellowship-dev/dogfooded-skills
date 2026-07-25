# Deploys — Chat Agent Perspective

Merge ≠ shipped. Backend merges land on `develop`; **prod runs `main` and never
auto-deploys**. When a user asks to "ship it" or "see it through to prod", this
is the path — do not invent one from repo archaeology.

## The prod lane (backend / gateway / CDK)

```
merge to develop
  └─► staging auto-deploy        — cdk-deploy-staging-on-backend-push automation
  └─► release PR develop→main   — auto-pylot maintains "[auto-pylot] Release: develop → main";
        (OWNER merges manually)    do NOT merge it via automation
  └─► POST /admin/deploy         — on the PROD gateway; empty body {} deploys main
```

## Deploy API

```bash
# Trigger (async — returns build id immediately):
curl -sS -X POST -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" -d '{}' \
  "$PYLOT_GATEWAY_URL/admin/deploy"

# Poll to terminal state (never fire-and-forget):
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/admin/build-worker/<build_id>"

# Build logs:
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  "$PYLOT_GATEWAY_URL/admin/deploy/logs/<build_id>"
```

- `{"source_version": "<branch-or-sha>"}` deploys a specific ref (staging PR testing).
- `409 {stage, held_by, ...}` = deploy lock — another deploy is running; poll and retry.
- The endpoint triggers CodeBuild (`buildspec-cdk-deploy.yml`), which builds the
  bundle and runs `cdk deploy` inside a region-fenced role. Staging and prod are
  physically isolated — pointing at the prod gateway deploys PROD.

## Hard rules

- **NEVER tell anyone to run `cd infra && npx cdk deploy` locally.** Local CDK
  is banned by deploy policy (it deploys whatever stale bundle is on disk and
  bypasses the region fence). The only sanctioned local cdk is the one-time
  fresh-account bootstrap by a credential holder.
- **Never update Lambda code via zip** (`aws lambda update-function-code`).
- If your token 403s on `/admin/deploy`: dispatch the deploy to the infra team,
  or tell the owner to run `pylot deploy --env prod --wait`. Those are the only
  fallbacks — not manual cdk.

## After the deploy

Verify the change is actually live on the prod gateway (hit the new/changed
endpoint), then continue the mission (seeding, follow-up verification, user
report). Authoritative deep-dive: `docs/deploying.md` + `docs/deploy-policy.md`
in `fellowship-dev/pylot`.
