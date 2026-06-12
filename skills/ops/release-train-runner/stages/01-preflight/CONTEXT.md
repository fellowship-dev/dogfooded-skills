# Stage 01: Pre-Flight (subagent)

## Inputs
- `.procedure-output/release-train-runner/00-claim-compute/handoff.md`
  (REPO, PR_NUMBERS, DEFAULT_BRANCH, REMOTE_EXEC, REPO_DIR)

## Task
Build the PR manifest, validate every PR, and put the remote environment into a clean known
state on the default branch — ready for the release branch to be cut.

## Steps

1. Confirm the default branch (already in stage 00 handoff; re-verify if unset). Lexgo's
   rails-backend uses `develop` (gitflow: `develop`→staging, `master`→prod — never target
   `master`, pushing it deploys production), most others use `main` — never assume:
```bash
DEFAULT_BRANCH=$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name)
```

2. Fetch metadata for every PR and collect a manifest:
```bash
for PR in $PR_NUMBERS; do
  gh pr view $PR --repo $REPO --json number,title,headRefName,author,labels,additions,deletions,changedFiles,url,body
done
```

   | PR | Title | Author | Branch | LOC | Files | Labels |
   |----|-------|--------|--------|-----|-------|--------|

3. Validate each PR (record pass/fail; do NOT abort the train on a single failure):
   - State is `open` (not already merged or closed)
   - Base branch matches `$DEFAULT_BRANCH`
   - Not a draft

   Any PR that fails validation is marked **skipped** in the manifest with a reason and dropped
   from the merge list — the rest of the train continues.

4. Ensure the remote environment is clean:
```bash
$REMOTE_EXEC "cd $REPO_DIR && git fetch origin && git checkout $DEFAULT_BRANCH && git reset --hard origin/$DEFAULT_BRANCH && git clean -fd"
```

5. Write handoff.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/01-preflight/handoff.md`

```markdown
# Stage 01: Pre-Flight

## Status
preflight_ok: {true|false}   # false only if ZERO PRs remain valid

## Default Branch
{master|main|...}

## PR Manifest (merge order preserved)
| PR | Title | Author | Branch | LOC | Files | Labels | Valid |
|----|-------|--------|--------|-----|-------|--------|-------|
| #N | ... | @a | ref | +X/-Y | F | ... | yes |
| #M | ... | @b | ref | +X/-Y | F | ... | NO: {reason} |

## Valid Merge List (in order)
{space-separated PR numbers that passed validation, in provided order}

## Skipped at Preflight
- PR #M — {reason} (or "none")

## Environment
Clean checkout of {DEFAULT_BRANCH} confirmed on {REPO_DIR}
```

## Success criteria
- Manifest built for every input PR
- Each PR validated (open / base matches / not draft), pass-or-fail recorded
- Remote env reset to a clean `origin/$DEFAULT_BRANCH` checkout
- At least one valid PR remains → `preflight_ok: true`

## Failure
- Zero PRs pass validation → `preflight_ok: false`. Orchestrator emits `status=blocked` and
  stops (nothing to merge).
