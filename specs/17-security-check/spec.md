# Spec: security-check + security-runner Skills

**Issue:** fellowship-dev/dogfooded-skills#17
**Title:** security-check: triage Dependabot/Snyk alerts, classify, and open fix PRs

## Problem

Production repos are accumulating unprocessed security alerts (55+ on one repo, 38+ on another).
Detection is working (GitHub Dependabot + Snyk), but triage and action are missing. Nobody
processes alerts regularly, so risk accumulates silently.

## Scope

Create two new skills in dogfooded-skills:

1. **`skills/ops/security-check/SKILL.md`** — knowledge/strategy skill defining how to think
   about and triage security alerts. Generic, repo-agnostic, reusable across all teams.

2. **`skills/ops/security-runner/SKILL.md`** — execution procedure skill with Pylot-specific
   steps for processing Dependabot/Snyk alerts, opening fix PRs, creating upgrade-path issues,
   and dismissing false positives.

## Classification Model

### Severity × Exploitability Matrix

```
                    | network-reachable | dev-only | test-only
--------------------+-------------------+----------+----------
critical            | P0 — patch now    | P1       | P2
high                | P1 — this week    | P2       | P2
medium              | P2 — batch next   | backlog  | dismiss
low                 | backlog           | dismiss  | dismiss
```

### Decision Outcomes

| Classification | Action |
|---|---|
| P0 (critical + network-reachable) | Open PR immediately; label `security` `P0` |
| P1 (high or critical+dev) | Open PR this week; label `security` `P1` |
| P2 (medium or high+dev) | Batch next monthly cycle; create issue |
| Backlog/dismiss | Dismiss via API with documented reason |

### Auto-patch criteria (safe to open PR without human review)

- Patch-version bump only (e.g., 1.2.3 → 1.2.4)
- No breaking changes in CHANGELOG
- CVE is fixed in the patch (verify via advisory)

### Manual review required

- Minor-version bump (may include API changes)
- Major-version bump (breaking changes likely)
- No patch available (needs code change or workaround)

## Merge Strategy

**CRITICAL:** Never auto-merge on restricted repos. Check `merge_strategy` from crew.yml:
- `auto-merge` repos: safe patches can be auto-merged after CI passes
- `restricted` repos (e.g., Lexgo): apply label `ready-to-merge`, human reviews and merges

## Attribution

When using ossf/scorecard or any OSS tool, credit original authors in the skill.

## Files to Create

- `skills/ops/security-check/SKILL.md`
- `skills/ops/security-runner/SKILL.md`

## Out of Scope

- Actually running security triage against production repos (that's security-runner's job)
- CI integration or workflow file changes
- Changes to any existing skill
