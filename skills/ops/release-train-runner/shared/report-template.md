# Local report template (used by stage 07)

Write to `reports/YYYY-MM-DD-release-train-ORG-REPO.md` (replace `/` with `-` in the repo name).
This local file is the ONLY reporting sink — there is no Quest POST.

```markdown
# Release Train: [org/repo] — YYYY-MM-DD

**Date:** YYYY-MM-DD
**Repo:** [org/repo]
**Release PR:** #N — [url]
**Release Branch:** release/YYYY-MM-DD
**Compute:** [Ona env ID / Codespace name]
**Duration:** [X minutes]

## Source PRs

| # | PR | Title | Author | LOC | Merge | Tests | Status |
|---|-----|-------|--------|-----|-------|-------|--------|
| 1 | [#N](url) | Title | @author | +X/-Y | Clean | Pass | Included |
| 2 | [#N](url) | Title | @author | +X/-Y | 2 conflicts | Pass | Included |
| 3 | [#N](url) | Title | @author | +X/-Y | — | Fail | Skipped |

## Conflict Log

### PR #X + PR #Y — `path/to/file`
- Conflict type: [adjacent lines / same function / lockfile]
- Resolution: [description of what was kept/changed]

## Test Results

- After PR #1: PASS
- After PR #2: PASS (2 conflicts resolved)
- After PR #3: FAIL — reverted, skipped
- Final suite: PASS (N examples, M baseline failures)

## Manual Test Plan

[Combined from all included PRs — deduplicated, ordered by workflow area]

## Verdict

Release branch is ready for Max to review and merge.
```
