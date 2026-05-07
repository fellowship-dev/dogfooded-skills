# Specify

Create a feature specification from the issue and pre-flight data. Answer any clarification questions.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/01-preflight/report.md` | Full file | Issue context and real data |

## Process

1. Read the pre-flight report.

2. Checkout the default branch and pull latest:
   ```bash
   git checkout $(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@') && git pull
   ```

3. Run the specify phase:
   ```
   /speckit-specify $ISSUE
   ```
   This creates `specs/{issue-slug}/spec.md` and a feature branch.

4. Read the generated spec. Check for `[NEEDS CLARIFICATION]` markers.

5. If clarification questions exist, answer them using the real data gathered in pre-flight:
   ```
   /speckit-clarify $ISSUE
   ```

6. Record the feature branch:
   ```bash
   git branch --show-current
   ```
   Do NOT pre-create branches -- specify creates them.

7. Write specify output: spec file path, branch name, whether clarifications were needed.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Spec exists | `specs/{issue-slug}/spec.md` is present and non-empty |
| Under line limit | Spec file is 50 lines or fewer |
| No open questions | No remaining `[NEEDS CLARIFICATION]` markers |
| Feature branch | Not on the default branch |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Specify result | `.procedure-output/speckit-proc/02-specify/result.md` | Markdown: spec path, branch name, clarification status |
