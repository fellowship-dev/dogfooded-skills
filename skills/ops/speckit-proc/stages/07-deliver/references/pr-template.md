# PR Template

## Title Convention

- `fix:` for bug fixes
- `feat:` for new features
- `chore:` for maintenance
- Always include `(#ISSUE_NUMBER)` at the end

## Body Format

```markdown
## What
<1-2 sentence summary>

## Why
Closes #ISSUE_NUMBER
<Brief context from the issue>

## How
<Technical approach>

## Testing
<What was tested and results>
```

## Visual Evidence (Optional)

Skip for: backend-only, CLI-only, test-only changes.

If the change has UI impact (120s hard timeout):
- Screenshot before/after
- Upload to S3 if `AWS_BUCKET` is set
- Embed URLs in PR body
