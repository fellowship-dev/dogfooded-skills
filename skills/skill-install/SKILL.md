---
name: skill-install
description: Install one or more skills from dogfooded-skills into a Claude Code project — copy files, update CLAUDE.md skill table, verify.
user-invocable: true
argument-hint: "<skill-name> [target-project-path]"
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Skill Install

Install skills from the [`dogfooded-skills`](https://github.com/Fellowship-dev/dogfooded-skills) library into a Claude Code project.

## When to Use

- Adding a new skill to a project for the first time
- Updating an existing installed skill to the latest version
- Bulk-installing a set of skills into a new project

## Prerequisites

The library must be cloned locally:

```bash
ls dogfooded-skills/skills/ 2>/dev/null || \
  git clone https://github.com/Fellowship-dev/dogfooded-skills
```

The target project must have a `.claude/` directory (it's a Claude Code project):

```bash
ls <target-project>/.claude/
```

## Workflow

### Install a single skill

1. **Locate the skill** in the library:
   ```bash
   ls dogfooded-skills/skills/<skill-name>/
   ```
   If not found, check the [README](../../README.md) for the full catalog.

2. **Copy to the target project:**
   ```bash
   cp -r dogfooded-skills/skills/<skill-name> <target-project>/.claude/skills/
   ```

3. **Register in CLAUDE.md** — add a row to the project's skill table. Find the table:
   ```bash
   grep -n "skill" <target-project>/CLAUDE.md | head -20
   ```
   Add the row using the skill's `name` and `description` from its frontmatter:
   ```markdown
   | `skill-name` | One-line description from the skill's frontmatter |
   ```

4. **Verify:**
   ```bash
   ls <target-project>/.claude/skills/<skill-name>/SKILL.md
   grep "skill-name" <target-project>/CLAUDE.md
   ```

### Install multiple skills at once

```bash
TARGET=<target-project>/.claude/skills
for skill in skill-author skill-install <other-skills>; do
  cp -r dogfooded-skills/skills/$skill $TARGET/
  echo "Installed: $skill"
done
```

Then update CLAUDE.md with all new rows in one edit.

### Update an existing skill

Pull latest from the library and re-copy:

```bash
cd dogfooded-skills && git pull origin main && cd ..
cp -r dogfooded-skills/skills/<skill-name> <target-project>/.claude/skills/
```

> **Warning:** This overwrites any local modifications to the skill. If the project has diverged from the library version, diff before overwriting:
> ```bash
> diff -r dogfooded-skills/skills/<skill-name> <target-project>/.claude/skills/<skill-name>
> ```

## Project CLAUDE.md Skill Table Format

The skill table in CLAUDE.md typically looks like:

```markdown
## Skills

| Skill | Purpose |
|-------|---------|
| `ona-gitpod` | Manage Ona (Gitpod) cloud environments |
| `skill-install` | Install skills from dogfooded-skills library |
```

If the project doesn't have a skill table yet, add one. Find an appropriate heading (usually near the bottom, after project-specific instructions) and insert:

```markdown
## Skills

| Skill | Purpose |
|-------|---------|
| `<skill-name>` | <description from frontmatter> |
```

## Skills Directory Layout

After installation, the project's skills directory should look like:

```
.claude/
  skills/
    <skill-name>/
      SKILL.md          ← the skill itself
      <support-files>   ← scripts or reference data bundled with the skill
```

Every skill is self-contained in its own subdirectory. Installing a skill is always a directory copy — never a single-file copy.

## Error Handling

**Skill not found in library** — check the library README for the correct name. Skills use kebab-case: `deps-runner` not `depsRunner`.

**Target project has no `.claude/skills/` dir** — create it:
```bash
mkdir -p <target-project>/.claude/skills/
```

**CLAUDE.md has no skill table** — add one. See the format above.

**Skill already exists with local modifications** — diff before overwriting. If the local version has project-specific customizations, merge manually rather than overwriting.

## Critical Rules

- **Always install as a directory**, not as a single file — skills may bundle support files
- **Always register in CLAUDE.md** — a skill file that isn't referenced in CLAUDE.md won't be surfaced to Claude without explicit invocation
- **Diff before updating** — don't silently overwrite local customizations
