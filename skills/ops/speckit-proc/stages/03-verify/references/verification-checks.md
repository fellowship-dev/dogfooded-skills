# Verification Checks

Detailed procedures for each verification gate.

## PR Existence

```bash
PR_JSON=$(gh pr view $PR --repo $REPO --json state,title,body,headRefName,url)
```

- State must be OPEN
- headRefName must match expected branch from implementation output

## CI Status

```bash
gh pr checks $PR --repo $REPO
```

- All required checks must pass
- If checks are still running, poll every 30s up to 5 minutes
- Record which checks failed (if any)

## Issue Linkage

The PR body must contain one of:
- `#ISSUE_NUMBER` (e.g., `#42`)
- Full issue URL (e.g., `https://github.com/org/repo/issues/42`)
- `Closes #ISSUE_NUMBER` or `Fixes #ISSUE_NUMBER`

## Spec Files

```bash
gh pr diff $PR --repo $REPO --name-only | grep "^specs/"
```

Expected files under `specs/`:
- `spec.md` -- feature specification
- `plan.md` -- implementation plan
- `tasks.md` -- atomic task list

At minimum, `spec.md` must exist.

## Outcome Decision

| Result | Outcome Marker |
|--------|---------------|
| All checks pass | `[pylot] outcome="speckit-proc complete: PR #N ready" status=success` |
| PR exists, CI fails | `[pylot] outcome="speckit-proc partial: PR #N failing checks" status=partial` |
| PR exists, no specs | `[pylot] outcome="speckit-proc partial: PR #N missing specs" status=partial` |
| No PR created | `[pylot] outcome="speckit-proc failed: no PR" status=failed` |
