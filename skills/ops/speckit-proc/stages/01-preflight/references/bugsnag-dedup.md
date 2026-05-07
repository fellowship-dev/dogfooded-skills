# Bugsnag Dedup Check

Only run this when the issue has a `bugsnag` label. Skip for feature requests.

## Process

1. Extract error signature from the issue body: error class, method name, file path.

2. Search open PRs for existing fixes:
   ```bash
   gh pr list --repo $1 --state open --json number,title,headRefName,body --limit 100
   ```

3. Search recently merged PRs (last 30 days):
   ```bash
   gh pr list --repo $1 --state merged --json number,title,mergedAt,body --limit 50
   ```

4. Search open issues for duplicates:
   ```bash
   gh issue list --repo $1 --state open --label bugsnag --json number,title,body --limit 50
   ```

5. Match the error signature against PR titles, bodies, and branch names.

## Decision Matrix

| Finding | Action |
|---------|--------|
| Confident duplicate (same error, open PR exists) | Close as duplicate, link to existing PR/issue. **Stop.** |
| Related but not identical error | Link bidirectionally, proceed with speckit |
| Partial fix exists (merged PR, error persists) | Link merged PR, note what is still broken, proceed |
| No matches or uncertain | Proceed with speckit |
