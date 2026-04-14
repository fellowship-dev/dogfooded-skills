# dogfooded-skills

A cross-platform agent skill library compatible with 40+ agents via the [Vercel `npx skills`](https://skills.new) ecosystem. Built and battle-tested internally at [fellowship-dev](https://github.com/fellowship-dev) — every skill here has run hundreds of times in real production workflows before being published.

## Install

Install all skills:

```bash
npx skills add fellowship-dev/dogfooded-skills --skill '*' -y
```

Install specific skills:

```bash
npx skills add fellowship-dev/dogfooded-skills --skill 'entropy' --skill 'hookshot' -y
```

## Skill Catalog

| Skill | Description |
|-------|-------------|
| [`build-prd`](skills/build-prd/) | Collaborative PRD creation from feature requests — 7-step workflow with GitHub integration |
| [`cto-review`](skills/cto-review/) | CTO-level PR review — architecture impact, quality rubric adherence, process verification |
| [`daily-report`](skills/daily-report/) | Daily repo activity summary — commits, PRs, issues, deployments |
| [`distill`](skills/distill/) | Post-mission audit — classifies outcomes using 8-code failure taxonomy, aggregates trends |
| [`docs-review`](skills/docs-review/) | Detect drift between docs/ and source code — flags, states, config keys, and paths |
| [`double-check`](skills/double-check/) | Second-pass PR review with fixes — push corrections and post curated review comment |
| [`entropy`](skills/entropy/) | Sensor — checks doc freshness and computes domain quality grades. Updates QUALITY_SCORE.md |
| [`hookshot`](skills/hookshot/) | Generate Claude Code enforcement hooks from docs/ — pre-edit reminders before file changes |
| [`maintenance`](skills/maintenance/) | Periodic health audit — investigate, flag findings, create GitHub issues |
| [`migrate-skill`](skills/migrate-skill/) | Move a skill from toolkit/local into dogfooded-skills and import it back |
| [`setup-github`](skills/setup-github/) | Set up GitHub Actions workflows, labels, and project board |
| [`setup-harness`](skills/setup-harness/) | Scaffold the knowledge layer — ARCHITECTURE.md, QUALITY_SCORE.md, docs/, FlowChad flows |
| [`skill-builder`](skills/skill-builder/) | How to write a high-quality agent skill for this library |
| [`spec-plan`](skills/spec-plan/) | Relentless design interview — walk the decision tree one branch at a time |
| [`visual-evidence`](skills/visual-evidence/) | Playwright screenshots and GIF recordings for PR evidence |
| [`write-report`](skills/write-report/) | Structured report generation from data and findings |

## Design Principles

1. **Agent-agnostic** — skills work with any agent that supports the Vercel skill format
2. **Concrete over abstract** — every skill ships with real commands, not pseudocode
3. **Explicit gotchas** — if something can go wrong, the skill says so
4. **Decision tables** — when there are multiple paths, a table makes the choice clear
5. **Self-contained** — a skill can be dropped into any project and work without external docs

## Contributing

See the [`skill-builder`](skills/skill-builder/) skill for the complete authoring standard.

1. Write the skill following the skill-builder standard
2. Place it at `skills/<skill-name>/SKILL.md` (flat structure, no subdirectories)
3. Use only Vercel standard frontmatter: `name`, `description`, and optionally `allowed-tools`
4. Run it at least five times against real workloads
5. Open a PR — the benchmark results go in the PR body
