---
name: pylot-onboarding
description: Checklist-driven worker setup for onboarding a new repo to the Pylot booster-pack crew. Encodes the correct 5-step procedure and failure-mode diagnosis to prevent trial-and-error.
user-invocable: true
allowed-tools: Read, Bash
---

# pylot-onboarding

Onboard a repo to the Pylot booster-pack crew in one session, without trial-and-error.

**Why this skill exists:** Onboarding Lexgo-cl/lexgo-website burned 5+ hours because `infra.ops` silently built the app's Next.js Dockerfile and pushed it to the Pylot worker ECR repo. Symptoms were non-obvious (`input_tokens: null`, `exit_code: 1`, 60–120s runtimes). This skill encodes the correct procedure and all known failure modes so the next repo doesn't repeat that.

## Invocation

```
/pylot-onboarding <org/repo>
```

Example: `/pylot-onboarding Lexgo-cl/lexgo-website`

## 5-Step Summary

| Step | Name | What happens |
|------|------|-------------|
| 1 | [Pre-flight](docs/checklist.md#step-1--pre-flight-verify-crewyml) | Read `crew.yml` — confirm `worker_images` points to the correct ECR path, not the app Dockerfile |
| 2 | [Build worker images](docs/checklist.md#step-2--build-worker-images-with-ensure-workersh) | Dispatch `ensure-worker.sh` via `infra.ops` from `fellowship-dev/pylot` for all four operator families |
| 3 | [Operator canary](docs/checklist.md#step-3--operator-canary-run) | Dispatch a minimal mission to each operator; confirm `status: done`, `exit_code: 0`, non-null `input_tokens` |
| 4 | [Load keychains](docs/checklist.md#step-4--load-keychains) | Load `booster-pack` and `booster-pack/<org>%2F<repo>` keychains |
| 5 | [Seed CLAUDE.md](docs/checklist.md#step-5--seed-claudemd-with-pylot-ops-section) | Dispatch `booster-pack.cto` to add a `## Pylot Ops` section documenting operators, keychains, and CI commands |

**Do not proceed past Step 2 until the canary signals are clean.** If any operator fails with `input_tokens: null` or `exit_code: 1` in under 120s, see [docs/canary.md](docs/canary.md) before continuing.

## Critical Rules

1. **Never dispatch booster-pack missions until Step 2 exits 0 with non-null `input_tokens`.**
2. **Step 2 must dispatch to `infra.ops` in `fellowship-dev/pylot` — never build from anything in the target repo.**
3. **Each operator has its own ECS task definition family — fixing one does not fix the others.**
4. **`input_tokens: null` means the container crashed before Claude ran — do not retry the mission, fix the image first.**
