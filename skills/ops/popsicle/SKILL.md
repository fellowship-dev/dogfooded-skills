---
name: popsicle
description: Agent-native onboarding doc generator — builds coverage maps, health baselines, generated docs, and agent adapters so any AI tool can autonomously navigate your repo.
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Popsicle

Agent-native onboarding doc generator. Discover. Map. Generate. Adapt. Validate. Loop.

**Purpose:** Make any repo agent-ready. A fresh AI agent with zero context should be able to read the docs and start working — without reading source code first.

**Agent-ready output.** Every artifact popsicle produces — coverage maps, health baselines, generated docs, agent adapters — is designed so a fresh AI agent can navigate your repo independently, not just a human skimming the README.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/skills/ops/popsicle
```

## When to Use

- **New repo onboarding:** Bootstrap agent-readable docs from scratch.
- **After major refactors:** Verify docs still match reality.
- **Periodic health check:** Catch doc rot before it compounds.
- **Before handing a repo to agents:** Confirm docs give a fresh agent enough to work independently.
- **Multi-tool teams:** Use `--agents` to generate adapter files for Cursor, Copilot, and Codex.

## Anti-Cheat Constraint

Whatever you discover during research is the **answer key**. The repo docs are the **test**. The fresh validation session is the **student**.

Discovery artifacts (knowledge map) MUST live in `/tmp`, never in the repo. The validation sessions must have zero access to discovery artifacts. If they can see what you found, the test is worthless.

---

## Doc Types — What Goes Where

Agents need three kinds of documentation. Popsicle enforces separation:

### 1. `CLAUDE.md` — Agent Instructions (≤80 lines)

The entry point. An agent reads this first. It answers: "What is this repo, how do I work in it, and what rules must I follow?"

**What belongs here:**
- Project identity (one sentence: what this is, what stack)
- How to install, run, test, deploy (commands only, no explanation)
- Key rules and constraints (things that break if violated)
- Pointers to `docs/` for deeper reference

**What does NOT belong here:**
- Architecture explanations (→ `docs/architecture.md`)
- API reference (→ `docs/api.md`)
- Config/env var tables longer than 5 rows (→ `docs/configuration.md`)
- Runbooks or troubleshooting (→ `docs/runbook.md`)
- History, context, or "why we built this" (→ README.md or nowhere)

**Budget: ≤80 lines.** If CLAUDE.md exceeds 80 lines after your changes, refactor: move detail into `docs/` and replace with a one-line pointer. Count lines with `wc -l CLAUDE.md`.

### 2. `docs/*.md` — Reference Documentation

Deep knowledge an agent navigates to when working on specific areas. Each file covers one topic. An agent should be able to find the right file by name alone.

**Standard files** (create only the ones the repo needs):
- `docs/architecture.md` — system boundaries, data flow, key abstractions, service map
- `docs/api.md` — routes, endpoints, request/response shapes
- `docs/configuration.md` — env vars, feature flags, config files with all options documented
- `docs/workflows.md` — dev workflow, CI/CD, deploy process, release steps
- `docs/data-model.md` — database schema, key tables, relationships
- `docs/glossary.md` — domain terms that aren't obvious from code (only if needed)
- `docs/runbook.md` — how to debug common issues, operational procedures

**Rules:**
- One topic per file. If a file exceeds 200 lines, split it.
- File names must be self-descriptive — an agent picks which file to read based on the name.
- No `docs/misc.md` or `docs/notes.md` — if it doesn't have a clear topic, it doesn't belong.
- Link between doc files when concepts cross boundaries.

### 3. `README.md` — Human Documentation (don't touch)

README.md is for humans: badges, screenshots, marketing copy, contribution guides. **Popsicle does not modify README.md.** If critical info exists only in README.md and belongs in agent docs, copy the relevant facts into the appropriate `docs/` file or CLAUDE.md — don't restructure the README.

---

## Instructions

### 0. Setup

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename $(git remote get-url origin) .git)
TODAY=$(date +%Y-%m-%d)
ITERATION=1
MAX_ITERATIONS=5
PASS_THRESHOLD=80
```

Parse flags:
- `--loop` — run the full loop until pass rate >= 80% or max iterations
- `--agents` — generate agent adapter files (Phase 2.5)
- `--canonical agents` — make `AGENTS.md` the source of truth; `CLAUDE.md` symlinks to it

Auto-detect `--agents` behavior: if `.cursor/` or `.github/copilot-instructions.md` already exists in the repo, treat `--agents` as set.

**You MUST complete ALL phases in every iteration.** Do not stop after validation — always grade, report, and decide whether to loop. If context is tight, keep grading terse (one line per concept).

---

### Phase 1: Discover (Build the Answer Key)

Scan the repo systematically. Build a knowledge map of what an agent SHOULD be able to learn from good docs.

**What to scan:**
- Entry points (`main`, `index`, `app`, CLI entrypoints)
- How to install, run, test (the commands, not just that they exist)
- API routes and endpoints
- Config files (env vars, feature flags, deploy config)
- Important abstractions (key classes, modules, patterns)
- Architecture (service boundaries, data flow, external deps)
- Dev workflow (CI, deploy, release process)
- Domain-specific terms that aren't obvious from code

**Classify each concept by doc type** — where should an agent find this?

| Category | Target file |
|----------|-------------|
| identity, stack, run/test commands, key rules | `CLAUDE.md` |
| system design, data flow, service boundaries | `docs/architecture.md` |
| routes, endpoints, request/response | `docs/api.md` |
| env vars, config files, feature flags | `docs/configuration.md` |
| dev workflow, CI/CD, deploy, release | `docs/workflows.md` |
| database schema, key tables | `docs/data-model.md` |
| domain terms | `docs/glossary.md` |

**Pick 5-10 concepts per iteration.** Rotate across iterations so you eventually cover the whole repo. Don't repeat concepts that already PASSed.

Write the knowledge map to a temp file:

```bash
KNOWLEDGE_MAP="/tmp/popsicle-knowledge-$(date +%s).json"
```

```bash
python3 -c "
import json, sys
concepts = [
    {
        'id': 'concept-1',
        'category': 'architecture',
        'target_file': 'docs/architecture.md',
        'name': 'Short name',
        'description': 'What an agent should know about this',
        'evidence': 'Where you found it in the code (file:line)',
        'question': 'Question to ask the validation session',
        'nav_question': 'Which doc file would you read to learn about this?'
    },
    # ... 5-10 concepts
]
with open('$KNOWLEDGE_MAP', 'w') as f:
    json.dump({'repo': '$REPO_NAME', 'iteration': $ITERATION, 'concepts': concepts}, f, indent=2)
"
```

**This file is the answer key. It stays in `/tmp`. Never commit it.**

---

### Phase 1.5: Coverage Map

After discovery, write a coverage map so that both humans and agents can see at a glance what is documented and what is not.

Write (or overwrite) `docs/coverage-map.md`:

```markdown
# Coverage Map — {REPO_NAME}

> Generated by popsicle on {TODAY} (iteration {N}).
> ✓ = documented  ✗ = gap  ~ = partial

## {top-level-area/}

- ✓ `src/index.ts` — entry point, startup sequence
- ✓ `src/routes/` — API routes (see docs/architecture.md)
- ✗ `src/workers/` — background job processing (undocumented)
- ~ `src/models/` — data models exist in README but schema not captured

## {another-area/}

- ✗ `scripts/deploy.sh` — deployment procedure (gap)
- ✓ `.env.example` — environment variables documented in CLAUDE.md
```

Rules:
- Use hierarchical file-tree order that mirrors the directory structure.
- Every file/area surfaced during discovery gets an entry.
- Do not fabricate entries for areas you did not scan.
- Mark `✓` only if a validation session could plausibly find the answer in docs. If uncertain, mark `~`.

Commit with doc changes (Phase 2 commit covers this file too).

---

### Phase 2: Generate (Improve the Docs)

Read existing docs: `CLAUDE.md`, `docs/` directory, `README.md` (read-only reference).

For each concept in the knowledge map:
1. Does the target file exist? If not, create it with a `# Title` header.
2. Is the concept already documented in the right place? If yes, skip.
3. If documented in the wrong place (e.g., architecture details in CLAUDE.md), move it.
4. If missing, write it in the target file.

**After all concepts are placed, enforce budgets:**

```bash
CLAUDE_LINES=$(wc -l < CLAUDE.md 2>/dev/null || echo 0)
if [ "$CLAUDE_LINES" -gt 80 ]; then
  echo "CLAUDE.md is $CLAUDE_LINES lines — over 80-line budget. Refactor."
fi
```

If CLAUDE.md exceeds 80 lines:
1. Identify sections that are reference material (tables >5 rows, detailed explanations, examples).
2. Move them to the appropriate `docs/` file.
3. Replace with a one-line pointer: `See [docs/configuration.md](docs/configuration.md) for full env var reference.`
4. Re-check the line count.

**CLAUDE.md structure template** (adapt to repo, don't force sections that don't apply):

```markdown
# {Repo Name}

{One sentence: what this is and what stack.}

## Quick Start

{install, run, test commands — no prose, just the commands}

## Key Rules

{Things that break if violated — max 5 bullets}

## Project Structure

{Only if non-obvious — 5-10 lines max showing key directories}

## Reference

- [Architecture](docs/architecture.md) — {one-line summary}
- [Configuration](docs/configuration.md) — {one-line summary}
- [API](docs/api.md) — {one-line summary}
```

#### Health Baseline

Write (or update) `docs/health-baseline.md`. Use categories, not scores:

```markdown
# Doc Health Baseline — {REPO_NAME}

> Last updated by popsicle on {TODAY}.

## Architecture

**Docs exist:** `docs/architecture.md`, CLAUDE.md §Architecture
**Missing:** service dependency graph, data flow for async jobs
**Companion skills installed:** none

## API Contracts

**Docs exist:** README API section
**Missing:** request/response schemas for /auth routes
**Companion skills installed:** none

## Dev Setup

**Docs exist:** README §Getting Started
**Missing:** `.env` values required for local OAuth
**Companion skills installed:** hookshot (enforces freshness on commit)

## Deployment

**Docs exist:** none
**Missing:** deploy command, required secrets, rollback procedure
**Companion skills installed:** none
```

This file is a living foundation for ongoing monitoring. Other skills (entropy-check, hookshot) can consume it.

#### Generated Docs

Write auto-extracted facts to `docs/generated/`. These files are ephemeral — regenerated each iteration. They exist so agents don't have to re-discover them.

Always include a "last updated" header:

```markdown
<!-- generated by popsicle on {TODAY} — do not edit manually -->
```

Files to generate (only when applicable):
- `docs/generated/env-vars.md` — all environment variables found in the codebase (`.env.example`, `process.env.*`, `os.environ`, etc.)
- `docs/generated/api-routes.md` — all API routes extracted from router files
- `docs/generated/db-schema.md` — database schema summary (if ORM or migration files exist)

Commit all doc changes (including coverage-map.md and health-baseline.md):

```bash
git add CLAUDE.md docs/
git commit -m "docs: popsicle iteration $ITERATION — structured agent docs

Concepts targeted: [list the concept names]
Coverage map updated. Health baseline updated."
```

---

### Phase 2.5: Agent Adapters

After doc generation, create agent-agnostic entry points so any AI tool can onboard to this repo.

#### Default (always run)

Create `AGENTS.md` as a symlink to `CLAUDE.md` if it does not already exist:

```bash
if [ ! -e "$REPO_ROOT/AGENTS.md" ]; then
  ln -s CLAUDE.md "$REPO_ROOT/AGENTS.md"
  git add "$REPO_ROOT/AGENTS.md"
  git commit -m "docs: add AGENTS.md symlink for Codex compatibility"
fi
```

If `--canonical agents` flag is set, reverse the relationship — make `AGENTS.md` the real file and `CLAUDE.md` the symlink. Only do this if neither file exists as a symlink yet.

#### With `--agents` flag (or auto-detected)

Auto-detection: if `.cursor/` or `.github/copilot-instructions.md` already exists in the repo, proceed as if `--agents` was passed.

**Before writing any adapter, check if it already exists with custom content.** If a file exists and does not contain the `generated by popsicle` marker, skip it — do not overwrite custom configs.

Write `.github/copilot-instructions.md`:

```markdown
<!-- generated by popsicle — edit CLAUDE.md instead -->
# {REPO_NAME} — Copilot Instructions

See CLAUDE.md for project identity and docs/ for reference material.
Key docs: docs/architecture.md, docs/coverage-map.md, docs/health-baseline.md
```

Write `.cursor/rules/project.mdc`:

```
---
description: Project onboarding for {REPO_NAME}
alwaysApply: true
---
<!-- generated by popsicle — edit CLAUDE.md instead -->
See CLAUDE.md for project identity and docs/ for reference material.
Key docs: docs/architecture.md, docs/coverage-map.md, docs/health-baseline.md
```

**Adapter rules:**
- Adapters are thin pointers — no duplicated content.
- `CLAUDE.md` is always the source of truth (unless `--canonical agents` was set).
- Never overwrite existing custom configs (check for the `generated by popsicle` marker before writing).

Commit adapters (if any were written):

```bash
git add .github/copilot-instructions.md .cursor/rules/project.mdc 2>/dev/null
git diff --cached --quiet || git commit -m "docs: add agent adapter files (popsicle)"
```

---

### Phase 3: Validate (Test with Fresh Sessions)

**Critical: the knowledge map must be invisible to validation sessions.** It's already in `/tmp` (not in the repo), so fresh sessions can't see it.

Two types of validation per concept:

```bash
RESULTS_DIR="/tmp/popsicle-results-$(date +%s)"
mkdir -p "$RESULTS_DIR"
```

**Test A — Content validation** (can the agent answer from docs?):

```bash
claude -p "You are examining the repository at $REPO_ROOT. \
Using ONLY the documentation in this repo (CLAUDE.md, docs/*.md), \
answer this question. Do not read source code — only docs. \
If the docs don't cover this, say 'NOT DOCUMENTED'. \
\
Question: [concept.question]" \
  --model sonnet --output-format text \
  2>/dev/null > "$RESULTS_DIR/concept-N-content-1.txt"
```

Run 2 independent content sessions per concept.

**Test B — Navigation validation** (can the agent find WHERE to look?):

```bash
claude -p "You are examining the repository at $REPO_ROOT. \
Look at the documentation files available (CLAUDE.md, docs/*.md). \
Do NOT read the full contents — only look at file names and headers. \
\
Question: Which specific doc file would you open to learn about: [concept.nav_question]? \
Answer with just the file path." \
  --model sonnet --output-format text \
  2>/dev/null > "$RESULTS_DIR/concept-N-nav.txt"
```

Run 1 navigation session per concept.

**Run up to 3 sessions in parallel** (background and `wait`). Do not exceed 3 concurrent — small machines will OOM.

---

### Phase 4: Grade + Staleness Detection

#### Grading

For each concept, score on two axes:

**Content score** (from Test A):
- **PASS** (2/2): Both sessions answered correctly from docs.
- **WEAK** (1/2): One got it, one didn't.
- **FAIL** (0/2): Neither could answer.

**Navigation score** (from Test B):
- **HIT**: Agent pointed to the correct file (matches `target_file` from knowledge map).
- **MISS**: Agent pointed to wrong file or couldn't find it.

**Combined verdict:**
- **PASS**: Content PASS + Nav HIT
- **PARTIAL**: Content PASS + Nav MISS (info exists but hard to find), or Content WEAK + Nav HIT
- **FAIL**: Content FAIL (regardless of nav), or Content WEAK + Nav MISS

#### Staleness Detection

After grading, run a staleness check by comparing doc claims against actual code. Read the docs produced or updated this iteration and check for factual mismatches.

**What to check:**
- Port numbers (e.g., docs say "port 3000" but code uses `PORT=4000`)
- Environment variable names (e.g., docs say `DATABASE_URL` but code reads `DB_CONNECTION_STRING`)
- File paths (e.g., docs reference `src/server.js` but it was moved to `src/app.js`)
- Command syntax (e.g., docs say `npm start` but `package.json` scripts changed)
- Version numbers (e.g., docs specify Node 16 but `.nvmrc` says 20)

For each mismatch found, add a `STALE` entry:

```json
{
  "type": "STALE",
  "doc_claim": "port 3000 (README line 42)",
  "actual": "PORT env var defaults to 4000 (src/config.ts:8)",
  "fix": "Update README to reference PORT env var"
}
```

Add STALE items to the gaps list in the report (Phase 5).

Compute the pass rate (PASS only, PARTIAL counts as half; STALE items do not affect pass rate — tracked separately):

```bash
SCORE=$((PASS_COUNT * 100 + PARTIAL_COUNT * 50))
PASS_RATE=$((SCORE / TOTAL_CONCEPTS))
```

---

### Phase 5: Report

```bash
REPORT="$REPO_ROOT/docs/popsicle-report-${TODAY}.md"
```

```markdown
# Popsicle Report — {REPO_NAME}

**Date**: {TODAY}
**Iteration**: {N}
**Concepts tested**: {count}
**Pass rate**: {PASS_COUNT}/{TOTAL} ({PCT}%)
**Stale claims found**: {STALE_COUNT}

## Doc Structure

| File | Lines | Status |
|------|-------|--------|
| CLAUDE.md | {n} | {ok / over budget} |
| docs/architecture.md | {n} | {exists / created / n/a} |
| docs/configuration.md | {n} | {exists / created / n/a} |
| ... | | |

## Results

| # | Concept | Target File | Content | Nav | Verdict |
|---|---------|-------------|---------|-----|---------|
| 1 | {name}  | docs/arch.. | PASS    | HIT | PASS    |
| 2 | {name}  | CLAUDE.md   | WEAK    | HIT | PARTIAL |
| 3 | {name}  | docs/api..  | FAIL    | MISS| FAIL    |

## Gaps Remaining

- **{concept}**: {why it failed — what's missing or misplaced}
- ...

## Staleness

<!-- Omit section if STALE_COUNT == 0 -->

- **{doc_claim}** in `{file}`: actual value is `{actual}`. Fix: {fix}
- ...

## Missing Knowledge

<!-- Concepts that cannot be inferred from source code alone. These require human input. -->

- **Business rules**: {e.g., "pricing tiers defined in Notion, not in code"}
- **External credentials**: {e.g., "Stripe webhook secret — ask ops team"}
- **Deployment procedures**: {e.g., "staging deploy requires VPN + manual approval"}
- ...

## Doc Changes This Iteration

- Updated `CLAUDE.md`: added {what}
- Updated `docs/architecture.md`: added {what}
- Updated `docs/coverage-map.md`: reflects new scan
- Updated `docs/health-baseline.md`: added {category} section
- Created `docs/generated/env-vars.md`
- ...

## Companion Skills

These skills complement popsicle for ongoing doc health:

- **hookshot** — enforces doc freshness via commit hooks
  `npx skills add fellowship-dev/dogfooded-skills/skills/ops/hookshot`
- **entropy-check** — periodic doc drift sensor
  `npx skills add fellowship-dev/dogfooded-skills/skills/ops/entropy-check`
- **trash-truck** — removes dead/duplicate code that confuses agents
  `npx skills add fellowship-dev/dogfooded-skills/skills/ops/trash-truck`
- **speckit** — structured issue-to-PR pipeline for doc-gated features
  `npx skills add fellowship-dev/dogfooded-skills/skills/ops/speckit`
```

Commit the report:

```bash
git add "docs/popsicle-report-${TODAY}.md"
git commit -m "docs: popsicle report — iteration $ITERATION, ${PASS_RATE}% pass rate"
```

---

### Phase 6: Loop or Stop

```bash
if [ "$PASS_RATE" -ge "$PASS_THRESHOLD" ]; then
  echo "Pass rate ${PASS_RATE}% >= ${PASS_THRESHOLD}%. Docs are agent-ready. Stopping."
  exit 0
fi

if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  echo "Hit max iterations ($MAX_ITERATIONS). Pass rate: ${PASS_RATE}%. Review remaining gaps manually."
  exit 0
fi

ITERATION=$((ITERATION + 1))
```

If pass rate is below threshold and iterations remain:
1. Read the FAILed, PARTIAL, and STALE concepts from the report.
2. For nav MISSes: restructure — move content to a more discoverable location or rename the file.
3. For content FAILs: improve the docs in the target file. Fix STALE claims immediately.
4. Go back to **Phase 2**.

---

### Cleanup

After all iterations complete:

```bash
rm -f /tmp/popsicle-knowledge-*.json
rm -rf /tmp/popsicle-results-*
```

Discovery artifacts are ephemeral. Reports and doc changes are committed.

---

## Usage Modes

**One-shot** (single iteration, report only):
```bash
/popsicle
```

**Loop** (iterate until pass rate >= 80% or max 5 iterations):
```bash
/popsicle --loop
```

**With agent adapters** (generate Copilot/Cursor files):
```bash
/popsicle --agents
```

**With canonical AGENTS.md** (AGENTS.md is source of truth, CLAUDE.md symlinks to it):
```bash
/popsicle --canonical agents
```

**Crew mission** (dispatched via Pylot):
```bash
curl -X POST "$PYLOT_DISPATCH_URL" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent":"crew.lead","task":"Run popsicle in loop mode on this repo. Commit doc improvements and reports.","repo":"org/repo"}'
```

---

## Design Principles

1. **No rubric.** The skill discovers what matters by reading the code. No upfront configuration needed.
2. **Anti-cheat by architecture.** Discovery artifacts live in `/tmp`. Validation sessions are fresh. The test is honest.
3. **Docs get better every iteration.** This isn't just measurement — it actively fills gaps.
4. **Fresh sessions are the oracle.** If a fresh agent can't learn it from docs, the docs are broken.
5. **Loop-first.** One iteration is useful. Five iterations with targeted fixes is transformative.
6. **Agent-ready framing.** Output is designed for autonomous agents, not just humans. Every doc should answer: "Can a fresh agent work independently in this repo?"
7. **Coverage over completeness.** A coverage map showing known gaps beats docs that claim completeness. Agents prefer honest gaps over false confidence.
8. **Loose coupling.** Each companion skill works independently. Popsicle generates artifacts (coverage-map.md, health-baseline.md) that other skills can optionally consume.
