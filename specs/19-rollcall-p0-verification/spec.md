# Spec: Rollcall Scout P0/P1 Verification

**Issue:** fellowship-dev/dogfooded-skills#19
**Title:** Rollcall scout: verify P0/P1 claims before promoting to briefing

## Problem

The morning rollcall promoted 3 false-positive P0s to Max's briefing on 2026-04-17
without verifying claims. All three were closed within minutes after a basic curl check.
False P0s waste Max's most scarce resource (desk time).

## Scope

Modify `skills/ops/daily-report/SKILL.md` — the shared skill used by all team rollcall
workers when assembling production health status.

## Trigger Conditions

Apply verification when an open issue:
- Has label `priority-critical` or `priority-high` (P0/P1)
- OR title/body contains keywords: `500`, `down`, `broken`, `production`

## Required Behaviors

### 1. Liveness Check

Extract the production URL from the issue body (look for `https://` URLs that are not
GitHub links). Run:

```bash
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL")
```

- HTTP 200 → flag as `unverified` — production is up, claim is questionable
- HTTP 5xx → confirmed outage → keep as P0
- No URL found → cannot verify → skip liveness, apply evidence check only

### 2. Evidence Check

Scan issue body for production evidence:
- curl output showing non-200 status
- Error log snippet or stack trace
- Screenshot or Sentry/Bugsnag link
- Reproduction steps with confirmed failure

If none found → note `no production evidence`

### 3. Downgrade Presentation

Unverified P0s MUST use the warning format, not the alert format:

```
# Wrong (promotes false positive):
🔴 P0: farmesa 500 error (live site)

# Correct (flags for scrutiny):
⚠️ UNVERIFIED: farmesa#84 claims 500 — production returns 200, likely false positive
```

Verified P0s keep the 🔴 format with a `[verified: curl → 5xx]` annotation.

### 4. Ask the Filer

If no production URL in issue body (cannot run liveness check):
- Comment on the issue requesting evidence before this can be promoted to P0
- Template:

```
Promoting this to P0 in rollcall requires production evidence.
Please add one of:
- curl output showing the error (curl -I https://your-production-url.com)
- Screenshot or error log from production
- Sentry/Bugsnag link

Without evidence, this will appear as ⚠️ UNVERIFIED in the briefing.
```

## Verification Procedure (Decision Tree)

```
Issue claims P0/P1 or has keywords?
├── YES → Extract production URL from body
│   ├── URL found → curl it (--max-time 10)
│   │   ├── 5xx/timeout → ✅ Confirmed → 🔴 P0: [title] [verified: curl → 5xx]
│   │   └── 200 → ⚠️ UNVERIFIED: [repo#N] claims [keyword] — production returns 200, likely false positive
│   └── No URL → Check for evidence (screenshots, logs, stack traces)
│       ├── Evidence found → 🟡 NEEDS REVIEW: [title] — unverified but has production evidence
│       └── No evidence → Comment on issue requesting evidence
│                       → ⚠️ UNVERIFIED: [repo#N] claims [keyword] — no production URL or evidence
└── NO → Standard reporting, no verification needed
```

## Output Contract

Section 0 (Production Health) entries for P0/P1 claims:

| Scenario | Format |
|----------|--------|
| Verified outage (curl 5xx) | `🔴 P0: repo — [title] [verified: curl → 503]` |
| Unverified (curl 200) | `⚠️ UNVERIFIED: repo#N claims [keyword] — production returns 200, likely false positive` |
| Has evidence, no URL | `🟡 NEEDS REVIEW: repo#N — [title] — has evidence, cannot auto-verify` |
| No URL, no evidence | `⚠️ UNVERIFIED: repo#N claims [keyword] — no production URL or evidence; asked filer for evidence` |

## Files Changed

- `skills/ops/daily-report/SKILL.md` — add P0/P1 verification subsection to Section 0
