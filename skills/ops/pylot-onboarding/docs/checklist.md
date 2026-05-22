# Pylot Onboarding Checklist

5-step procedure for wiring a new repo to the Pylot booster-pack crew. Follow steps in order — each step is a gate.

---

## Step 1 — Pre-flight: verify `crew.yml`

Read `crew.yml` from the target repo and confirm it exists and defines a `worker_images` block pointing to the correct Pylot worker ECR repository — **not** the app's own Dockerfile or image.

```bash
# Read crew.yml from the target repo (adjust path as needed)
cat crew.yml
```

Look for a block like:

```yaml
worker_images:
  cto: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-cto:latest
  dev: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-dev:latest
  qa: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-qa:latest
  designer: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-designer:latest
```

**Stop here if `crew.yml` is missing or `worker_images` is absent or points to the wrong image.** Add or fix it before proceeding. See [canary.md §Root cause #3](canary.md#root-cause-3--missing-crewyml) for diagnosis when `infra.ops` fails because `crew.yml` is absent.

---

## Step 2 — Build worker images with `ensure-worker.sh`

**This is the most critical step.** The Pylot worker images must be built from `fellowship-dev/pylot`'s `scripts/ensure-worker.sh`, not from anything in the target repo.

**Dispatch to `infra.ops` — never to `infra.dev` (it does not have Docker/ECR access).**

```
Dispatch to: infra.ops
Repo: fellowship-dev/pylot
Task: Run scripts/ensure-worker.sh for <org/repo>.
      Build all four operator families:
        pylot-worker-<org>-<repo>-cto
        pylot-worker-<org>-<repo>-dev
        pylot-worker-<org>-<repo>-qa
        pylot-worker-<org>-<repo>-designer
```

Wait for the job to complete. Verify:
- `status: done`
- `exit_code: 0`
- `input_tokens` is a real number (not null)
- Duration > 30s (under 30s = container crashed before Claude ran)

**Do not proceed to Step 3 until all four operator families report clean signals.**

Per-operator isolation — each operator is a separate ECS task definition family:
- `pylot-worker-<org>-<repo>-cto`
- `pylot-worker-<org>-<repo>-dev`
- `pylot-worker-<org>-<repo>-qa`
- `pylot-worker-<org>-<repo>-designer`

Fixing one does **not** fix the others. Run `ensure-worker.sh` for all four.

---

## Step 3 — Operator canary run

For each of the four operators, dispatch a minimal mission and verify the signals:

```
Dispatch to: booster-pack.<operator>   (cto | dev | qa | designer)
Repo: <org/repo>
Task: Canary check — report the current git HEAD commit hash and confirm you can read the repo.
```

Expected signals for a healthy operator:

| Signal | Expected value |
|--------|---------------|
| `status` | `done` |
| `exit_code` | `0` |
| `input_tokens` | Real number (e.g. 4821) |
| Duration | > 30s |

If any operator returns `input_tokens: null` or `exit_code: 1` with duration < 120s, the worker image is broken. Stop and re-run Step 2 for that specific operator family. See [canary.md](canary.md) for full diagnosis.

---

## Step 4 — Load keychains

Two keychains are always required for booster-pack missions:

| Keychain | Contents |
|----------|---------|
| `booster-pack` | `GH_TOKEN`, `FLY_TOKEN`, `VERCEL_TOKEN` |
| `booster-pack/<org>%2F<repo>` | Repo-specific secrets (URL-encoded slash) |

Load both via the Pylot admin before dispatching any real missions:

```bash
# Example using the Pylot API
curl -X POST "$PYLOT_DISPATCH_URL/keychains/load" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keychain": "booster-pack", "repo": "<org>/<repo>"}'

curl -X POST "$PYLOT_DISPATCH_URL/keychains/load" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keychain": "booster-pack/<org>%2F<repo>", "repo": "<org>/<repo>"}'
```

Verify the keychain contents are present by running a canary mission that reads `$GH_TOKEN` (should be non-empty).

---

## Step 5 — Seed CLAUDE.md with Pylot Ops section

Dispatch `booster-pack.cto` to add a `## Pylot Ops` section to the repo's `CLAUDE.md` documenting the available operators, required keychains, and known CI/deploy commands.

```
Dispatch to: booster-pack.cto
Repo: <org/repo>
Task: Add a "## Pylot Ops" section to CLAUDE.md documenting:
      - Available operators: cto, dev, qa, designer
      - Required keychains: booster-pack, booster-pack/<org>%2F<repo>
      - Known CI command (from package.json or Makefile)
      - Known deploy command (from fly.toml, vercel.json, or equivalent)
      Open a PR for this change.
```

Once the PR is merged, the repo is fully onboarded. All four operators can read CLAUDE.md on any future mission and know how to operate in the repo without additional context.

---

## Completion Checklist

- [ ] `crew.yml` exists with correct `worker_images` ECR paths
- [ ] All four worker image families built successfully (exit 0, non-null `input_tokens`)
- [ ] Canary missions pass for all four operators
- [ ] Both keychains loaded: `booster-pack` and `booster-pack/<org>%2F<repo>`
- [ ] `CLAUDE.md` updated with `## Pylot Ops` section
