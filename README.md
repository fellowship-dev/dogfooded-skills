# dogfooded-skills

A cross-platform agent skill library compatible with 41+ agents via the [Vercel `npx skills`](https://skills.new) ecosystem. Built and battle-tested internally at [fellowship-dev](https://github.com/fellowship-dev) — every skill here has run hundreds of times in real production workflows before being published.

## What Are Skills?

Agent **skills** are markdown files placed at `.claude/skills/<skill-name>/SKILL.md`. When invoked via skill invocation or referenced in the project instructions file, the skill's content is loaded into the agent's context — giving it persistent, reusable capabilities without burning prompt space on every message.

Skills are not prompts. They are **runbooks**: structured, concrete instructions with real commands, decision tables, and explicit gotchas. A good skill makes the agent behave like a domain expert, not a generalist guesser.

## Install

Install any skill directly into your project using the `npx skills` subpath syntax:

```bash
npx skills add fellowship-dev/dogfooded-skills/meta/skill-builder
npx skills add fellowship-dev/dogfooded-skills/meta/migrate-skill
npx skills add fellowship-dev/dogfooded-skills/product/spec-plan
npx skills add fellowship-dev/dogfooded-skills/product/build-prd
npx skills add fellowship-dev/dogfooded-skills/ops/distill
npx skills add fellowship-dev/dogfooded-skills/ops/visual-evidence
```

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

Skills for CI, deployment, and evidence workflows.

| Skill | Description |
|-------|-------------|
| [`ops/distill`](skills/ops/distill/) | Post-mission audit — classifies outcomes using 8-code failure taxonomy (capture), aggregates trends and creates GitHub issues (analyze) |
| [`ops/visual-evidence`](skills/ops/visual-evidence/) | Playwright screenshots and GIF recordings for PR evidence — before/after, feature demos, interaction bugs |

## Namespace Convention

Skills are organized into three namespaces:

| Namespace | Purpose |
|-----------|---------|
| `meta/` | Skills about building and managing skills |
| `product/` | Skills for product development: PRDs, planning, requirements |
| `ops/` | Skills for operations: CI, auditing, evidence capture |

Each skill lives at `skills/<namespace>/<skill-name>/SKILL.md`.

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
