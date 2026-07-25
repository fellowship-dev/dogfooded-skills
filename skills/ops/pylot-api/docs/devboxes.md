# Devboxes (Fargate Projects)

## List Devboxes Projects

```bash
curl -sS -H "Authorization: Bearer $PYLOT_API_TOKEN" "$PYLOT_GATEWAY_URL/devboxes/projects"
```

Returns Fargate environments: cluster, task definition families, environment variables, and current task status.

## Task Definitions

Task definitions are resolved per-operator from team config (Aurora) worker_images. Each project maps to an ECS cluster + task definition family. The `ensure-operator-taskdef.sh` and `ensure-worker.sh` scripts manage lifecycle — see the repo's `scripts/` directory.

## Local Override

Pass `"local": true` in a dispatch payload to skip Fargate and run the operator process on the gateway host — use for gateway restarts and host-level ops only.
