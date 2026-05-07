# Implement

Resume worker to execute the planned tasks.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/04-tasks/handoff.md` | Full file | Session ID, tasks path |
| Shared | `../../shared/worker-dispatch.md` | "Resume" section | How to resume the worker |

## Process

1. Read the tasks handoff. Extract worker session ID.

2. Build resume prompt:
   ```
   Run /speckit-implement $ISSUE to execute all tasks.
   Work through each task in dependency order.
   Commit working code only -- do not commit broken state.
   Report: files changed, any tasks skipped or blocked.
   ```

3. Resume worker per `shared/worker-dispatch.md`.

4. Wait for completion. Read worker log.

5. Extract: files changed count, any blocked tasks, commit status.

6. Write handoff with: session ID, files changed, blocked tasks, implementation status.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Worker completed | Exit code 0 or outcome marker in log |
| Code committed | Worker log shows at least one commit |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Implement handoff | `.procedure-output/speckit-proc/05-implement/handoff.md` | Markdown: session ID, files changed, status |
