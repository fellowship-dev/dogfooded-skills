# dogfooded-skills

A cross-platform agent skill library compatible with 41+ agents via the [Vercel `npx skills`](https://skills.new) ecosystem. Built and battle-tested internally at [fellowship-dev](https://github.com/fellowship-dev) — every skill here has run hundreds of times in real production workflows before being published.

## What Are Skills?

Agent **skills** are markdown files placed at `.claude/skills/<skill-name>/SKILL.md`. When invoked via skill invocation or referenced in the project instructions file, the skill's content is loaded into the agent's context — giving it persistent, reusable capabilities without burning prompt space on every message.

Skills are not prompts. They are **runbooks**: structured, concrete instructions with real commands, decision tables, and explicit gotchas. A good skill makes the agent behave like a domain expert, not a generalist guesser.

## Install

Install all skills:

```bash
npx skills add fellowship-dev/dogfooded-skills --full-depth --skill '*' -y
```

Install specific skills by name:

```bash
npx skills add fellowship-dev/dogfooded-skills --full-depth --skill 'entropy-check' --skill 'hookshot' -y
```

> **Note:** `--full-depth` is required because skills are organized in namespace subdirectories (`ops/`, `product/`, `meta/`). Without it, only top-level skills are discovered.

## Skill Catalog

### meta

Skills about the skills system itself.

| Skill | Description |
|-------|-------------|
| [`meta/skill-builder`](skills/meta/skill-builder/) | How to write a high-quality agent skill for this library |
| [`meta/migrate-skill`](skills/meta/migrate-skill/) | Move a skill from toolkit/local into dogfooded-skills and import it back |

### product

Skills for product development workflows.

| Skill | Description |
|-------|-------------|
| [`product/spec-plan`](skills/product/spec-plan/) | Relentless design interview — walk the decision tree one branch at a time until shared understanding |
| [`product/build-prd`](skills/product/build-prd/) | Collaborative PRD creation from feature requests — 7-step workflow with GitHub integration |

### ops

Skills for CI, deployment, operations, and evidence workflows.

| Skill | Description |
|-------|-------------|
| [`ops/setup-harness`](skills/ops/setup-harness/) | Scaffold the knowledge layer — ARCHITECTURE.md, QUALITY_SCORE.md, docs/, FlowChad flows |
| [`ops/entropy-check`](skills/ops/entropy-check/) | Sensor — checks doc freshness and computes domain quality grades. Updates QUALITY_SCORE.md |
| [`ops/hookshot`](skills/ops/hookshot/) | Generate Claude Code enforcement hooks from docs/ — pre-edit reminders before file changes |
| [`ops/maintenance`](skills/ops/maintenance/) | Infra-only health audit — LaunchAgents, cron logs, system health, secrets scan |
| [`ops/cto-review`](skills/ops/cto-review/) | Strategic CTO checklist for PR review — architecture impact, quality rubric adherence |
| [`ops/double-check`](skills/ops/double-check/) | Second-pass PR double-check — fix must-fix issues, run tests, post curated review |
| [`ops/distill`](skills/ops/distill/) | Post-mission audit — classifies outcomes using 8-code failure taxonomy |
| [`ops/visual-evidence`](skills/ops/visual-evidence/) | Playwright screenshots and GIF recordings for PR evidence |
| [`ops/docs-review`](skills/ops/docs-review/) | Detect drift between docs/ and source code — flags, states, config keys, and paths |
| [`ops/setup-github`](skills/ops/setup-github/) | Set up GitHub Actions workflows, labels, and project board |
| [`ops/daily-report`](skills/ops/daily-report/) | Standard format for daily/rollcall team reports |
| [`ops/write-report`](skills/ops/write-report/) | Write a mission report to reports/ — resolves paths, generates timestamps, posts to Quest |

## Namespace Convention

Skills are organized into three namespaces:

| Namespace | Purpose |
|-----------|---------|
| `meta/` | Skills about building and managing skills |
| `product/` | Skills for product development: PRDs, planning, requirements |
| `ops/` | Skills for operations: CI, auditing, evidence capture |

Each skill lives at `skills/<namespace>/<skill-name>/SKILL.md`.

## Install Gotchas

- **`--full-depth` is required** for bulk install (`--skill` flag). Without it, only top-level skills are discovered — namespaced skills under `ops/`, `product/`, `meta/` are silently skipped.
- **`--skill` must be repeated per skill**, not comma-separated: `--skill 'entropy-check' --skill 'hookshot'` (not `--skill 'entropy-check,hookshot'`).
- **Subpath syntax** works for single skills but needs the full path including the `skills/` prefix: `fellowship-dev/dogfooded-skills/skills/ops/entropy-check`.
- **`--skill '*'`** installs all discovered skills.

## Design Principles

1. **Agent-agnostic** — skills work with any agent that supports the Vercel skill format, not just one tool
2. **Concrete over abstract** — every skill ships with real commands, not pseudocode
3. **Explicit gotchas** — if something can go wrong, the skill says so
4. **Decision tables** — when there are multiple paths, a table makes the choice clear
5. **Minimal frontmatter** — only Vercel standard fields (`name`, `description`, `allowed-tools`)
6. **Self-contained** — a skill can be dropped into any project and work without external docs

## Contributing

See the [`meta/skill-builder`](skills/meta/skill-builder/) skill for the complete authoring standard.

In short:
1. Write the skill following the skill-builder standard
2. Place it in the correct namespace (`meta/`, `product/`, or `ops/`)
3. Use only Vercel standard frontmatter: `name`, `description`, and optionally `allowed-tools`
4. Run it at least five times against real workloads
5. Open a PR — the benchmark results go in the PR body
