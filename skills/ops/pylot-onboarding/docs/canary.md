# Diagnosing Worker Image Failures

Use this doc when a booster-pack mission returns unexpected signals. All three root causes produce similar surface symptoms — the signal table below distinguishes them.

---

## Failure Signal Table

| Signal | Value | Meaning |
|--------|-------|---------|
| `input_tokens` | `null` | Container crashed before Claude ran — the image is broken |
| `input_tokens` | Real number | Claude ran — failure is in the task, not the image |
| `exit_code` | `1` + duration ~60–120s | Worker image is broken (wrong Docker image or crash on boot) |
| `exit_code` | `1` + duration > 5 min | Task failed after Claude ran — check mission logs |
| `status` | `done` | Job completed (check `exit_code` and `input_tokens` separately) |
| `status` | `failed` | Job did not complete — likely infra-level failure |

**The critical discriminator is `input_tokens`.** Null = container crashed before Claude ran. Non-null = Claude ran; the failure is in the mission content, not the image.

---

## Root Cause #1 — Wrong Dockerfile built

A previous `infra.ops` job built the target repo's **app Dockerfile** (e.g., a Next.js or Rails Dockerfile) and pushed it to the `pylot-worker-*` ECR repository. The container starts, fails to launch a Claude agent, and exits in ~60–120s.

### Diagnosis

| Signal | Value |
|--------|-------|
| `input_tokens` | `null` |
| `exit_code` | `1` |
| Duration | 60–120s |
| Operator | One or more (whichever had `ensure-worker.sh` run against the wrong Dockerfile) |

To confirm, check the ECR image tag timestamp against the `infra.ops` job that ran most recently. If the image was pushed at the same time as an app build job, this is the cause.

### Fix

Re-run `ensure-worker.sh` from `fellowship-dev/pylot` via `infra.ops` for the affected operator family:

```
Dispatch to: infra.ops
Repo: fellowship-dev/pylot
Task: Run scripts/ensure-worker.sh for <org/repo>, operator family: <operator>.
      This rebuilds the correct Pylot worker image and pushes it to ECR.
```

Do **not** try to patch the ECS task definition manually — `ensure-worker.sh` handles the full image build, push, and task definition update.

After the job completes (exit 0), re-run the canary mission for the affected operator.

---

## Root Cause #2 — Per-operator task def not patched

`booster-pack.cto` works (or one operator works) but `booster-pack.dev`, `.qa`, or `.designer` still fail with `input_tokens: null`. This happens when `ensure-worker.sh` was run for only one operator family, leaving the others pointing at a stale or wrong image.

### Diagnosis

| Signal | Value |
|--------|-------|
| `input_tokens` | `null` on `.dev`, `.qa`, or `.designer` |
| `input_tokens` | Real number on `.cto` (or whichever was fixed) |
| `exit_code` | `1` on the failing operators |
| Duration | 60–120s on the failing operators |

Each operator maps to its own ECS task definition family:
- `pylot-worker-<org>-<repo>-cto`
- `pylot-worker-<org>-<repo>-dev`
- `pylot-worker-<org>-<repo>-qa`
- `pylot-worker-<org>-<repo>-designer`

Updating one task definition does not propagate to the others.

### Fix

Run `ensure-worker.sh` for each failing operator family independently:

```
Dispatch to: infra.ops
Repo: fellowship-dev/pylot
Task: Run scripts/ensure-worker.sh for <org/repo>.
      Target each failing operator family separately:
        pylot-worker-<org>-<repo>-dev
        pylot-worker-<org>-<repo>-qa
        pylot-worker-<org>-<repo>-designer
```

Run the canary for each operator after the job completes. Do not assume that fixing two fixes the third — verify each one.

---

## Root Cause #3 — Missing `crew.yml`

`infra.ops` fails when running `ensure-worker.sh` because the target repo has no `crew.yml` defining the `worker_images` block. Without it, `ensure-worker.sh` cannot determine which ECR repositories to build for.

### Diagnosis

| Signal | Value |
|--------|-------|
| `infra.ops` job | `exit_code: 1` early in the run |
| Error message | "crew.yml not found" or "worker_images undefined" |
| `input_tokens` | Non-null (infra.ops itself ran; it was the `ensure-worker.sh` script that failed) |

This failure happens at Step 2 of the checklist, not during a booster-pack canary.

### Fix

Add `crew.yml` to the target repo with the correct `worker_images` block:

```yaml
worker_images:
  cto: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-cto:latest
  dev: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-dev:latest
  qa: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-qa:latest
  designer: 123456789.dkr.ecr.us-east-1.amazonaws.com/pylot-worker-<org>-<repo>-designer:latest
```

Replace `<org>`, `<repo>`, and the AWS account ID with the correct values. Commit and push the file, then re-run Step 2 of the [onboarding checklist](checklist.md#step-2--build-worker-images-with-ensure-workersh).

---

## Quick Decision Tree

```
Canary fails →
  input_tokens null?
    yes → duration ~60–120s?
      yes → Root Cause #1 or #2 (wrong image)
        All operators failing? → Root Cause #1 (wrong Dockerfile built for all)
        Only some operators?  → Root Cause #2 (per-operator task def not patched)
      no  → infra-level failure; check Fargate task logs
    no  → Claude ran; check mission output for task-level error
        → Not an image issue

ensure-worker.sh fails →
  crew.yml missing or no worker_images? → Root Cause #3
```
