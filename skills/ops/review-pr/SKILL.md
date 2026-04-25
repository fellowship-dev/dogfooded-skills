---
name: review-pr
description: Read-only first-pass PR review — read diff, score findings by confidence, post structured comment, apply reviewed label. No checkout, no fixes. Chains into double-check pipeline.
argument-hint: "[pr-number] [org/repo]"
user-invocable: true
allowed-tools: Read, Bash, Glob, Grep, Agent
---

# review-pr

Read-only first-pass PR review. Reads the diff, checks repo conventions, scores findings by confidence, posts a structured review comment, and applies the `reviewed` label. Never checks out code, never fixes issues, never pushes commits — that's double-check's job.

## When to Use

- PR opened or reopened (event-triggered via `review-pr-on-opened` rule)
- Manual first-pass review before handing off to double-check
- Any PR that needs a quick read-through with structured feedback

## Invocation

```
/review-pr PR_NUMBER org/repo
```

**Examples:**
```
/review-pr 256 fellowship-dev/pylot
/review-pr 84 Lexgo-cl/rails-backend
```

## Token

Set `GH_TOKEN` in the environment before running. For Pylot crews, the team's `token_var` from `crew.yml` is used automatically.

## Pipeline Position

```
PR opened → review-pr (THIS SKILL) → `reviewed` label
  → double-check (active: checkout, fix, test, push) → `double-checked` label
    → flowchad (optional) → cto-review → merge/hold
```

This skill is the FIRST step. It is read-only analysis. It does NOT:
- Clone or checkout the repo
- Fix any issues
- Run tests
- Push commits
- Apply the `double-checked` label

---

## Runbook

### Step 0: Dedup Gate

```bash
export PR=$1
export REPO=$2

ALREADY_DONE=$(gh pr view $PR --repo $REPO --json labels --jq '[.labels[].name] | contains(["reviewed"])')
if [ "$ALREADY_DONE" = "true" ]; then
  echo "[pylot] outcome=\"already complete — reviewed label already applied\" status=success"
  exit 0
fi
```

### Step 1: Gather Context

```bash
# PR metadata
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')
PR_BRANCH=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')
ADDITIONS=$(gh pr view $PR --repo $REPO --json additions --jq '.additions')
DELETIONS=$(gh pr view $PR --repo $REPO --json deletions --jq '.deletions')
FILE_COUNT=$(gh pr view $PR --repo $REPO --json files --jq '.files | length')

# Repo conventions (best-effort)
gh api repos/$REPO/contents/CLAUDE.md --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo "(no CLAUDE.md)"

# Existing PR comments (avoid duplicating observations)
gh pr view $PR --repo $REPO --json comments --jq '.comments[].body'
gh pr view $PR --repo $REPO --json reviews --jq '.reviews[].body'

# CI status (best-effort)
gh pr checks $PR --repo $REPO 2>/dev/null || echo "CI checks not accessible"
```

### Step 2: Read the Diff

```bash
# Full diff
gh pr diff $PR --repo $REPO

# Changed file names (for quick overview)
gh pr diff $PR --repo $REPO --name-only
```

Read the diff carefully. Build a mental model of what changed and why. Focus on understanding intent before looking for issues.

### Step 3: Analyze and Score Findings

For each potential issue, assess:

**Severity:**
- **Bug** — logic errors, security issues, broken behavior, data loss risk
- **Warning** — potential issues worth investigating, edge cases, performance
- **Info** — style observations, suggestions, minor improvements

**Confidence (0–100):**
- **90–100**: Certain — clear bug, obvious security flaw, definite spec violation
- **80–89**: High — strong evidence, likely a real issue
- **70–79**: Moderate — plausible but uncertain (DO NOT INCLUDE — below threshold)
- **0–69**: Low — speculation, nitpick, or pre-existing issue (DO NOT INCLUDE)

**Only surface findings with confidence ≥ 80.**

**Mandatory filters — EXCLUDE these even if scored high:**
- Pre-existing issues not introduced by this PR
- Issues that linters/formatters will catch automatically
- Generic code quality nitpicks not backed by CLAUDE.md conventions
- Pedantic style preferences with no functional impact
- Moved/renamed code flagged as "new" (detect refactors)

**Verification step:** For each finding, actively try to disprove it. Check if the "bug" is actually handled elsewhere, if the "missing check" exists in a caller, if the "edge case" is prevented by the type system. Only findings that survive this check make the final list.

### Step 4: Convention Compliance

Check the diff against the repo's CLAUDE.md (if it exists). Flag violations of explicitly stated conventions. Do NOT invent conventions — only flag what the CLAUDE.md actually says.

If no CLAUDE.md exists, skip this section.

### Step 5: Closes vs Refs Check (MANDATORY)

```bash
gh pr view $PR --repo $REPO --json body --jq '.body' | grep -oE '(Closes|Fixes|Resolves) #[0-9]+' | grep -oE '[0-9]+'
```

For each linked issue with a `Closes` keyword:

```bash
gh issue view ISSUE_N --repo $REPO --json body --jq '.body' | grep -c '- \[ \]' || echo 0
```

If count > 0 → flag as **Bug** (confidence 100): PR uses `Closes #N` but issue has unchecked acceptance criteria. Must change to `Refs #N`.

### Step 6: Post Review Comment

```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'REVIEW_EOF'
## PR Review: $REPO#$PR — $PR_TITLE

**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`
**Size:** +$ADDITIONS / -$DELETIONS across $FILE_COUNT files

### Summary
[2-3 sentences: what this PR does, what problem it solves, and whether the approach is sound]

### Findings

| # | Severity | Location | Finding | Confidence |
|---|----------|----------|---------|------------|
| 1 | 🔴 Bug | `path/file.ts#L67-72` | [description] | 95 |
| 2 | 🟡 Warning | `path/other.ts#L23` | [description] | 85 |
| 3 | ℹ️ Info | `path/util.ts#L45` | [description] | 80 |

[If no findings ≥ 80 confidence: "No issues found above confidence threshold."]

### Convention Compliance
[Findings from CLAUDE.md — or "No CLAUDE.md found" / "All conventions followed"]

### Closes vs Refs
[Result of mandatory check — or "No Closes keywords found"]

### Verdict
[Clean — proceed to double-check / {N} findings to address — proceed to double-check]

REVIEW_EOF
)"
```

**Comment rules:**
- Always include the Summary — even if no findings, the summary helps the double-checker
- Empty findings table → write "No issues found above confidence threshold"
- Never write findings below 80 confidence — they are noise
- Location must reference file path and line numbers from the diff
- Verdict is always "proceed to double-check" — this skill never blocks

### Step 7: Apply reviewed Label

```bash
gh label create "reviewed" --repo $REPO --color "bfd4f2" --description "First-pass review complete" 2>/dev/null || true
gh pr edit $PR --repo $REPO --add-label "reviewed"
```

Only apply AFTER the comment posts successfully. This label triggers the `review-pr-on-reviewed` event rule, which dispatches double-check.

### Step 8: Write Report

```bash
REPORT_FILE="reports/$(date +%Y-%m-%d)-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```

Report format:
```markdown
# Review: $REPO PR #$PR — $PR_TITLE

**Date:** YYYY-MM-DD
**Repo:** $REPO
**PR:** [$REPO#$PR]($PR_URL)
**Branch:** `$PR_BRANCH` → `$BASE_BRANCH`
**Size:** +$ADDITIONS / -$DELETIONS across $FILE_COUNT files

## Summary

[What this PR does and why]

## Findings

[Findings table or "No issues found"]

## Convention Compliance

[CLAUDE.md check results]

## Verdict

[Clean / N findings — handed off to double-check]
```

Post to Quest DB (best-effort):
```bash
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
curl -s -X POST "http://127.0.0.1:4242/api/event" \
  -H "Authorization: Bearer $QUEST_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
content = open('$REPORT_FILE').read()
print(json.dumps({
  'source': 'commander',
  'type': 'commander.report',
  'title': 'Review: $REPO PR #$PR',
  'meta': {'content': content, 'report_type': 'review-pr'}
}))
")" 2>/dev/null || true
```

---

## Design Principles

Inspired by [Anthropic Code Review](https://github.com/anthropics/claude-code/tree/main/plugins/code-review) and [Devin Review](https://docs.devin.ai/work-with-devin/devin-review):

- **Confidence scoring with threshold** — kills false positives (Anthropic pattern)
- **Convention compliance from CLAUDE.md** — repo-specific, not generic (Anthropic pattern)
- **Only flag issues introduced in this PR** — never flag pre-existing problems (Anthropic pattern)
- **Severity categorization** (bug/warning/info) — clear signal for double-checker (Devin pattern)
- **Verification step** — try to disprove each finding before posting (Anthropic pattern)
- **Read-only** — review-pr reads, double-check fixes. Separation of judgment and execution (Pylot Principle III).

## Notes

- **This is the first step, not the last.** The verdict is always "proceed to double-check." This skill never blocks or rejects a PR.
- **Read-only means read-only.** No `git clone`, no `git checkout`, no file modifications. The diff comes from `gh pr diff`.
- **Confidence threshold is 80.** Below that, findings are noise. Don't lower it "to be thorough" — the double-check will catch anything real.
- **Convention compliance is opt-in.** Only repos with CLAUDE.md get convention checks. Don't invent rules.
- **The `reviewed` label is the handoff signal.** It triggers the event rule that dispatches double-check. Never apply `double-checked` — that's a different skill entirely.
