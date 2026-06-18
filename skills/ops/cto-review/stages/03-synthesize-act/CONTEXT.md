# Stage 03: Synthesize & Act (inline — orchestrator only)

## Inputs
- `.procedure-output/cto-review/01-setup/handoff.md`
- `.procedure-output/cto-review/02-review/handoff.md` (absent only on the short-circuit path)

## Task
Take action on the verdict: post the formatted GH review comment, apply the verdict label, merge or
label honoring merge state and CI, write the local report file, and emit the outcome marker. This
stage runs inline in the orchestrator — do NOT spawn a Task. All GH side effects and the

## Merge-state branching (decide FIRST, from stage 01 `merge_state`)

- **`closed-no-merge`** (short-circuit; stage 02 was skipped):
  Post nothing, label nothing, merge nothing. Write a one-line report noting the PR was closed
  without merge. Emit:
  ```
  ```
  STOP. (A closed-without-merge PR is a normal terminal state — not a blocker requiring human
  intervention. `status=blocked` would trigger an unnecessary escalation to the human operator.)

- **`merged`** (already merged):
  Post the review as a **post-merge note** (Step 1). Apply the verdict label (Step 2). Do NOT
  attempt any merge in Step 3 — skip merge entirely. Write the report (Step 4). Emit success with
  `action=post-merge-note`.

- **`open`**: full path — Steps 1-4 below, then emit success.

## Steps

### Step 1: Post the review comment
Use the exact template in `shared/review-comment-format.md`. Populate from the stage 01 and stage 02
handoffs:
```bash
gh pr comment $PR --repo $REPO --body "$(cat <<'COMMENT_EOF'
# CTO Review: $REPO PR #$PR — $PR_TITLE
... (see shared/review-comment-format.md — verbatim) ...
COMMENT_EOF
)"
```
For `merge_state: merged`, prefix the verdict line to make clear it is a post-merge note.
Capture the returned comment URL for the report.

### Step 2: Apply the verdict label
```bash
gh label create "approved" --repo $REPO --color "0e8a16" --description "CTO approved — ready to merge" 2>/dev/null || true
gh label create "needs-work" --repo $REPO --color "d93f0b" --description "Needs work before merge" 2>/dev/null || true

if [[ "$VERDICT" == "merge" ]]; then
  gh pr edit $PR --repo $REPO --add-label "approved"
elif [[ "$VERDICT" == "hold" || "$VERDICT" == "sendback" ]]; then
  gh pr edit $PR --repo $REPO --add-label "needs-work"
fi
```

### Step 3: Merge or label (OPEN PRs only — skip entirely if merge_state is `merged`)
Only proceed to a merge if ALL hold:
1. Stage 02 `merge_decision` is `merge` (verdict LGTM / "merge immediately").
2. Required labels present (`reviewed`, `double-checked`).
3. CI is green.

```bash
# Verify CI is green
gh pr checks $PR --repo $REPO

# Verify required labels
gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'
```
Use the `merge_strategy` resolved in stage 01:
```bash
if [ "$MERGE_STRATEGY" = "label-only" ]; then
  # Team requires human merge — label instead
  gh label create "ready-to-merge" --repo $REPO --color "0e8a16" --description "Agent-verified, Max merges" 2>/dev/null || true
  gh pr edit $PR --repo $REPO --add-label "ready-to-merge"
  echo "Labeled ready-to-merge (merge_strategy: label-only)"
else
  # Default: auto-merge
  gh pr merge $PR --repo $REPO --merge
fi
```
If CI is failing: do NOT merge — the verdict should already be hold; note the CI failure in the
comment if not already noted. Record the action taken: `merged` | `labeled` | `held`.

### Step 4: Write the report file (local only — NO Quest)
Use the template in `shared/report-format.md`:
```bash
REPORT_PATH="$PYLOT_DIR/reports/$(date +%Y-%m-%d)-cto-review-$(echo $REPO | tr '/' '-')-pr$PR.md"
```
(If `$PYLOT_DIR` is unset, use `$(git rev-parse --show-toplevel)/reports`.) Write the verdict, full
checklist, action items, and the posted comment URL into the file. There is NO Quest POST — the
report ends at the file write; operators surface it via the mission report.

### Step 5: Emit the outcome marker (orchestrator only)
```
```
On the closed-no-merge short-circuit, emit the `status=blocked` marker shown above instead.
If a side effect failed hard (comment post errored), emit:
```
```

## Output: handoff.md

Path: `.procedure-output/cto-review/03-synthesize-act/handoff.md`

```markdown
# Stage 03: Synthesize & Act

## Actions Taken
- merge_state: {open | merged | closed-no-merge}
- comment_posted: {url or "skipped (closed-no-merge)"}
- label_applied: {approved | needs-work | ready-to-merge | none}
- merge_action: {merged | labeled-ready-to-merge | held | skipped (already merged) | skipped (closed)}
- report_path: {path}

## Outcome
{the emitted [pylot] outcome marker, verbatim}
```

## Success criteria
- Comment posted (unless closed-no-merge), label applied per verdict, merge/label honoring merge
  state and CI, report file written (no Quest), outcome marker emitted from the orchestrator.

## Failure
- Comment post or label edit errors → emit the stage-03 failure marker; still write whatever report
  is possible (marker is the primary signal).
