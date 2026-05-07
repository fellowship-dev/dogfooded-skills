# Bugsnag Dedup Check

Only run when the issue has a `bugsnag` label. Skip for feature requests.

## Process

1. Extract error signature from issue body: error class, method name, file path.

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

5. Match error signature against PR titles, bodies, and branch names.

## Decision Matrix

| Finding | Action |
|---------|--------|
| Confident duplicate (same error, open PR) | Close as duplicate, link. **Stop.** |
| Related but not identical | Link bidirectionally, proceed |
| Partial fix exists (merged PR) | Link, note what is still broken, proceed |
| No matches or uncertain | Proceed |
