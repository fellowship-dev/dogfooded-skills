# Local Report-File Template (lifted verbatim from deps-runner)

Written by stage 06 to `reports/YYYY-MM-DD-deps-REPO-BRANCH.md` (replace `/` with `-` in the
repo name; one file per dependency PR processed, using the full branch name of each PR).
The file MUST start with the source PRs that were picked up.

**No Quest.** This local file is the only output. Operators surface it via the mission
report. Do NOT POST it anywhere.

```markdown
# Deps Run: [org/repo]

**Date:** YYYY-MM-DD
**Repo:** [org/repo]
**Ona Environment:** [ENV_ID]
**Baseline:** [N tests passing on main, build time]

## Source PRs

| PR | Title | Author | Created | Age |
|----|-------|--------|---------|-----|
| #N | [title] | @[bot] | YYYY-MM-DD | [N days] |
| ... | ... | ... | ... | ... |

[Total: N PRs picked up for processing]

## Pre-Flight

- **Main branch:** [compiles: yes/no, tests: N passing / N failing]
- **Environment health:** [services running, database seeded]
- **Booster sync:** [synced / skipped (no booster remote) / conflict-aborted — issue filed]
- **Blockers:** [any issues found before starting]

## Results Per PR

### PR #N -- [title]

- **Package:** [name] [old] -> [new] ([bump type])
- **Dep type:** [runtime / devDep / transitive]
- **Direct usage:** [yes (N files) / no]
- **Risk:** [low/medium/high]
- **Build:** [pass / fail -- error summary if failed]
- **Tests:** [pass (N/N) / fail -- failure summary]
- **Action:** [auto-merged / flagged for Max / needs tests / blocked]
- **Notes:** [any issues encountered]

[Repeat for each PR processed]

## Summary

Merged [skip ci]:
- #N [package] [old]->[new] ([risk] [dep type])

Needs Max (with tests written):
- #N [package] [old]->[new] ([risk], new test at [path])

Needs Max (complex/failed):
- #N [package] [old]->[new] ([risk], [reason])

Skipped:
- #N [package] -- [reason skipped]

## Lessons

[Anything new learned -- dependency gotchas, environment issues, patterns to add]
```
