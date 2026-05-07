# Specify

Spawn the worker and create a feature specification. Answer clarification questions from pre-flight data.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/01-preflight/handoff.md` | Full file | Issue context |
| Shared | `../../shared/worker-dispatch.md` | "First Spawn" section | How to spawn the worker |

## Process

1. Read the pre-flight handoff. Extract issue number, repo, title, and context.

2. Start worker environment if health gate is configured (`/start-worker`).

3. Build worker prompt:
   ```
   You are implementing issue #$ISSUE in $REPO.

   Context from pre-flight:
   $PREFLIGHT_SUMMARY

   First: gather real data. Read the issue references, fetch any URLs, read
   existing code patterns for similar features, inspect dev server if running.

   Then run /speckit-specify $ISSUE to create the feature spec.
   Read the spec. If it has [NEEDS CLARIFICATION] markers, answer them using
   the real data you gathered and run /speckit-clarify $ISSUE.
   Report: spec path, branch name, open questions remaining.
   ```

4. Spawn worker per `shared/worker-dispatch.md` -- first spawn, use `--session-id`.

5. Wait for completion. Read worker log.

6. Extract: spec file path, feature branch name, clarification status.

7. Write handoff with: worker session ID, spec path, branch name, status.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Worker completed | Exit code 0 or outcome marker in log |
| Spec mentioned | Worker log references a spec file path |
| Branch created | Worker is on a feature branch, not default |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Specify handoff | `.procedure-output/speckit-proc/02-specify/handoff.md` | Markdown: session ID, spec path, branch, status |
