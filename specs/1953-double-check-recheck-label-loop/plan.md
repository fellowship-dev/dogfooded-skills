# Implementation Plan: double-check re-check closes the rework loop via labels

**Branch**: `1953-double-check-recheck-label-loop` | **Date**: 2026-07-02 | **Spec**: `specs/1953-double-check-recheck-label-loop/spec.md`

## Summary

The double-check skill's stage 04-post must detect when it is running as a re-check (the PR
already has `needs-work`) and close the loop via labels rather than prose. On PASS: remove
`needs-work` + re-toggle `double-checked` so the `cto-review-on-double-checked` automation
re-fires automatically. On FAIL: keep `needs-work` + post a structured verdict comment with a
stable HTML marker so downstream tooling can distinguish a rework verdict from a mission failure.

The pylot automation layer (`event-reactions.mts`) is already compatible — confirmed in pre-flight.
**All code changes land in `fellowship-dev/dogfooded-skills`.** No changes in `fellowship-dev/pylot`.

## Repo Map

| Repo | Changes |
|------|---------|
| `fellowship-dev/dogfooded-skills` | `skills/ops/double-check/stages/04-post/CONTEXT.md` (primary), `skills/ops/double-check/SKILL.md` (exit-path docs) |
| `fellowship-dev/pylot` | **None** — automation compatibility pre-verified |

## Technical Context

- **Skill language**: Bash + `gh` CLI (agent-executed instructions in CONTEXT.md files)
- **Target files**: Markdown instruction files in dogfooded-skills; agents parse them at runtime
- **No compiled code**: changes are documentation/instruction edits only
- **Pylot compatibility**: `matchRule` in `event-reactions.mts:119-194` already re-fires on re-add;
  `MessageDeduplicationId` in `ingress.mts:55` uses `Date.now()` (unique per event)

## Design: Re-check Detection

Stage 04-post reads the stage-01 handoff which already records `Labels: {labels or none}`
(from `gh pr view --json labels`). If `needs-work` is in that labels list, it is a re-check run.

```
re-check context = "needs-work" appears in stage-01 handoff "## PR / Labels" field
```

Stage 01-setup requires NO change — it already captures labels.

## Design: PASS Re-check Behavior (verdict=ready AND re-check context)

```bash
# 1. Remove needs-work — clears the rework signal
gh pr edit $PR --repo $REPO --remove-label "needs-work"

# 2. Remove double-checked (if present) — needed so the re-add fires a new event
gh pr edit $PR --repo $REPO --remove-label "double-checked" 2>/dev/null || true

# 3. Re-add double-checked — fires pull_request.labeled → cto-review-on-double-checked
gh label create "double-checked" --repo $REPO --color "0075ca" --description "Double-checked by agent" 2>/dev/null || true
gh pr edit $PR --repo $REPO --add-label "double-checked"
```

### Why this does NOT create an infinite loop

The loop-break is structural:

1. Stage 04-post re-check PASS removes `needs-work` **before** re-adding `double-checked`.
2. cto-review fires (triggered by `double-checked` add) on a PR with NO `needs-work`.
3. cto-review outcome:
   - **PASS** → merge. Loop ends.
   - **FAIL** → cto-review applies `needs-work`. This starts a NEW rework cycle, not a
     re-trigger of double-check. The developer must push rework and re-trigger double-check
     again (which is correct behavior).
4. double-check itself does NOT re-trigger itself — it only re-fires cto-review via
   `double-checked` label. The `cto-review-on-double-checked` rule does not add `double-checked`.
5. Therefore: `double-checked` add → cto-review → [merge | add needs-work]. No cycle back to
   double-check without developer action.

### Edge case: `double-checked` not on PR (label manually removed before re-check)

Skip the remove step; just add `double-checked`. The event still fires.

## Design: FAIL Re-check Behavior (verdict=needs-work AND re-check context)

```bash
# Do NOT touch needs-work — it stays on the PR
# Do NOT re-toggle double-checked — cto-review must NOT fire

# Post structured verdict comment
gh pr comment $PR --repo $REPO --body "$(cat <<'COMMENT_EOF'
<!-- pylot:recheck-fail pr=$PR repo=$REPO -->
## Re-check Result: Still Needs Work

**PR:** $REPO#$PR — $PR_TITLE
**Re-check verdict:** needs more work

### Remaining items
{ordered list from stage-02 handoff Fix List / Verdict section}

### What to do
1. Address the items above.
2. Push your fixes.
3. Remove and re-add the \`double-checked\` label to re-trigger this re-check.
COMMENT_EOF
)"
```

### Idempotency: the `<!-- pylot:recheck-fail -->` marker

The HTML comment marker `<!-- pylot:recheck-fail pr={PR} repo={REPO} -->` is a stable identifier.

**Before posting**, stage 04-post MUST check for an existing re-check-fail comment to avoid
duplicate posts on agent retries:

```bash
EXISTING=$(gh pr view $PR --repo $REPO --json comments \
  --jq '.comments[].body | select(contains("pylot:recheck-fail"))' | head -1)
if [ -z "$EXISTING" ]; then
  gh pr comment $PR --repo $REPO --body "..."
fi
```

This makes re-check FAIL posting idempotent: a second invocation on the same PR state skips
the comment post because the marker already exists.

**Why this doesn't loop**: The FAIL path explicitly does NOT re-toggle `double-checked`. With
`needs-work` still on the PR and `double-checked` unchanged, no automation fires. The loop
is broken by inaction.

## Design: First-Check Path (no re-check context — current behavior, unchanged)

When `needs-work` is NOT in the stage-01 handoff labels, behavior is identical to the current
stage 04-post:
- Post curated review comment
- Apply `double-checked` label (create if needed)
- Write report file
- Emit outcome marker with verdict

No change to this path.

## File Changes

### `fellowship-dev/dogfooded-skills`: `skills/ops/double-check/stages/04-post/CONTEXT.md`

Insert a new section **before** the "Post the curated review comment" step:

```
### Detect re-check context (read from stage-01 handoff)

Read the `## PR / Labels` field from `.procedure-output/double-check/01-setup/handoff.md`.
If the labels list contains `needs-work`, this is a re-check run (IS_RECHECK=true).
```

Then add two new sections **after** "Post the curated review comment" and **replacing** the
current "Apply the double-checked label" section:

```
### Apply labels (re-check vs first-check)

**If IS_RECHECK=true AND verdict=ready (re-check PASS)**:
  1. Remove `needs-work` label
  2. Remove `double-checked` label (if present; 2>/dev/null || true for safety)
  3. Re-add `double-checked` label → fires pull_request.labeled → cto-review re-fires

**If IS_RECHECK=true AND verdict=needs-work (re-check FAIL)**:
  1. Do NOT touch labels
  2. Check for existing pylot:recheck-fail comment (idempotency guard)
  3. If none found, post structured verdict comment with <!-- pylot:recheck-fail --> marker

**If IS_RECHECK=false (first-check, any verdict)**:
  1. Apply `double-checked` label (create if not exists, then add) — existing behavior
```

Update the outcome marker line to include re-check context:
```
[pylot] outcome="double-checked {re-check PASS|re-check FAIL|first-check} {repo}#{pr} — ..." status=success
```

### `fellowship-dev/dogfooded-skills`: `skills/ops/double-check/SKILL.md`

Update the "Exit paths" section to document re-check outcomes:

```
- **Re-check PASS**: `[pylot] outcome="double-checked re-check PASS {repo}#{pr} — loop closed, cto-review re-fired" status=success`
- **Re-check FAIL**: `[pylot] outcome="double-checked re-check FAIL {repo}#{pr} — needs-work retained" status=success`
- **Success (first-check)**: `[pylot] outcome="double-checked {repo}#{pr} — verdict {ready|needs-work}, ..." status=success`
```

## Verification Plan

1. **Unit test** (manual trace): walk through stage 04-post logic with a PR having `needs-work`
   in labels, verdict=ready → confirm the three gh commands execute in order.
2. **Integration evidence** (on a real PR): trigger a double-check re-check cycle on a test PR,
   observe label removal + re-toggle, confirm cto-review dispatch without human intervention.
3. **Contrast evidence**: cite the fellowship-dev/pylot#1940 incident vs the new run.
