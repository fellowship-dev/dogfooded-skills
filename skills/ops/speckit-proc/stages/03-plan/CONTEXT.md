# Plan

Resume worker to design the implementation approach.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/02-specify/handoff.md` | Full file | Session ID, spec path |
| Shared | `../../shared/worker-dispatch.md` | "Resume" section | How to resume the worker |

## Process

1. Read the specify handoff. Extract worker session ID.

2. Build resume prompt:
   ```
   Read the spec at $SPEC_PATH. Verify it makes sense given the codebase.
   Run /speckit-plan $ISSUE to create the implementation plan.
   Read the plan. Verify the approach is sound.
   Report: plan path, any concerns about the approach.
   ```

3. Resume worker per `shared/worker-dispatch.md` -- use `--resume` with session ID from handoff.

4. Wait for completion. Read worker log.

5. Extract: plan file path, any concerns flagged.

6. Write handoff with: session ID, plan path, concerns.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Worker completed | Exit code 0 or outcome marker in log |
| Plan created | Worker log references a plan file path |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Plan handoff | `.procedure-output/speckit-proc/03-plan/handoff.md` | Markdown: session ID, plan path, concerns |
