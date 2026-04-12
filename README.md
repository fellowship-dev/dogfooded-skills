# dogfooded-skills

A battle-tested library of Claude Code skills used internally at [Fellowship Dev](https://github.com/Fellowship-dev). Each skill in this library has been run hundreds of times in real production workflows before being published here.

## What Are Skills?

Claude Code **skills** are markdown files placed in `.claude/skills/<skill-name>/SKILL.md`. When invoked via the `Skill` tool (or referenced in `CLAUDE.md`), the skill's content is loaded into Claude's context — giving it persistent, reusable capabilities without burning prompt space on every message.

Skills are not prompts. They are **runbooks**: structured, concrete instructions with real commands, decision tables, and explicit gotchas. A good skill makes Claude behave like a domain expert, not a generalist guesser.

## Skill Catalog

### Meta

Skills about the skills system itself.

| Skill | Description | Invocable |
|-------|-------------|-----------|
| [`skill-author`](skills/skill-author/) | How to write a high-quality Claude Code skill for this library | Yes |
| [`skill-install`](skills/skill-install/) | How to install skills from this library into your project | Yes |
| [`migrate-skill`](skills/migrate-skill/) | Move a skill from toolkit/local into dogfooded-skills and import it back | Yes |

### Product

Skills for product development workflows.

| Skill | Description | Invocable |
|-------|-------------|-----------|
| [`spec-plan`](skills/spec-plan/) | Relentless design interview — walk the decision tree one branch at a time until shared understanding | Yes |
| [`build-prd`](skills/build-prd/) | Collaborative PRD creation from feature requests — 7-step workflow with GitHub integration | Yes |

## Quick Start

```bash
# Clone the library
git clone https://github.com/Fellowship-dev/dogfooded-skills

# Copy a skill into your project
cp -r dogfooded-skills/skills/skill-author .claude/skills/
```

Then add a row to the skill table in your project's `CLAUDE.md`:

```markdown
| `skill-author` | How to write a Claude Code skill |
```

That's it. Claude will read the skill when it needs it.

## Design Principles

1. **Concrete over abstract** — every skill ships with real commands, not pseudocode
2. **Explicit gotchas** — if something can go wrong, the skill says so
3. **Decision tables** — when there are multiple paths, a table makes the choice clear
4. **Minimal frontmatter** — only the fields Claude Code actually reads
5. **Self-contained** — a skill can be dropped into any project and work without external docs

## Contributing

See the [`skill-author`](skills/skill-author/) skill for the complete authoring standard.

In short:
1. Write the skill following the authoring standard
2. Run it at least five times against real workloads
3. Open a PR — the benchmark results go in the PR body
