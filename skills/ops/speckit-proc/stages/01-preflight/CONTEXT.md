# Pre-flight

Gather all context needed before touching code. Operator-only -- no worker needed.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Argument | `$0` | Issue number | Target issue |
| Argument | `$1` | Org/repo | Target repository |
| Reference | `references/bugsnag-dedup.md` | Full file | Dedup logic for bugsnag-labeled issues |

## Process

1. Check if the issue is already CLOSED:
   ```bash
   ISSUE_STATE=$(gh issue view $0 --repo $1 --json state --jq '.state')
   ```
   If CLOSED: emit `[pylot] outcome="already complete -- issue is CLOSED" status=success` and stop.

2. Fetch issue details:
   ```bash
   gh issue view $0 --repo $1 --json title,body,labels,comments
   ```

3. Ensure `in-progress` label exists:
   ```bash
   gh label create "in-progress" --repo $1 --color "FBCA04" 2>/dev/null || true
   ```

4. Read issue comments for clarifying Q&A.

5. Identify every URL, file path, data source, and API the issue references.

6. If issue has `bugsnag` label: run dedup check per `references/bugsnag-dedup.md`. If confident duplicate: close issue, link, emit `status=success`, stop.

7. Write handoff with: issue title, body, labels, comments summary, referenced resources, dedup decision.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Issue accessible | `gh issue view` returns valid JSON, state is OPEN |
| Dedup decided | If bugsnag: explicit proceed/dup/link decision. Otherwise: N/A |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Pre-flight handoff | `.procedure-output/speckit-proc/01-preflight/handoff.md` | Markdown: issue metadata, resources, dedup decision |
