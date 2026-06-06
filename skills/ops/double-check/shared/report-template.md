# Local Report File Template

Used by stage 04 to write the local review report. Lifted verbatim from the original
`double-check` skill (Step 9). The Quest POST that followed this in the original is removed —
this report file is the only report sink.

Path:
```bash
REPORT_FILE="reports/$(date +%Y-%m-%d)-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

Format:
```markdown
# Review: $REPO PR #$PR — $PR_TITLE

**Date:** YYYY-MM-DD
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL) — $PR_TITLE
**Branch:** `$PR_BRANCH` -> `$BASE_BRANCH`

## Source PR

[PR body verbatim]

## Intent

[What problem this solves]

## Implementation

- [Key approach and decisions]

## Curated CI Findings

[Findings table]

## Tests After Fixes

[Pass/fail results]

## Verdict

[Ready for merge / Needs fixes]
```

- For Pylot/crew-based runs the report goes to `$(git rev-parse --show-toplevel)/reports/`.
- For deps-only PRs (Dependabot, lockfile-only), tests may be skipped — note this explicitly.
- NO Quest POST. Do not call any Quest endpoint, `127.0.0.1:4242`, or `quest.fellowship.dev`.
