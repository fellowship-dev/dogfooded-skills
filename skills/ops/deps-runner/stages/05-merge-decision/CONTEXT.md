# Stage 05: Merge Decision (subagent)

## Inputs
- `.procedure-output/deps-runner/01-scan-context/handoff.md`
- `.procedure-output/deps-runner/03-risk-eval/handoff.md`
- `.procedure-output/deps-runner/04-build-test/handoff.md`
- `../../shared/risk-matrix.md` (merge-decision matrix)

## Task
For each PR, apply the merge-decision matrix from its (build, tests, risk) result: auto-merge
with [skip ci], label, write targeted tests, or flag for Max. This is the ONLY stage that
merges/labels PRs and may write targeted tests. Enforce the review pipeline.

## Steps

Use `ENV_ID` (preflight handoff) and `merge_strategy` (scan-context handoff). For each PR, look
up its risk (stage 03) and build/test result (stage 04), then apply `shared/risk-matrix.md`.

### Decision matrix (summary; full table in shared/risk-matrix.md)
- pass/pass/Low → auto-merge [skip ci] (or label if `merge_strategy: label-only`)
- pass/pass/Medium (no direct usage) → auto-merge [skip ci] (or label)
- pass/pass/Medium (direct usage) → **write targeted tests** (Phase 7b), then flag for review
- pass/pass/High → flag for Max
- build fail OR test fail OR stale-conflict → flag for Max

### Targeted tests (medium with direct usage)
```bash
gitpod environment ssh $ENV_ID -- \
  "cd /workspaces/\$(ls /workspaces/) && claude -p --dangerously-skip-permissions --verbose \
  'The dependency <package> was bumped from <old> to <new>. It is used in these files: <files>. Write a focused test that exercises the specific functionality we use from this library. Run the test and confirm it passes. Do NOT commit -- just create the test file and show results.'"
```
- Targeted tests pass → **flag for manual review** (Max sees the new tests and decides)
- Targeted tests fail → **flag for Max** with failure details
- Do NOT auto-merge PRs that needed new tests.

### Merge or label (safe PRs only) — pipeline enforcement
Before merging, verify the full review pipeline has run. Check for `reviewed` and
`double-checked` labels. Do NOT merge directly without these — the CTO owns the final merge.
```bash
PR_NUMBER=<number>
ORG_REPO="<org>/<repo>"

LABELS=$(gh pr view $PR_NUMBER --repo $ORG_REPO --json labels --jq '.labels[].name' 2>/dev/null)
HAS_REVIEWED=$(echo "$LABELS" | grep -c "^reviewed$" || true)
HAS_DOUBLE_CHECKED=$(echo "$LABELS" | grep -c "^double-checked$" || true)

MERGE_STRATEGY=$(python3 -c "
import yaml
with open('$PYLOT_DIR/crew.yml') as f:
    data = yaml.safe_load(f)
for team, cfg in data.get('crew', {}).items():
    if not isinstance(cfg, dict): continue
    for r in cfg.get('repos', []):
        if r.lower() == '$ORG_REPO'.lower():
            print(cfg.get('merge_strategy', 'auto'))
            exit()
print('auto')
" 2>/dev/null || echo "auto")

if [ "$MERGE_STRATEGY" = "label-only" ]; then
  gh label create "ready-to-merge" --repo $ORG_REPO --color "0e8a16" --description "Agent-verified, Max merges" 2>/dev/null || true
  gh pr edit $PR_NUMBER --repo $ORG_REPO --add-label "ready-to-merge"
elif [ "$HAS_REVIEWED" = "0" ]; then
  gh label create "reviewed" --repo $ORG_REPO --color "1d76db" --description "First-pass review complete" 2>/dev/null || true
  gh pr edit $PR_NUMBER --repo $ORG_REPO --add-label "reviewed"
  # Do NOT merge. Event router triggers double-check -> cto-review, then CTO merges.
elif [ "$HAS_DOUBLE_CHECKED" = "0" ]; then
  echo "PR has 'reviewed' but not 'double-checked'. Waiting for pipeline to complete."
else
  gitpod environment ssh $ENV_ID -- "gh pr merge $PR_NUMBER --repo $ORG_REPO --squash -t 'chore(deps): merge #$PR_NUMBER [skip ci]' -b 'Auto-merged dependency update. Build and tests verified in Ona container. Pipeline: reviewed + double-checked.'"
fi
```

### Write handoff (all PRs).

## Output: handoff.md

Path: `.procedure-output/deps-runner/05-merge-decision/handoff.md`

```markdown
# Stage 05: Merge Decision

## Per-PR Actions
| PR | Package | Risk | Build/Tests | Action | Detail |
|----|---------|------|-------------|--------|--------|
| #N | name | low/med/high | pass/pass | auto-merged [skip ci] / labeled reviewed / labeled ready-to-merge / wrote tests + flagged / flagged for Max | merge SHA, test path, or reason |

## Counts
merged: {N}   labeled-pipeline: {N}   tests-written: {N}   flagged: {N}   blocked: {N}
```

## Success criteria
- Every verified PR has an action applied per the matrix
- No High-risk PR auto-merged
- `[skip ci]` on every merge; pipeline labels enforced before any direct merge

## Failure
- A merge command errors (e.g. branch protection) → record `flag for Max` for that PR,
  continue with the rest. Never leave a PR in an ambiguous half-merged state silently.
