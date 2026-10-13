# Stage 01: Read Issue

## Inputs
- Issue number, plus either a repo (`org/repo`) or the issue text supplied in the prompt

## Task
Capture the full issue as raw data for the downstream stages. Read only; never write to GitHub.

## Steps
1. If `gh` can read the repo, run
   `gh issue view {number} --repo {repo} --json number,title,body,labels,comments,state,url`.
   Otherwise use the issue title, body and comments given in the prompt. In a devbox with no
   GitHub access, the prompt is the only source; do not go looking for other refs.
2. If `specs/{number}-*/spec.md` already exists in the repo, read it too and copy its
   `## Questions for the owner` answers (if any) into the handoff. Those answers are owner
   decisions and outrank anything inferred later.
3. Write the result to `$WORK/01-read-issue.md`.

## Output: `$WORK/01-read-issue.md`
```markdown
# Issue #{number}: {title}

## Source
{issue URL, or "supplied in prompt"}

## Labels / State
{labels} / {state}

## Body
{body}

## Comments
{comments}

## Prior spec and owner answers
{path and answers, or "none"}
```

## Success criteria
- The handoff contains title, body and every comment, verbatim
- No interpretation; raw data only
- No GitHub writes and no interactive prompts
