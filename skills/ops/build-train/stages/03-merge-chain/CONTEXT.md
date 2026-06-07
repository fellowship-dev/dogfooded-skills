# Stage 03: Merge Chain (subagent)

## Inputs
- `.procedure-output/build-train/00-setup/handoff.md` — repo, build branch
- `.procedure-output/build-train/02-build-fanout/handoff.md` — PRs ready to merge

## Task
Merge each build-train PR into the build branch, resolving conflicts. Merge in dependency order
(prerequisites first) so that dependent PRs apply cleanly on top of their prerequisite's changes —
follow the wave order from stage 01 / the build table.

## Steps

1. Collect the PR list from stage 02's "PRs ready to merge" (skip any issue marked `failed`/`skipped`).

2. Merge each PR into the build branch, in wave order:
```bash
for PR in $BUILD_TRAIN_PRS; do
  gh pr merge $PR --repo $REPO --merge --admin
done
```

3. Resolve conflicts (same policy as release-train):
   - **Lockfiles** (package-lock.json, yarn.lock, Cargo.lock, etc.): regenerate.
   - **Adjacent lines**: keep both.
   - **Irreconcilable**: skip that PR, log the reason, continue with the rest.

4. **Never force push** the build branch.

5. Write handoff.

## Output: handoff.md

Path: `.procedure-output/build-train/03-merge-chain/handoff.md`

```markdown
# Stage 03: Merge Chain

## Merges
| PR | Issue | Result | Conflict handling |
|----|-------|--------|-------------------|
| #50 | #10 | merged | none |
| #51 | #14 | merged | lockfile regenerated |
| #52 | #16 | skipped | irreconcilable conflict in src/app.ts |

## Merged into build branch
{count} of {attempted} PRs

## Skipped PRs
{PR + reason, or "none"}
```

## Success criteria
- Every ready PR either merged or skipped-with-reason
- Build branch never force-pushed
- Conflicts resolved per policy; irreconcilable ones skipped, not broken

## Failure
- `gh pr merge` error on one PR → log it, skip that PR, continue with remaining PRs
- Zero PRs merged → write handoff with `Merged: 0`; stage 04 has nothing to ship
