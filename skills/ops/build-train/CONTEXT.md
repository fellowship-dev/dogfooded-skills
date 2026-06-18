# build-train — Overview

6-stage ICM procedure that batches multiple GitHub issues into a single build branch, then ships
one final PR through the review pipeline once instead of N times.

## Purpose

The monolithic `build-train` ran as one long `claude -p` session: setup → dispatch workers →
verify → merge → final PR → report. By the merge phase the session context held every worker
prompt and every worker log, polluting the critical conflict-resolution and verification
judgement. Worse, its worker loop was effectively serial ("spawn one, wait, spawn next" at
concurrency 1), wasting wall-clock on independent builds.

This proc fixes both problems:
- Each phase is an isolated subagent with focused context.
- The dispatch phase (stage 02) becomes a **dependency-graph wave scheduler** that runs
  independent builds concurrently and only serializes across real dependency edges.

## Architecture

6 stages. Stages 00 and 05 run inline in the orchestrator (no Task spawn). Stages 01–04 each run
as a Task subagent with isolated context.

Stage 02 is special: it is itself a fan-out controller. It reads the build order (a list of waves)
from stage 01 and, per wave, launches all of that wave's builds as concurrent Task workers in a
single response. It awaits the whole wave, then proceeds to the next wave. This is where the
parallelism lives — parallel within a wave, sequential across dependency edges.

## Dependency-graph fan-out (the key design, issue #1020)

Stage 01 produces a DAG over the batched issues and topologically sorts it into **waves**:
- Wave 1 = all issues with no unmet dependency.
- Wave k = all issues whose dependencies were all satisfied by waves 1..k-1.

A dependency edge exists when one issue's build must consume another's output — shared
migration/schema, a package built upstream, a generated artifact, a file both touch, or an
explicit "depends on #N" / "blocked by #N" in the issue body. Independent issues share a wave and
build concurrently; dependent issues fall into later waves and build sequentially relative to
their prerequisite.

Stage 02 executes the waves: for each wave it fires N parallel build Task workers (one per issue),
waits for all of them, verifies/fixes each PR's base + label, writes a per-build sub-handoff, then
advances. A build with a failed prerequisite is skipped (skip-rather-than-break) and its dependents
are skipped too (cannot consume missing output).

## Key invariants

- Stage 00: inline, side-effecting setup (creates build branch + label). Establishes shared
  context and the issue manifest. Blocks if a `build/*` train already exists.
- Stage 01: pure analysis — derives the DAG and waves. No side effects. Critical-judgement stage:
  a wrong dependency edge either over-serializes (slow) or races (broken build), so it is isolated
  in clean context.
- Stage 02: the only stage that spawns build workers; parallel within waves, sequential across edges.
- Stage 03: merges PRs into the build branch; resolves conflicts.
- Stage 04: opens the single final PR (no build-train label) → enters review pipeline.

## Folder map

```
SKILL.md             — invocation reference and execution logic
CONTEXT.md           — this file
stages/00-05/        — CONTEXT.md per stage
```

## Runtime handoff path

```
.procedure-output/build-train/{stage}/handoff.md
.procedure-output/build-train/02-build-fanout/builds/{issue}.md   — per-build sub-handoffs
```

Written at runtime in the repo working directory (not inside the skill directory).

## Emit on completion

