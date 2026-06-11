---
name: daily-report
description: Use when writing the daily/rollcall team report — defines 5 sections, quality rules, and a minimal idle card.
user-invocable: false
allowed-tools: Bash, Read, Grep
---

# daily-report

Standard report format for Pylot crew teams. Used in morning rollcall dispatch jobs and any standup/status reporting task.

## When to Use

- You have been dispatched with a rollcall or standup task
- Your task says "write today's team report per /daily-report"
- Any task asking for a team status report

## Standard Sections

### Section 0: Production Health (MANDATORY — P0/P1 verification required)

One line per repo. Must appear FIRST — production issues are never buried below issues or PRs.

Format:
```
- org/repo — 🟢 green: up, no incidents
- org/repo — 🔴 red: 500 errors on /api/products (issue #84, since 2026-04-11) [verified: curl → 503]
- org/repo — 🟡 yellow: degraded response times, investigating
- org/repo — ⚠️ UNVERIFIED: repo#84 claims 500 — production returns 200, likely false positive
```

If no active incidents: `All repos: 🟢 green`

#### P0/P1 Verification Protocol

**Any issue claiming P0/P1 severity OR containing keywords `500`, `down`, `broken`, `production` in the title or body MUST be verified before being promoted to the briefing.** Unverified P0s waste Max's desk time — they are more harmful than missing a real incident.

**Decision tree:**

```
Issue claims P0/P1 or has keywords (500, down, broken, production)?
├── YES → Extract production URL from body (https:// that is NOT a GitHub URL)
│   ├── URL found → run liveness check:
│   │   STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$PROD_URL")
│   │   ├── 5xx or timeout → CONFIRMED outage
│   │   │   → 🔴 P0: org/repo — [title] (issue #N, since DATE) [verified: curl → $STATUS]
│   │   └── 200 → UNVERIFIED — production is up, claim is questionable
│   │       → ⚠️ UNVERIFIED: org/repo#N claims [keyword] — production returns 200, likely false positive
│   └── No production URL → check issue body for evidence:
│       ├── Has evidence (curl output, screenshot, error log, Sentry/Bugsnag link)
│       │   → 🟡 NEEDS REVIEW: org/repo#N — [title] — has evidence, cannot auto-verify
│       └── No evidence → comment on the issue asking for evidence (see template below)
│           → ⚠️ UNVERIFIED: org/repo#N claims [keyword] — no production URL or evidence; asked filer
└── NO → Standard reporting, no verification needed
```

**Output formats by scenario:**

| Scenario | Format |
|----------|--------|
| Verified outage (curl 5xx) | `🔴 P0: org/repo — [title] [verified: curl → 503]` |
| Unverified (curl 200) | `⚠️ UNVERIFIED: org/repo#N claims [keyword] — production returns 200, likely false positive` |
| Has evidence, no URL | `🟡 NEEDS REVIEW: org/repo#N — [title] — has evidence, cannot auto-verify` |
| No URL, no evidence | `⚠️ UNVERIFIED: org/repo#N claims [keyword] — no production URL or evidence; asked filer` |

**Ask-filer comment template** (post when no URL and no evidence found):

```bash
gh issue comment $ISSUE_NUMBER --repo $ORG/$REPO --body "Promoting this to P0 in rollcall requires production evidence.
Please add one of:
- curl output showing the error: \`curl -I https://your-production-url.com\`
- Screenshot or error log from production
- Sentry/Bugsnag link

Without evidence, this will appear as ⚠️ UNVERIFIED in the morning briefing."
```

### Section 1: Open Issues

For each repo, list all open issues. Verify each is actually open — do NOT parrot stale data.

Format per issue:
```
- #N [Title](https://github.com/org/repo/issues/N) — labels: priority-high, bug
```

If 0 open issues: state it explicitly.

### Section 2: PRs Waiting

**Split feature PRs from dep PRs — never mix them in the same list.**

Feature PRs:
```
- #N [Title](https://github.com/org/repo/pull/N) — status: review | 3d / 2026-04-10
- #N [Title](https://github.com/org/repo/pull/N) — status: draft | 15d / 2026-03-26 [STALE]
```

Dep PRs (one line each with risk label):
```
- #N [bump lodash 4→5](https://github.com/org/repo/pull/N) — CRIT | 2d / 2026-04-11
- #N [bump eslint 8→9](https://github.com/org/repo/pull/N) — LOW | 5d / 2026-04-08
```

Risk labels:
- **CRIT** — security CVE, known breakage, or major version with documented breaking changes
- **HIGH** — major version bump with possible API breaks
- **MED** — minor version with notable changes
- **LOW** — patch update, routine

PR count headline: `N open (X actionable, Y stale drafts)` — never a bare count.

Repos with no CI configured: note it once as a section footer, not per-PR.

### Section 3: Latest Updates

Named merges with PR number and merge date. A bare count ("8 PRs merged") is useless.

Format:
```
- PR #N [Title](url) — merged 2026-04-10
- PR #N [Title](url) — merged 2026-04-09
```

If nothing merged in 7 days: state it and note the last merge date.

### Section 4: Suggested Next Tasks

2-3 concrete actions. Each must have:
- Exact slash command where applicable: `/review-pr 47 CLAPES-UC/ipc-med-backend ipcmed-runner`
- Sequencing note when order matters: "do this BEFORE merging deps — lockfile conflict risk"
- Reasoning tied to team Direction goals
- Risk callout for dangerous deps: "do NOT merge Next.js 16 without testing locally"

## Quality Rules

- Every issue/PR MUST include a full clickable URL (`https://github.com/org/repo/issues/N` or `/pull/N`)
- Ages include absolute dates alongside relative: `3d / 2026-04-10` — not just `3d`
- "Quiet" is not a report — if nothing happened, say what SHOULD happen next from the backlog
- Verify data freshness before reporting — call `gh issue list` and `gh pr list`, don't guess
- Closed issues are NOT open — verify with `gh issue view N --repo org/repo --json state`
- **P0/P1 production claims MUST be verified with curl before promoting to briefing** — see the P0/P1 Verification Protocol in Section 0. An unverified P0 in the briefing wastes more time than a missed real incident.

## Minimal Format for Idle Teams

Teams with 0 open issues AND 0 feature PRs get a 10-line status card instead of the full format:

```
## {team} — IDLE
Prod: 🟢 green | Issues: 0 | Feature PRs: 0 | Dep PRs: N
Last merge: YYYY-MM-DD / PR #N [Title](url)
Next: {suggested action — e.g., "process dep PRs on weekend, watch for Next.js 16 breaking changes"}
```

Do NOT produce a full section-by-section breakdown for idle teams — it adds noise without signal.

## Report Location

All reports go to `$(git rev-parse --show-toplevel)/reports/`. NEVER inside `crew/*/reports/` or any subdirectory.

## Writing the Report File

Once you have drafted all sections above, use `/write-report` to write the file:

```bash
/write-report --group rollcall --id {your-team-name} --type rollcall
```

This ensures:
- Correct path (`reports/` from repo root, never `crew/*/`)
- Correct timestamped filename per CONVENTIONS.md
- Automatic Quest DB posting
- Consistent naming across all teams

Do NOT write the file manually using the Write tool — always use `/write-report`.
