# Implement

Execute the planned tasks and verify with tests.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/03-plan/result.md` | Full file | Plan and tasks paths |
| Reference | `references/test-verification.md` | Full file | How to verify the implementation |

## Process

1. Read the plan output. Confirm plan and tasks files exist on disk.

2. Run the implement phase:
   ```
   /speckit-implement $ISSUE
   ```

3. Run the project's test suite. See `references/test-verification.md` for how to discover and run tests.

4. If a dev server is available, verify affected pages/APIs return correct responses.

5. Fix any test failures before proceeding. Commit only working code.

6. Write implementation output: files changed count, test results summary, issues encountered.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Tests pass | Test suite exits 0 |
| Code committed | All implementation changes committed to the feature branch |
| No broken imports | No new compilation or import errors introduced |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Implementation result | `.procedure-output/speckit-proc/04-implement/result.md` | Markdown: files changed, test results, issues |
