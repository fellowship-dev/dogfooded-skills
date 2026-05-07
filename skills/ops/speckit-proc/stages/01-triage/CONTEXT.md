# Triage

Fetch issue metadata from GitHub, check for duplicates, decide whether to proceed.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Argument | `$0` | Issue number | Target issue to implement |
| Argument | `$1` | Org/repo | Target repository |
| Reference | `references/bugsnag-dedup.md` | Full file | Dedup procedure for bugsnag-labeled issues |

## Process

1. Check if the issue is already CLOSED:
   ```bash
   ISSUE_STATE=$(gh issue view $0 --repo $1 --json state --jq '.state')
   ```
   If CLOSED: emit `[pylot] outcome="already complete -- issue is CLOSED" status=success` and stop.

2. Fetch full issue details:
   ```bash
   gh issue view $0 --repo $1 --json title,body,labels,comments
   ```

3. Ensure `in-progress` label exists on the repo:
   ```bash
   gh label create "in-progress" --repo $1 --color "FBCA04" 2>/dev/null || true
   ```

4. If the issue has a `bugsnag` label, follow the dedup procedure in `references/bugsnag-dedup.md`. Record decision: proceed, close-as-dup (stop), or link-and-proceed.

5. Write triage output with: issue title, body summary, labels, key comments, and dedup decision.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Issue accessible | `gh issue view` returns valid JSON, state is OPEN |
| Dedup decision recorded | Output explicitly states proceed, close-as-dup, or link-and-proceed |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Triage report | `.procedure-output/speckit-proc/01-triage/triage.md` | Markdown: title, body summary, labels, comments, dedup decision |
