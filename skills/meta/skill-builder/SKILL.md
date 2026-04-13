---
name: skill-builder
description: Write a high-quality agent skill — covers frontmatter spec, section structure, quality criteria, and common antipatterns.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Skill Builder

How to write an agent skill that belongs in this library. Follow this standard exactly — every skill in `dogfooded-skills` was reviewed against it before merge.

## What Is a Skill?

A skill is a markdown file at `.claude/skills/<skill-name>/SKILL.md`. It is loaded into the agent's context when invoked via skill invocation or referenced in the project instructions file. It is **not** a prompt — it is a runbook: concrete commands, decision tables, and explicit gotchas that turn the agent into a domain expert.

A skill is NOT:
- A README explaining what a tool does
- A collection of examples for the user to read
- A configuration file
- A vague list of things to consider

A skill IS:
- Step-by-step instructions the agent executes, not reads
- Real commands with real flags, not pseudocode
- The authoritative source of truth for one capability

## File Structure

```
skills/
  <skill-name>/
    SKILL.md          ← required: the skill itself
    <support-files>   ← optional: scripts, templates, reference data
```

Skill names are kebab-case, lowercase. Use the shortest name that's unambiguous: `deps-runner`, not `dependency-update-runner`.

## Frontmatter

Every `SKILL.md` must start with YAML frontmatter:

```yaml
---
name: skill-name
description: One-line summary — used by the agent to decide relevance. Be specific.
allowed-tools: Read, Write, Bash, Glob, Grep  # optional — restrict tool use
---
```

### Field rules

**`name`** — matches the directory name. No spaces, no uppercase.

**`description`** — one line, plain English. The agent reads this to decide whether to invoke the skill. Bad: "Manage environments." Good: "Claim, start, SSH into, and release Gitpod cloud environments for CI/agent workloads."

**`allowed-tools`** — whitelist of tools this skill may use. Omit to allow all tools. Set when the skill should be restricted (e.g., a read-only audit skill).

## Section Structure

A skill must have these sections, in order:

### 1. One-line purpose (H1)

The title is the skill name. The first paragraph (no heading) is the one-sentence purpose. Example:

```markdown
# deps-runner

Run dependency update PRs through a verification pipeline — checkout, build, test, classify risk, auto-merge or flag.
```

### 2. When to Use (optional but recommended)

Bullet list of triggers. When should the agent invoke this skill vs. doing something else?

```markdown
## When to Use

- Dependabot or Renovate PRs that need automated verification
- Batch processing multiple dep updates for the same repo
- When you need a risk classification before merging
```

### 3. Prerequisites

Everything that must be true before the skill runs. Include verification commands.

```markdown
## Prerequisites

```bash
gitpod version && gitpod whoami  # Gitpod CLI authenticated
gh auth status                    # GitHub CLI authenticated
```

### 4. Core Workflow

The heart of the skill. Numbered steps, real commands, decision points clearly marked.

Rules:
- Use numbered steps for sequential operations
- Use `> **Warning:**` for steps where errors are common
- Wrap multi-line bash in fenced code blocks with `bash` lang
- Show expected output when it matters for verification
- Decision points use tables or `if/else` prose, not vague "depending on..."

Example:

```markdown
## Workflow

1. **List environments**
   ```bash
   gitpod environment list --timeout 60s
   ```
   Filter by repository URL. Count running/stopping envs for this repo.

2. **Check pool limits** — abort if count >= 3 (issue) or >= 2 (deps)

3. **Claim a stopped env** (prefer reuse over create)
   ```bash
   gitpod environment start {env-id} --set-as-context --dont-wait
   ```

   > **Check for active pilot before claiming:**
   > ```bash
   > gitpod environment ssh {env-id} -- "pgrep -x claude || echo NO_PILOT"
   > ```
   > If a `claude` process exists, this pod is occupied. Pick another.
```

### 5. Decision Tables

Use tables whenever there are multiple paths or risk tiers.

```markdown
## Risk Classification

| Condition | Risk | Action |
|-----------|------|--------|
| Patch update, build passes, tests pass | Low | Auto-merge with [skip ci] |
| Minor update, build passes | Medium | Flag for review |
| Major update or build fail | High | Block — manual review required |
```

### 6. Error Handling

Explicit failure modes and what to do. Not exhaustive — only the non-obvious ones.

```markdown
## Error Handling

**`pgrep -x claude` returns a PID** — pod is mid-mission. Do not claim. Pick a different env.

**Build fails on `bundle install`** — check Ruby version. Lexgo requires Ruby 3.2.x. Run `ruby -v` inside the env.

**`gitpod environment ssh` times out** — env may still be starting. Poll with `gitpod environment get {env-id}` and retry after 15s.
```

### 7. Critical Rules (optional)

Bullet list of absolute must-follow rules. Use when violations cause data loss, leaked resources, or security issues.

```markdown
## Critical Rules

- **Always release envs after use** — stopped envs cost nothing; leaked running envs burn credits
- **Never skip decontamination** — a stopped pod resumes with stale git state
- **One agent process per env** — two agents share a git working directory and corrupt each other
```

## Quality Checklist

Before submitting a skill, verify every item:

- [ ] Frontmatter is complete and valid YAML
- [ ] `description` is specific enough to distinguish from similar skills
- [ ] Every command in the skill was copy-pasted from a real terminal session
- [ ] Error handling covers the three most common failure modes
- [ ] No pseudocode — every step has a real, runnable command
- [ ] Decision points have tables or explicit conditions, not "it depends"
- [ ] No instructions to the *user* — all prose is addressed to the agent
- [ ] The skill has been run at least 5 times against a real workload

## Common Antipatterns

### Too vague

```markdown
# Bad
3. Run the appropriate command to start the environment.

# Good
3. Start the environment:
   ```bash
   gitpod environment start {env-id} --set-as-context --dont-wait
   ```
```

### Instructing the user instead of the agent

```markdown
# Bad
The user should verify that the environment is running before proceeding.

# Good
Verify the environment is running:
```bash
gitpod environment get {env-id} --timeout 15s | grep -i "running"
```
```

### Missing the "when not to use" case

A skill that can be over-applied is dangerous. If there are situations where the skill should NOT be invoked, say so explicitly.

```markdown
## When NOT to Use

- Major version upgrades with breaking changes — these need manual review
- PRs that touch `schema.rb` or database migrations
```

### Hiding gotchas in prose

Gotchas must be visually prominent. Use `> **Warning:**`, bold text, or a dedicated section. A gotcha buried in paragraph three will be missed.

## Template

Copy this as a starting point:

```markdown
---
name: your-skill
description: One specific sentence about what this skill does and for what context.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Your Skill

One sentence: what this skill does and why it exists.

## When to Use

- Trigger A
- Trigger B

## Prerequisites

```bash
# verification commands
```

## Workflow

1. **Step one**
   ```bash
   command here
   ```

2. **Step two** — decision point

   | Condition | Action |
   |-----------|--------|
   | Case A | Do X |
   | Case B | Do Y |

## Error Handling

**Common failure** — what to do.

## Critical Rules

- Rule 1
- Rule 2
```
