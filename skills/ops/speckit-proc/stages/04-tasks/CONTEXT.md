# Tasks

Resume worker to break the plan into atomic, dependency-ordered tasks.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/03-plan/handoff.md` | Full file | Session ID, plan path |
| Shared | `../../shared/worker-dispatch.md` | "Resume" section | How to resume the worker |

## Process

1. Read the plan handoff. Extract worker session ID.

2. Build resume prompt:
   ```
   Run /speckit-tasks $ISSUE to break the plan into atomic tasks.
   Read the tasks file. Verify each task is concrete and implementable.
   Report: tasks path, task count, any tasks that seem too large or vague.
   ```

3. Resume worker per `shared/worker-dispatch.md`.

4. Wait for completion. Read worker log.

5. Extract: tasks file path, task count.

6. Write handoff with: session ID, tasks path, task count.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Worker completed | Exit code 0 or outcome marker in log |
| Tasks created | Worker log references a tasks file path |
| Tasks are atomic | Task count > 0 and no single task spans multiple concerns |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Tasks handoff | `.procedure-output/speckit-proc/04-tasks/handoff.md` | Markdown: session ID, tasks path, task count |
