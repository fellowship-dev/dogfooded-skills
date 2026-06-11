---
name: security-check
description: Use when triaging Dependabot/Snyk security alerts by severity and exploitability before running security-runner.
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep
---

# security-check

Knowledge/strategy skill for security alert triage. Classifies, prioritizes, and prescribes action.
**Does not open PRs or modify repos.** For execution, use `/security-runner`.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/skills/ops/security-check
```

## When to Use

- Before running `/security-runner` on a repo to understand what actions to expect
- When manually reviewing a batch of Dependabot/Snyk alerts
- When onboarding a new repo to the security triage pipeline
- Weekly cron alongside entropy-check for full health signal

---

## Classification Model

Two dimensions determine priority:

**Dimension 1 — Severity** (from CVE/advisory): `critical` | `high` | `medium` | `low`

**Dimension 2 — Exploitability** (from context): `network-reachable` | `dev-only` | `test-only`

- **network-reachable**: the vulnerable package is in a runtime dependency exposed to the internet
- **dev-only**: the package is a `devDependency` / build tool, not shipped to production
- **test-only**: only used in tests, never runs in production

### Decision Matrix

```
                    | network-reachable | dev-only | test-only
--------------------+-------------------+----------+----------
critical            | P0 — patch now    | P1       | P2
high                | P1 — this week    | P2       | P2
medium              | P2 — batch next   | backlog  | dismiss
low                 | backlog           | dismiss  | dismiss
```

### Action per Priority

| Priority | Action | Label |
|---|---|---|
| P0 | Open fix PR immediately; block deploys if no patch exists | `security` `P0` |
| P1 | Open fix PR this week | `security` `P1` |
| P2 | Create issue with upgrade path; batch in monthly cycle | `security` `P2` |
| Backlog | Create issue, no urgency | `security` |
| Dismiss | Dismiss via API with documented reason | — |

---

## Auto-Patch Criteria

A patch is **safe to auto-merge** (open PR without manual review) when ALL of the following are true:

1. **Patch-version bump only** — e.g., `1.2.3 → 1.2.4`. Minor or major bumps require manual review.
2. **CVE is fixed in the patch** — verify via the GitHub advisory or NVD entry.
3. **No breaking changes** — scan the package CHANGELOG for the target version range.
4. **CI passes** — the update must not break existing tests.

If any criterion fails → **manual review required** before merging.

---

## Merge Strategy Awareness

**CRITICAL: Never auto-merge security patches on restricted repos.**

Before opening or merging any PR, check the repo's `merge_strategy` in `crew.yml`:

```bash
MERGE_STRATEGY=$(cat crew.yml 2>/dev/null | grep merge_strategy | head -1 | awk '{print $2}')
```

| merge_strategy | Action |
|---|---|
| `auto-merge` | Safe patches can be merged automatically after CI green |
| `restricted` | Apply label `ready-to-merge`; human reviews and merges manually |
| (missing/unknown) | Treat as `restricted` — fail safe |

Example restricted repos: Lexgo. When in doubt, treat as restricted.

---

## Exploitability Detection

To determine network-reachability, inspect `package.json` (or equivalent):

```bash
# Node.js — check if the package is in dependencies vs devDependencies
cat package.json | python3 -c "
import sys, json
pkg = json.load(sys.stdin)
print('runtime:', list(pkg.get('dependencies', {}).keys()))
print('dev:', list(pkg.get('devDependencies', {}).keys()))
"
```

```bash
# Ruby — check Gemfile groups
grep -A5 'group :development\|group :test' Gemfile
```

```bash
# Python — check if package is in requirements.txt vs requirements-dev.txt
diff <(cat requirements.txt 2>/dev/null) <(cat requirements-dev.txt 2>/dev/null)
```

If the alert package appears in **both** runtime and dev — classify as **network-reachable**.

---

## OpenSSF Scorecard Integration

> **Attribution**: [ossf/scorecard](https://github.com/ossf/scorecard) by OpenSSF contributors (Apache 2.0).
> Run before building custom security grades — scorecard covers 18 security checks out of the box.

Run scorecard to supplement alert triage with repo-level security posture:

```bash
# Install (one-time)
go install sigs.k8s.io/scorecard/v4@latest

# Run against target repo
scorecard --repo github.com/{org}/{repo} --format json 2>/dev/null | \
  jq '.checks[] | {name: .name, score: .score, reason: .reason}' | \
  grep -E '"score": [0-7]'  # Surface low-scoring checks
```

Scores 0-10 per check. Checks to prioritize:
- **Token-Permissions** (< 7): workflows using excessive token scopes
- **Branch-Protection** (< 7): missing branch rules
- **Dependency-Update-Tool** (< 7): no Dependabot or Renovate configured
- **Vulnerabilities** (< 10): known CVEs in dependencies

Feed scorecard output into entropy-check grades — security score signals go into the `D/F` grade bucket.

---

## Cron Integration

Add to `crew.yml` for weekly automated triage:

```yaml
cron:
  - schedule: "0 5 * * 1"   # Every Monday at 05:00
    task: "Weekly security triage: process open Dependabot/Snyk alerts on all active repos, open fix PRs for safe patches, create issues for breaking changes"
```

---

## Output Contract

After classifying a batch of alerts, produce a triage summary:

```
Security Triage: {org}/{repo}
Date: YYYY-MM-DD
Alerts scanned: N

P0 (patch now):    X alerts
P1 (this week):    Y alerts
P2 (batch next):   Z alerts
Backlog:           A alerts
Dismissed:         B alerts

Action required:
- [CRITICAL][net-reachable] lodash@4.17.20 → CVE-2021-23337 — patch to 4.17.21 (safe, patch-only)
- [HIGH][dev-only] webpack@4.46.0 → CVE-2023-28154 — P2, no runtime exposure
```

---

## Related Skills

- `/security-runner` — executes the triage: opens PRs, creates issues, dismisses via API
- `/entropy-check` — doc/architecture health; scorecard scores can feed into entropy grades
- `/maintenance` — checks Dependabot coverage (is Dependabot even configured?)
- `/deps-runner` — handles non-security dependency updates; follows same PR pattern
