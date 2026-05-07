# Pre-flight

Gather all context needed before writing a single line of code. Real data eliminates guesswork.

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

3. Ensure `in-progress` label exists on the repo:
   ```bash
   gh label create "in-progress" --repo $1 --color "FBCA04" 2>/dev/null || true
   ```

4. Read issue comments -- may contain clarifying Q&A from humans.

5. Identify every URL, file path, data source, and API the issue references.

6. Gather real data from the repo and live services:
   - If scraping needed: fetch target pages, extract real CSS selectors
   - If APIs needed: curl real endpoints, document request/response shapes
   - If data needed: get real samples, not fabricated examples
   - Read existing code patterns for similar features in the repo
   - If dev server running (`curl -sf localhost:1337/_health` or `localhost:3000`): inspect real responses

7. If issue has `bugsnag` label: run dedup check per `references/bugsnag-dedup.md`.

8. Write pre-flight report with: issue metadata, real data findings, dedup decision.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Issue accessible | `gh issue view` returns valid JSON, state is OPEN |
| Real data gathered | Report contains at least one concrete data point from the repo or live services |
| Dedup decided | If bugsnag: explicit proceed/dup/link decision. Otherwise: N/A |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Pre-flight report | `.procedure-output/speckit-proc/01-preflight/report.md` | Markdown: issue metadata, real data findings, dedup decision |
