# Test

Resume worker to run the project's test suite and fix any failures.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/05-implement/handoff.md` | Full file | Session ID, implementation status |
| Shared | `../../shared/worker-dispatch.md` | "Resume" section | How to resume the worker |

## Process

1. Read the implement handoff. Extract worker session ID.

2. Build resume prompt:
   ```
   Run the project's test suite. Find the test command from package.json,
   Gemfile, Makefile, or equivalent.
   If a dev server is running, also verify affected pages/APIs respond correctly.
   Fix any test failures caused by your changes.
   Do NOT skip or ignore failing tests -- fix them.
   Report: test command used, pass/fail count, what you fixed.
   ```

3. Resume worker per `shared/worker-dispatch.md`.

4. Wait for completion. Read worker log.

5. Extract: test results (pass/fail), fixes applied, final test status.

6. Write handoff with: session ID, test command, results, fixes, final status.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Worker completed | Exit code 0 or outcome marker in log |
| Tests ran | Worker log shows test command execution |
| Tests pass | Final test run exits 0 (or worker explicitly reports all green) |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Test handoff | `.procedure-output/speckit-proc/06-test/handoff.md` | Markdown: session ID, test results, fixes, status |
