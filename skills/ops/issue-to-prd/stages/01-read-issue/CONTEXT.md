# Stage 01: Read Issue

## Inputs
- Issue number + repo (from invocation)

## Task
Fetch the full issue and return raw data for downstream stages.

## Steps
1. Run: `gh issue view {number} --repo {repo} --json number,title,body,labels,comments,state`
2. Write output to `stages/01-read-issue/output/handoff.md`

## Output: handoff.md
```markdown
# Issue #{number}: {title}

## Labels
{labels}

## State
{state}

## Body
{body}

## Comments
{comments}
```

## Success criteria
- handoff.md exists and contains title, body, labels, and all comments
- No interpretation — raw data only
