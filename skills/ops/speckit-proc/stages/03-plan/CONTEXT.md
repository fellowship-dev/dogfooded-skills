# Plan

Design the implementation approach and break it into atomic, dependency-ordered tasks.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/02-specify/result.md` | Full file | Spec path and branch name |

## Process

1. Read the specify output. Confirm you are on the feature branch.

2. Run the plan phase:
   ```
   /speckit-plan $ISSUE
   ```

3. Read `specs/{issue-slug}/plan.md`. Verify the approach makes sense given the codebase.

4. Run the tasks phase:
   ```
   /speckit-tasks $ISSUE
   ```

5. Read `specs/{issue-slug}/tasks.md`. Verify tasks are concrete, atomic, and implementable.

6. Write plan output: plan path, tasks path, task count, any concerns about the approach.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Plan exists | `specs/{issue-slug}/plan.md` is present, 60 lines or fewer |
| Tasks exist | `specs/{issue-slug}/tasks.md` has at least one task |
| Tasks are atomic | Each task describes a single, concrete action |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Plan result | `.procedure-output/speckit-proc/03-plan/result.md` | Markdown: plan path, tasks path, task count, concerns |
