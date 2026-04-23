---
name: hookshot
description: Read a repo's docs/ structure and generate Claude Code enforcement hooks — pre-edit reminders, skill-drift warnings, and markdown lint. Warning and guidance only; never auto-edits files.
argument-hint: "[--drift-warn] [--md-lint]"
user-invocable: true
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Hookshot

From docs to enforcement hooks. Reads what you've documented. Generates the hooks that make agents read it.

**Philosophy:** Hookshot only issues warnings and guidance. It never amends files, never lints-and-fixes. All hooks it generates emit messages to stderr and exit 0 — the agent decides whether to act.

## Modes

Hookshot is composable — invoke with one or more flags. Default mode (no flags) runs the doc-coverage generator.

| Flag | What it adds |
|------|--------------|
| *(no flag)* | **Doc coverage** — PreToolUse Edit/Write hook that nudges agents to read the relevant `docs/` section before editing a covered file. (Default behavior, documented below.) |
| `--drift-warn` | **Skill drift warning** — PreToolUse Edit/Write hook that warns when an agent edits a file inside `.claude/skills/<name>/` for a skill that's tracked in `skills-lock.json`. Edits should go upstream. |
| `--md-lint` | **Markdown lint** — PostToolUse Edit/Write hook that runs `npx markdownlint-cli2` on any changed `*.md` file and surfaces warnings. Never auto-fixes. |

Flags compose: `/hookshot --drift-warn --md-lint` installs both new hooks alongside the default doc-coverage hook. Re-running hookshot merges with existing hooks idempotently.

**Install via npx:**
```bash
npx skills add fellowship-dev/dogfooded-skills/ops/hookshot
```

## When to Use

- After `/setup-harness` creates the knowledge layer — hookshot wires it to the agent runtime
- After updating `docs/code-structure.md` or `docs/code-guidelines.md` — regenerate hooks to stay current
- When the `#1585-class bug` occurs: agent modified a critical path without reading docs — add a hook to prevent recurrence
- After adding a new FlowChad flow — generate hooks for that critical path

## Integration with Pylot

- **Installation:** `boot-skills.sh` installs the hookshot skill via `npx skills add`. But installing the skill ≠ generating hooks. You must run `/hookshot` at least once to generate the artifacts (`doc-coverage.json`, `check-docs.sh`, `settings.json` hooks, `docs/hooks.md`).
- **setup-harness:** Runs hookshot as its final phase on first setup. You don't need to run hookshot separately after setup-harness.
- **Staleness:** `entropy-check` monitors hookshot coverage freshness on PR merge and weekly cron. When it flags staleness, re-run `/hookshot`.
- **Per-repo:** Each repo gets its own hooks. Cross-repo missions use the target repo's hooks.

## Key Insight

> "Because the lints are custom, we write the error messages to inject remediation
> instructions into agent context." — OpenAI harness engineering

Hookshot makes this automatic. The agent would have been told "read how `check_redirect`
works before modifying this area" — this skill generates that message from your docs.

## What It Generates

1. **`check-docs.sh`** — Given a file being edited, outputs a doc reminder to stderr if that file is covered by docs/
2. **`.claude/settings.json` hooks** — PreToolUse hook calling `check-docs.sh` on every Edit/Write
3. **Domain coverage map** — `$REPO_ROOT/.claude/doc-coverage.json` — maps file globs to doc sections
4. **Custom lint messages** — Remediation instructions with specific doc section links

---

## Instructions

### 0. Identify the Repo

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename $(git remote get-url origin) .git)
mkdir -p $REPO_ROOT/.claude
```

### 1. Parse Knowledge Layer

Read all documentation files and extract coverage mappings:

```bash
# Read all key docs
cat $REPO_ROOT/docs/code-structure.md 2>/dev/null
cat $REPO_ROOT/docs/code-guidelines.md 2>/dev/null
cat $REPO_ROOT/ARCHITECTURE.md 2>/dev/null
ls $REPO_ROOT/.flowchad/flows/ 2>/dev/null
```

For each domain section in `docs/code-structure.md`, extract:
- **Domain name** (section header)
- **Directory path** (the "Directory:" line)
- **Key files** (from the Entry Points table)
- **Critical patterns** ("Don't Repeat" section — these are the highest priority)

For each FlowChad flow in `.flowchad/flows/`:
- **Flow name**
- **Domain**
- **Entry point file** (from the flow definition)
- **Files touched** (all `file:` entries in the flow)

### 2. Build Coverage Map

Create `$REPO_ROOT/.claude/doc-coverage.json`:

```json
{
  "version": "1",
  "generated": "{DATE}",
  "repo": "{REPO_NAME}",
  "entries": [
    {
      "glob": "app/controllers/**/*.rb",
      "domain": "Controllers",
      "doc_section": "docs/code-structure.md#controllers",
      "reminder": "Before modifying a controller, read how the controller pattern works: docs/code-structure.md#controllers. Key rule: controllers do not query the DB directly — use service objects.",
      "criticality": "high"
    },
    {
      "glob": "app/services/**/*.rb",
      "domain": "Services",
      "doc_section": "docs/code-structure.md#services",
      "reminder": "Service objects in app/services/ follow the Command pattern. Read docs/code-structure.md#services for the interface contract.",
      "criticality": "medium"
    }
  ]
}
```

Build one entry per domain directory mapping. For critical paths (found in FlowChad flows), set `criticality: "high"`.

**Reminder text rules:**
- Lead with the specific doc section to read
- Include the most important "Don't Repeat" rule for that domain
- Keep under 200 characters — this appears in agent context, not a wall of text
- Be actionable: "Read X" not "Consider reading X"

### 3. Generate check-docs.sh

Write `$REPO_ROOT/.claude/check-docs.sh`:

```bash
#!/usr/bin/env bash
# check-docs.sh — Generated by hookshot on {DATE}
# Usage: check-docs.sh <file_path_being_edited>
# Outputs doc reminders to stderr if the file is covered by docs/

set -euo pipefail

FILE_PATH="${1:-}"
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Normalize path relative to repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COVERAGE_MAP="$SCRIPT_DIR/doc-coverage.json"

if [ ! -f "$COVERAGE_MAP" ]; then
  exit 0
fi

# Check file against each glob in the coverage map
# Uses jq to parse coverage map and bash glob matching
REMINDERS=$(jq -r '.entries[] | "\(.glob)\t\(.reminder)\t\(.criticality)"' "$COVERAGE_MAP" 2>/dev/null)

FOUND_REMINDER=""
FOUND_CRITICALITY=""

while IFS=$'\t' read -r GLOB REMINDER CRITICALITY; do
  # Normalize the file path
  REL_PATH="${FILE_PATH#$REPO_ROOT/}"
  
  # Normalize for bash [[ ]] pattern matching:
  # 1. **/ → * (** has no special meaning; * already matches any char incl /)
  # 2. Escape [ ] so Next.js routes like [locale] are literal, not char classes
  GLOB="${GLOB//\*\*\//*}"
  GLOB="${GLOB//\[/\\[}"
  GLOB="${GLOB//\]/\\]}"
  
  if [[ "$REL_PATH" == $GLOB ]]; then
    FOUND_REMINDER="$REMINDER"
    FOUND_CRITICALITY="$CRITICALITY"
    break
  fi
done <<< "$REMINDERS"

if [ -n "$FOUND_REMINDER" ]; then
  if [ "$FOUND_CRITICALITY" = "high" ]; then
    echo "⚠️  DOCUMENTATION REMINDER (high criticality)" >&2
    echo "$FOUND_REMINDER" >&2
    echo "" >&2
    echo "This file is in a critical path. Read the doc section before proceeding." >&2
  else
    echo "📖 Doc reminder: $FOUND_REMINDER" >&2
  fi
fi

exit 0
```

Make it executable:
```bash
chmod +x $REPO_ROOT/.claude/check-docs.sh
```

### 4. Write Hooks to settings.json

Read the existing `.claude/settings.json` if it exists.
Merge in the hooks configuration — do not clobber existing hooks.

The hook to add:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash {REPO_ROOT}/scripts/check-docs.sh \"$(jq -r '.tool_input.file_path // empty')\""
          }
        ]
      }
    ]
  }
}
```

**Merge strategy:**
- If `PreToolUse` already exists → add to the array, don't replace
- If an identical `check-docs.sh` hook already exists → skip (idempotent)
- Preserve all existing hook entries

Write the merged result back to `.claude/settings.json`.

### 5. Generate Custom Lint Messages

For each guideline in `docs/code-guidelines.md`, generate a lint message file:

Create `$REPO_ROOT/.claude/lint-messages.md`:

```markdown
# Custom Lint Messages — {REPO_NAME}

Generated by hookshot on {DATE}. Used by PreToolUse hooks to inject remediation context.

## {Domain}: {Rule Name}

**Pattern detected:** {what triggers this message}
**Message injected into context:**
> {The exact message the agent will see}
**Doc reference:** docs/code-guidelines.md#{anchor}

---

{Repeat per rule}
```

For critical rules (e.g., "never roll your own auth", "use check_redirect not inline conditionals"), generate explicit check commands to add to `check-docs.sh`:

```bash
# Add to check-docs.sh after the glob check:

# Rule-based checks (pattern detection in file content)
if echo "$FILE_PATH" | grep -q "controllers/"; then
  # Check if file being written contains a raw redirect without check_redirect
  # (This is a hint — actual content checking happens post-edit)
  echo "📖 Controllers reminder: Use check_redirect in lib/redirect_service.rb for all redirects." >&2
fi
```

Add these rule-based checks to `check-docs.sh` in a clearly marked section.

### 5b. Generate docs/hooks.md

Generate a `docs/hooks.md` file in the target repo documenting the active hooks:

```markdown
# Hooks — {REPO_NAME}

> Auto-generated by [hookshot](https://github.com/fellowship-dev/dogfooded-skills). Safe to add notes — hookshot merges on update, it won't overwrite your additions.

## Active Hooks

### PreToolUse: Doc Reminders on Edit/Write

**Trigger:** Every `Edit` or `Write` tool call
**Script:** `scripts/check-docs.sh` (or `.claude/check-docs.sh`)
**Config:** `.claude/settings.json` → `hooks.PreToolUse`
**Coverage map:** `.claude/doc-coverage.json`

When an agent edits a file matching a covered glob, the hook injects a doc reminder into context before the edit proceeds. High-criticality files produce warnings; medium-criticality files produce reminders.

## Covered Domains

{For each entry in doc-coverage.json, list:}
| Domain | Glob | Criticality | Reminder |
|--------|------|-------------|----------|
| {domain} | `{glob}` | {criticality} | {reminder} |

## Maintaining Hooks

- **Quick tweaks:** Edit `.claude/doc-coverage.json` directly — add/remove entries, adjust criticality or reminder text. Changes take effect immediately.
- **Full regeneration:** Run `/hookshot` to rebuild coverage map from current `docs/code-structure.md`. This merges with your existing `doc-coverage.json` and `docs/hooks.md` — it won't overwrite manual additions.
- **Staleness detection:** `/entropy-check` monitors whether hooks are current vs docs. If it flags staleness, re-run `/hookshot`.

## Troubleshooting

### Glob doesn't match expected files
The hook uses bash `[[ ]]` pattern matching, which differs from gitignore globs:
- `**` has no special meaning — `*` already matches any character including `/`
- `[brackets]` are character classes, not literal — Next.js routes like `[locale]` need escaping
- The generated `check-docs.sh` normalizes both automatically. If you're writing manual globs, use `*` not `**/*` for recursive matching.

Test a glob: `bash scripts/check-docs.sh "/full/path/to/file.ts"`

### Hook breaks the agent or slows edits
Disable temporarily by removing the hook entry from `.claude/settings.json`. Re-run `/hookshot` to restore.

### settings.json got clobbered
Re-run `/hookshot` — it merges hooks into existing settings, never overwrites other config.
```

On re-runs, read the existing `docs/hooks.md` and merge: preserve any human-added sections, regenerate the "Covered Domains" table and "Active Hooks" section from current state.

### 6. Verification

Test the generated hook:

```bash
# Test with a file that should trigger a reminder
bash $REPO_ROOT/.claude/check-docs.sh "$REPO_ROOT/app/controllers/sessions_controller.rb"

# Test with a file that should NOT trigger
bash $REPO_ROOT/.claude/check-docs.sh "$REPO_ROOT/README.md"

# Verify settings.json is valid JSON
cat $REPO_ROOT/.claude/settings.json | jq . > /dev/null && echo "settings.json: valid JSON"

# Verify doc-coverage.json is valid JSON
cat $REPO_ROOT/.claude/doc-coverage.json | jq . > /dev/null && echo "doc-coverage.json: valid JSON"
```

### 7. Summary Report

```
## Hookshot Complete: {REPO_NAME}

### Coverage Map
- {N} domain entries in .claude/doc-coverage.json
- {N} high-criticality entries (will produce warnings)
- {N} medium-criticality entries (will produce reminders)

### Hooks Generated
- .claude/check-docs.sh — glob-based doc lookup
- .claude/settings.json — PreToolUse hook wired
- .claude/lint-messages.md — custom lint message catalog
- docs/hooks.md — human-readable hook documentation

### Coverage Gaps
{List any domains in ARCHITECTURE.md that have no glob coverage — need manual mapping}

### Manual Next Steps
- [ ] Review .claude/doc-coverage.json — adjust globs that are too broad or too narrow
- [ ] Test a real edit to a covered file and confirm the reminder appears
- [ ] Add rule-based checks for your most critical "Don't Repeat" patterns
- [ ] Run /entropy-check to verify grades reflect the new hook coverage
```

---

## Mode: Drift Warning (`--drift-warn`)

Warns when an agent is about to edit a file inside a `.claude/skills/<name>/` dir for a skill that's tracked in `skills-lock.json`. The actual edit is not blocked — this is guidance, and agents sometimes legitimately need to hotfix a synced skill before upstreaming.

### Generate `.claude/check-skill-drift.sh`

```bash
#!/usr/bin/env bash
# check-skill-drift.sh — Generated by hookshot (--drift-warn) on {DATE}
# Usage: check-skill-drift.sh <file_path>
# Warns to stderr if the file belongs to a skill tracked in skills-lock.json.

set -uo pipefail

FILE_PATH="${1:-}"
[ -z "$FILE_PATH" ] && exit 0

# Walk up from the file to find the nearest skills-lock.json
DIR="$(dirname "$FILE_PATH")"
LOCK_FILE=""
while [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
  if [ -f "$DIR/skills-lock.json" ]; then
    LOCK_FILE="$DIR/skills-lock.json"
    break
  fi
  DIR="$(dirname "$DIR")"
done
[ -z "$LOCK_FILE" ] && exit 0

# Path must contain /.claude/skills/<name>/ or /.agents/skills/<name>/
SKILL_NAME="$(echo "$FILE_PATH" | sed -nE 's|.*/\.(claude|agents)/skills/([^/]+)/.*|\2|p')"
[ -z "$SKILL_NAME" ] && exit 0

# Look up in lockfile
SOURCE=$(python3 -c "
import json, sys
try:
    data = json.load(open('$LOCK_FILE'))
    entry = (data.get('skills') or {}).get('$SKILL_NAME')
    if entry:
        print(entry.get('source', ''))
except Exception:
    pass
" 2>/dev/null)

if [ -n "$SOURCE" ]; then
  echo "⚠️  SKILL DRIFT WARNING" >&2
  echo "'$SKILL_NAME' is a remote skill synced from: $SOURCE" >&2
  echo "Local edits will drift from upstream and may be overwritten on next 'npx skills update'." >&2
  echo "Edit upstream at https://github.com/$SOURCE instead, or be prepared to PR the change back." >&2
fi

exit 0
```

Make it executable and wire into `.claude/settings.json` under `PreToolUse` with matcher `Edit|Write`. Merge-don't-clobber, same strategy as the default doc-coverage hook.

### Verification

```bash
# Should warn — cto-review is a tracked skill
bash .claude/check-skill-drift.sh "$PWD/.claude/skills/cto-review/SKILL.md"

# Should be silent — file is outside any skills dir
bash .claude/check-skill-drift.sh "$PWD/README.md"

# Should be silent — skill isn't in lockfile (e.g. a local-only skill)
bash .claude/check-skill-drift.sh "$PWD/.claude/skills/local-thing/SKILL.md"
```

---

## Mode: Markdown Lint (`--md-lint`)

Runs `npx markdownlint-cli2` on any changed `.md` file after an Edit or Write, and surfaces the warnings to the agent. Never auto-fixes — agent decides.

### Starter `.markdownlint.json`

If the repo has no `.markdownlint.json` or `.markdownlint-cli2.jsonc` at root, drop a permissive starter so the linter isn't overwhelming out of the box:

```json
{
  "default": true,
  "MD013": false,
  "MD033": false,
  "MD041": false
}
```

- `MD013` (line length) — off by default; docs and skill files often have long lines
- `MD033` (inline HTML) — off; we use HTML details/summary in reports
- `MD041` (first line must be h1) — off; many docs start with frontmatter

If a config already exists, leave it. Never overwrite.

### Generate `.claude/check-md-lint.sh`

```bash
#!/usr/bin/env bash
# check-md-lint.sh — Generated by hookshot (--md-lint) on {DATE}
# Usage: check-md-lint.sh <file_path>
# Runs markdownlint-cli2 on the file if it's *.md. Warns only — never fixes.

set -uo pipefail

FILE_PATH="${1:-}"
[ -z "$FILE_PATH" ] && exit 0

# Only lint markdown files
case "$FILE_PATH" in
  *.md|*.markdown) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0

# Run markdownlint-cli2 — fast start via npx
OUTPUT=$(npx --yes markdownlint-cli2 "$FILE_PATH" 2>&1) || true

if [ -n "$OUTPUT" ] && echo "$OUTPUT" | grep -qE 'MD[0-9]{3}'; then
  echo "📝 Markdown lint warnings for $(basename "$FILE_PATH"):" >&2
  echo "$OUTPUT" | grep -E 'MD[0-9]{3}' | head -20 >&2
  echo "(warnings only — no auto-fix. Run 'npx markdownlint-cli2 --fix <file>' manually if desired.)" >&2
fi

exit 0
```

Wire into `.claude/settings.json` under **`PostToolUse`** (not PreToolUse — the file must exist before it can be linted) with matcher `Edit|Write`.

### Verification

```bash
# Should print MD### warnings if the file has any lint issues
bash .claude/check-md-lint.sh README.md

# Should be silent — not a markdown file
bash .claude/check-md-lint.sh package.json
```

---

## Coverage Map Reference

The `doc-coverage.json` format supports these glob styles:

| Pattern | Matches |
|---------|---------|
| `app/controllers/**/*.rb` | Any Ruby file under controllers/ |
| `src/pages/**/*.tsx` | Any TSX file under pages/ |
| `lib/redirect_service.rb` | Exact file |
| `app/models/user.rb` | Exact file |
| `**/*_mailer.rb` | Any mailer anywhere |

Use specific globs for high-criticality files. Use broad globs for domain directories.
