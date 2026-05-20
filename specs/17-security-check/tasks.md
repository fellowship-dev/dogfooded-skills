# Tasks: security-check + security-runner Skills

**Issue:** fellowship-dev/dogfooded-skills#17

## Task 1: Create security-check skill

File: `skills/ops/security-check/SKILL.md`

Content requirements:
- Frontmatter: name, description, user-invocable, allowed-tools
- Classification: severity × exploitability matrix
- Decision matrix with action per quadrant
- Auto-patch vs manual-review criteria
- Merge-strategy awareness (auto vs restricted repos)
- ossf/scorecard integration guidance (credit OSS tools)
- Cron suggestion for weekly runs

## Task 2: Create security-runner skill

File: `skills/ops/security-runner/SKILL.md`

Content requirements:
- Frontmatter: name, description, argument-hint, user-invocable, allowed-tools
- Step 0: Target repo + auth setup
- Step 1: Fetch all open Dependabot alerts via GitHub API
- Step 2: Classify each alert using security-check decision matrix
- Step 3: For safe patches — open PR via `gh` (or verify existing Dependabot PR)
- Step 4: For breaking changes — create issue with upgrade path analysis
- Step 5: For false positives — dismiss via API with reason
- Step 6: Output summary report

## Task 3: Commit all files

- `specs/17-security-check/spec.md`
- `specs/17-security-check/plan.md`
- `specs/17-security-check/tasks.md`
- `skills/ops/security-check/SKILL.md`
- `skills/ops/security-runner/SKILL.md`
