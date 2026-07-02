---
name: agent-readiness
description: Use when assessing whether a repo is ready for autonomous AI agents (pylot workers) — produces a scored, actionable Agent Readiness Report as a GitHub issue in the assessed repo.
argument-hint: "org/repo [team]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# agent-readiness

Assess a repository's readiness for autonomous agent work (à la factory.ai's agent
readiness assessment, pylot-native). Clones the repo read-only, scores **8 dimensions**,
and files a single `🤖 Agent Readiness Report` issue in the assessed repo with scores and
a prioritized remediation checklist. Idempotent: re-runs update the existing report issue
instead of opening duplicates.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/skills/ops/agent-readiness
```

## When to Use

- Onboarding a fresh repo/org into pylot — know what to fix before dispatching missions
- Demo: show a prospect exactly what agents need from their codebase, with a punch list
- Quarterly re-assessment of active repos (readiness drifts as codebases evolve)

## Inputs

- `$1` — `org/repo` to assess (required)
- `$2` — pylot team name (optional; enables the Pylot Wiring dimension checks via the gateway)

## Procedure

### 0. Access + clone

Mint repo credentials through the gateway (never require a personal PAT):

```bash
TOKEN_JSON=$(curl -fsS "$PYLOT_GATEWAY_URL/git-token?repo=$REPO" \
  -H "Authorization: Bearer ${PYLOT_BROKER_TOKEN:-$PYLOT_DISPATCH_TOKEN}")
GH_TOKEN=$(echo "$TOKEN_JSON" | jq -r .token)
git clone --depth 50 "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" /tmp/assess-repo
```

Shallow (depth 50) is enough — you need the tree + recent history, not archaeology.

### 1. Score the 8 dimensions

Score each 0–10 using the mechanical checks below, then adjust ±2 with judgment
(explain any adjustment in the report). **Do not fabricate**: every score must cite the
files/commands that produced it. If a check can't run, say so and score conservatively.

| # | Dimension | Mechanical checks (each ✓/✗ with evidence) |
|---|---|---|
| 1 | **Environment reproducibility** | `.devcontainer/` or `Dockerfile` present; lockfile present (package-lock/poetry.lock/Gemfile.lock/go.sum); pinned runtime (.nvmrc, .tool-versions, engines); install command succeeds headlessly (`npm ci` / `pip install -r` / etc. — actually run it, 10 min budget) |
| 2 | **Test trust** | test dir/files exist; test command discoverable (package.json scripts, Makefile, CI yml); tests RUN headlessly without live creds (actually run, 10 min budget); pass/fail/flaky count |
| 3 | **Agent context** | CLAUDE.md or AGENTS.md present; README explains what+how-to-run; architecture/docs dir; comment density not misleading |
| 4 | **CI/CD** | workflow files present; default-branch status of latest runs (via API); branch protection on default branch |
| 5 | **Task readiness** | open issues count; % with body >200 chars; labels exist; issue templates present |
| 6 | **Secrets hygiene** | `.env.example` or documented config; `.env`/keys NOT committed (grep for obvious creds: `-----BEGIN`, `AKIA`, `sk-`, hardcoded passwords); secrets usage documented |
| 7 | **Pylot wiring** (only if `$2` team given) | repo in team's `repos` (GET /crew); devbox_config registered; worker image exists; team goals set; **org skills home exists** — probe `GET $PYLOT_GATEWAY_URL/git-token?repo=<org>/pylot-skills` (also try `<org>/skills`): 200 = exists & App-accessible, 4xx = missing. Skip cleanly (`n/a`) if no team arg |
| 8 | **Code health quick-scan** | lint/format config present; largest file LOC (>1500 = smell); TODO/FIXME density; dependency staleness (count majors behind on top 10 deps) |

### 2. Compute the verdict

- **Overall score** = weighted mean: env 20%, tests 25%, context 15%, CI 10%, tasks 10%, secrets 10%, wiring 5%, health 5%. (Without a team arg, redistribute wiring's 5% to tests.)
- **Tier:** 8.0+ `READY` · 6.0–7.9 `NEARLY READY` · 4.0–5.9 `NEEDS WORK` · <4.0 `NOT READY`
- **Top fixes:** the 3–7 highest-ROI remediations, each with effort (S/M/L) and which
  dimension it unblocks. Order by (score impact ÷ effort). Be concrete: "add
  `.devcontainer/devcontainer.json` with node:22 + postCreateCommand `npm ci`", not
  "improve environment".

### 3. File the report issue

Search for an existing open issue titled `🤖 Agent Readiness Report` (exact match) —
update its body if found, create otherwise. Use the minted installation token.

Body template:

```markdown
# 🤖 Agent Readiness Report — <org/repo>

**Overall: <score>/10 — <TIER>**  ·  assessed <date> · commit <sha7>

| Dimension | Score | Evidence |
|---|---|---|
| Environment reproducibility | x/10 | <one-line: what was found/run> |
| … all 8 rows … |

## Top fixes (highest ROI first)
- [ ] **<fix>** (effort S/M/L, unblocks <dimension>) — <one concrete instruction>
…

## What agents can already do here
<2-4 bullets of work types that are safe to dispatch TODAY given current scores>

## Org setup (include ONLY if the org skills home probe failed)
- [ ] **Create your org's private skills home** — repo `<org>/pylot-skills` (private, empty is fine), then install the pylot GitHub App on it. This is where org-specific agent skills live; without it your teams can only use the shared cross-org skills. *(An org admin must do this — pylot's App token cannot create repos by design.)*

## Details
<per-dimension: checks run, outputs, and why the score>

---
_Generated by [pylot](https://pylot.fellowship.dev) `/agent-readiness`. Re-run to refresh._
```

### 4. Report

Write the mission report (score, tier, issue URL, top fixes). One line per repo verdict —
the owner reads scores, not transcripts.

## Guardrails

- **Read-only on the repo**: never push, never open PRs, never modify code. The ONLY write is the report issue.
- Never print minted tokens to logs or the report.
- Install/test runs happen in the clone under `/tmp`, network allowed, 10 min budget each — if exceeded, record `timeout` as the evidence and move on.
- If the clone itself fails, file no issue; fail the mission with the gateway error.
