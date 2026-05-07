# PR Template

## Title Convention

- `fix:` for bug fixes
- `feat:` for new features
- `chore:` for maintenance
- Always include `(#ISSUE_NUMBER)` at the end

## Body Format

```markdown
## What
<1-2 sentence summary of the change>

## Why
Closes #ISSUE_NUMBER
<Brief context from the issue>

## How
<Technical approach -- what was changed and why that approach>

## Testing
<What was tested, how, and results>
```

## Visual Evidence (Optional)

Skip for: backend-only, CLI-only, test-only, or no-UI-impact changes.

If the change has UI impact and time permits (120s hard timeout):
- Screenshot before/after states
- Upload to S3 if `AWS_BUCKET` is set
- Embed image URLs in the PR body
