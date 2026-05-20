# Plan: security-check + security-runner Skills

**Issue:** fellowship-dev/dogfooded-skills#17

## Approach

Create two SKILL.md files following existing ops skill conventions:
- `security-check`: knowledge/strategy (read-only sensor + decision framework)
- `security-runner`: execution procedure (GitHub API + PRs + issues + dismissals)

Both follow the SKILL.md frontmatter + section pattern established by entropy-check, maintenance,
and cto-heartbeat.

## Tasks

1. Write `skills/ops/security-check/SKILL.md` — classification model, decision matrix,
   merge-strategy awareness, ossf/scorecard integration note
2. Write `skills/ops/security-runner/SKILL.md` — step-by-step execution procedure using
   GitHub Dependabot API, PR opening, issue creation, and false-positive dismissal
3. Commit specs/ + skills/

## No app changes needed — this is a pure content/skill addition.
