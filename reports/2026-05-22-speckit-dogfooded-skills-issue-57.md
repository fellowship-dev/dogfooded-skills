# Pre-flight Report — dogfooded-skills issue #57

**Source issue:** https://github.com/fellowship-dev/dogfooded-skills/issues/57
**Date:** 2026-05-22
**Title:** feat(skills): pylot-onboarding — checklist-driven worker setup for new repos

## Issue Summary

Onboarding Lexgo-cl/lexgo-website to the Pylot booster-pack crew burned 5+ hours because an `infra.ops` job (1779423226) built the app's Next.js Dockerfile and pushed it to the Pylot worker ECR repo. Symptoms were non-obvious: `input_tokens: null`, `exit_code: 1`, 60–120s runtimes across all 4 operators.

The fix is a new `pylot-onboarding` skill encoding the correct procedure and all failure modes.

## Deliverables

- `skills/ops/pylot-onboarding/SKILL.md` — invocation docs with 5-step summary
- `skills/ops/pylot-onboarding/docs/checklist.md` — 5-step onboarding procedure
- `skills/ops/pylot-onboarding/docs/canary.md` — 3 failure mode diagnosis + fix

## Repo Structure Decision

Issue spec shows `skills/pylot-onboarding/` as sibling to `pylot-api/` and `vercel-deploy/`. Actual repo places all operational skills under `skills/ops/`. Placed new skill at `skills/ops/pylot-onboarding/` to match existing convention (vercel-deploy, fly-io, popsicle all live under `skills/ops/`).

## No Questions / Blockers

Issue body is exhaustive and contains all content needed. No clarification required.
