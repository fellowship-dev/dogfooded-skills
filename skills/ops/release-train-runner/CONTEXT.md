# release-train-runner — Overview

8-stage FULLY SEQUENTIAL ICM procedure for batching N reviewed PRs into one release branch.

## Purpose

The monolithic release-train-runner ran as a single session. By the time it reached the
later PRs in the train, its context carried the full merge/conflict history of every prior PR,
degrading the conflict-resolution and verdict quality on exactly the steps where judgement
matters most. This procedure isolates the per-PR validate+integrate loop in its own clean-context
stage (stage 03) and partitions setup, push, and teardown into focused stages.

## Why fully sequential (no fan-out)

Each PR merged into the train **changes the conflict surface for every other PR**. A PR that
merges cleanly against the base may conflict once an earlier PR lands. Therefore PRs MUST be
validated and integrated ONE AT A TIME, in the provided merge order, inside a single loop.
Fanning out per-PR subagents would validate each PR against a stale tree and lose the
cross-PR conflict cohesion. Parallelism is explicitly unwanted here — the ICM win is
clean-context isolation of the judgement step, not concurrency.

## Architecture

8 stages, executed strictly one after another. Stages 00 (claim compute) and 07 (report +
outcome marker) run inline in the orchestrator. Stages 01–06 each run as a single Task subagent
with isolated context. No stage ever runs concurrently with another.

## Key invariants

- Stage 00: inline. Claims remote compute (Ona or Codespaces) and fixes `REMOTE_EXEC` /
  `REPO_DIR` for all downstream stages. **All merging happens on remote compute, never locally.**
- Stage 01: read-only analysis — manifest + PR validation + clean checkout. No merges.
- Stage 02: cut the release branch from the default branch.
- Stage 03: the isolated critical-judgement stage. Sequential in-order loop: validate PR →
  `--no-ff` merge → resolve conflicts → run tests → log → next PR. Skip/revert rather than
  break. NEVER fan out.
- Stage 04: regenerate lockfiles only if a merged PR touched deps; re-test. Always runs.
- Stage 05: push the release branch (never force) and open one release PR (never auto-merge it).
- Stage 06: write async trigger notification; release/stop the remote compute.
- Stage 07: inline. Write the local report file, then emit `[pylot] outcome=...` from the
  orchestrator. **No Quest.**

## Folder map

```
SKILL.md             — invocation reference and execution logic
CONTEXT.md           — this file
shared/              — release-pr-template.md, report-template.md, test-commands.md
stages/00-07/        — CONTEXT.md + output/ per stage
```

## Runtime handoff path

```
.procedure-output/release-train-runner/{stage}/handoff.md
```

Written at runtime in the repo working directory (not inside the skill directory).

## Emit on completion

- Success: `[pylot] outcome="release train ready: N PRs merged into release/YYYY-MM-DD" status=success`
- Failure: `[pylot] outcome="release-train failed at stage NN: {reason}" status=failed`
- Blocked: `[pylot] outcome="release-train blocked: {reason}" status=blocked`
