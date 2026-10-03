# Stage 01: Setup (subagent)

## Inputs
- `pr` and `repo` (passed in the Task prompt)
- GitHub auth is ambient — the pod's `git-credential-pylot` helper and the `gh` shim mint
  short-lived App installation tokens per operation. No token env var is needed or set.

No upstream handoffs — this is the first stage.

## Task
Gather everything the review stage needs and prepare a clean local working tree:
PR metadata, CI status, the existing (first) review comments, the full diff, and a checked-out
base branch merged into the PR branch (resolving conflicts automatically where possible and
pushing so the PR stays current — merge, never rebase; see dogfooded-skills#161).

## Steps

```bash
export PR={pr}      # PR number
export REPO={repo}  # org/repo
```

### Fetch PR metadata

```bash
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits,headRefOid,comments

# Extract key info
PR_TITLE=$(gh pr view $PR --repo $REPO --json title --jq '.title')
PR_BRANCH=$(gh pr view $PR --repo $REPO --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view $PR --repo $REPO --json baseRefName --jq '.baseRefName')
PR_URL=$(gh pr view $PR --repo $REPO --json url --jq '.url')
INITIAL_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid')
printf '%s' "$INITIAL_HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$' || {
  echo "live head unavailable or malformed; write setup_ok: false blocked handoff"; exit 1;
}
```

### Check CI status (best-effort — may fail with PAT)

```bash
gh pr checks $PR --repo $REPO 2>/dev/null || echo "CI checks not accessible via token"
```

### Write the verbatim artifacts to files (shell, never retyped)

The PR body, the first review, the changed-file manifest and the full diff go to files **by
shell redirection**, next to the handoff. Never copy them into `handoff.md` through the Write
tool: retyping a large diff token by token was the single biggest setup cost (median 97 s,
up to 5+ min per cycle, measured on 40 pylot missions), and a retyped diff can drift from the
real one. A redirected file is byte-exact and costs nothing.

```bash
# Same directory as handoff.md. Absolute, because later steps cd into REPO_DIR.
OUT="$(pwd)/.procedure-output/double-check/01-setup"
mkdir -p "$OUT"
gh pr view $PR --repo $REPO --json body --jq '.body' > "$OUT/pr-body.md"
```

### Read existing review comments + the first review's head receipt

Capture ALL existing review comments verbatim, and extract the head SHA the latest first review
(review-pr) was bound to — its comment carries a `**Head reviewed:** \`<40-hex>\`` line:

```bash
{ set -o pipefail; gh pr view $PR --repo $REPO --json comments --jq '.comments[] | "### comment by \(.author.login) at \(.createdAt)\n\(.body)\n"'
  gh pr view $PR --repo $REPO --json reviews --jq '.reviews[] | "### review by \(.author.login) (\(.state))\n\(.body)\n"'
} > "$OUT/first-review.md" || echo "FIRST REVIEW FETCH FAILED — treat as unknown, not absent" >> "$OUT/first-review.md"
REVIEW_HEAD_SHA=$(gh pr view $PR --repo $REPO --json comments --jq '.comments[].body' \
  | sed -n 's/^\*\*Head reviewed:\*\* `\([0-9a-f]\{40\}\)`.*/\1/p' | tail -1)
```

Every finding from automated CI / the Claude GitHub App / bots is in `first-review.md` verbatim —
the review stage curates these in a clean context, so they must be carried over faithfully (never
pre-curated here). Read it yourself only as far as you need to fill the receipt fields.

### Read the full diff

```bash
# Full diff, whole and untruncated, straight to a file.
# GitHub refuses very large diffs (HTTP 406): then DIFF_FALLBACK=1, and the checkout step
# below regenerates diff.patch from git before the merge.
gh pr diff $PR --repo $REPO > "$OUT/diff.patch" || DIFF_FALLBACK=1

# Authoritative changed-file manifest with per-file line counts — stage 02 reconciles the
# PR body's claims against THIS list, so it must be complete and unedited.
gh pr view $PR --repo $REPO --json additions,deletions,files \
  --jq '"TOTAL +\(.additions)/-\(.deletions), \(.files|length) files", (.files[] | "\(.path)  +\(.additions)/-\(.deletions)")' \
  > "$OUT/changed-files.txt"
wc -l -c "$OUT"/pr-body.md "$OUT"/first-review.md "$OUT"/diff.patch "$OUT"/changed-files.txt
```

The review stage works only from this handoff and these four files. A failed or empty
`diff.patch` while `changed-files.txt` lists files is a setup failure (`setup_ok: false`), never a
silent gap: stage 02 treats what it is given as ground truth.

### Checkout PR branch + merge base into it

```bash
REPO_NAME=$(echo $REPO | cut -d/ -f2)
REPO_DIR="/tmp/double-check-$REPO_NAME"

if [ ! -d "$REPO_DIR" ]; then
  # Plain https URL — inline credentials would bypass git-credential-pylot
  git clone "https://github.com/$REPO.git" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch origin $PR_BRANCH
git checkout $PR_BRANCH
git pull origin $PR_BRANCH

# MERGE the base branch into the PR branch — never rebase (dogfooded-skills#161).
# A merge answers the only question that matters: does this branch integrate cleanly
# with base? Its conflict semantics match the squash merge the factory actually
# performs. Rebase replays old commits one-by-one, which (a) false-conflicts on
# branches that carry an earlier base-merge whose resolution rebase discards —
# exactly what blocked pylot#3177 on 2026-09-05 while a plain merge was clean —
# and (b) rewrites history, forcing a force-push that invalidates head-bound
# receipts even when nothing conflicted. "Linear history" buys nothing here: the
# final squash merge flattens the branch anyway. If already up to date, the merge
# is a no-op and the head SHA (and any current receipt) is preserved.
git fetch origin $BASE_BRANCH
if [ -n "$DIFF_FALLBACK" ]; then
  # Same range as `gh pr diff`: merge-base of base and the PR head, to the PR head (pre-merge).
  git diff "$(git merge-base origin/$BASE_BRANCH "$INITIAL_HEAD_SHA")" "$INITIAL_HEAD_SHA" > "$OUT/diff.patch" \
    || { echo "diff unavailable"; MERGE_FAILED=true; }
fi
if [ -z "$MERGE_FAILED" ] && ! git merge origin/$BASE_BRANCH --no-edit; then
  # Merge conflict — collect details, abort cleanly, report blocked
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
  git merge --abort 2>/dev/null || true
  echo "Merge conflict in: ${CONFLICT_FILES:-unknown files} — cannot auto-resolve, human intervention needed"
  # Fall through to write handoff with setup_ok: false
  MERGE_FAILED=true
fi

if [ -z "$MERGE_FAILED" ]; then
  # Plain push (no force needed — merge never rewrites existing commits).
  # If the merge was a no-op this pushes nothing and the head is unchanged.
  # --no-verify: this push carries only a clean, automatic base merge, no authored change
  # (a conflict already stopped above as blocked). Letting the repo's pre-push hook run its
  # test gate here cost 3.4 slot-hours over 40 pylot missions, one wide PR at a time, for code
  # that its author's push, CI and the release gate already test. Fix commits (stage 03)
  # are still tested.
  git push --no-verify origin $PR_BRANCH
  echo "Merged origin/$BASE_BRANCH into $PR_BRANCH and pushed — PR conflict cleared (or already current)"
fi

CURRENT_HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq '.headRefOid')
printf '%s' "$CURRENT_HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$' || MERGE_FAILED=true
if [ -z "$REVIEW_HEAD_SHA" ]; then
  REVIEW_RECEIPT_STATUS="absent"
elif [ "$REVIEW_HEAD_SHA" = "$CURRENT_HEAD_SHA" ]; then
  REVIEW_RECEIPT_STATUS="current"
else
  REVIEW_RECEIPT_STATUS="stale"
fi
```

If the merge cannot be auto-resolved (or the PR can't be fetched/checked out), write the
handoff with `setup_ok: false` and the reason — the orchestrator will treat this as a blocked exit.

## Output: handoff.md

Path: `.procedure-output/double-check/01-setup/handoff.md`

```markdown
# Stage 01: Setup

setup_ok: {true|false}

## PR
- Number: {PR}
- Title: {PR_TITLE}
- URL: {PR_URL}
- Branch: `{PR_BRANCH}` → `{BASE_BRANCH}`
- Author: {author}
- Size: +{additions} / -{deletions}, {N} files, {N} commits
- Labels: {labels or none}
- Initial HEAD SHA: {INITIAL_HEAD_SHA}
- Current HEAD SHA: {CURRENT_HEAD_SHA after any base merge}
- Setup head SHA: {CURRENT_HEAD_SHA, exactly 40 lowercase hex characters}

## Local Checkout
- REPO_DIR: {REPO_DIR}
- Checked out: `{PR_BRANCH}` with `{BASE_BRANCH}` merged in
- Base merge: {succeeded and pushed | no-op (already current) | failed: details}

## CI Status
{gh pr checks output, or "not accessible via token"}

## Artifacts (verbatim files, written by shell — not retyped here)
Absolute paths (`$OUT/...`):
- PR body: `{OUT}/pr-body.md` ({bytes} bytes) — the claims source stage 02 reconciles against
  the diff
- First review: `{OUT}/first-review.md` ({bytes} bytes)
- Changed files: `{OUT}/changed-files.txt` (TOTAL line: {copy the one TOTAL line here})
- Full diff: `{OUT}/diff.patch` ({lines} lines, untruncated)

## First-Review Receipt
- Receipt status: {current | stale | absent}
- Receipt head SHA: {REVIEW_HEAD_SHA or none}

`stale` is not a setup failure and does not restart the pipeline. It tells stage 02 not to treat
the old verification manifest as coverage of current HEAD.

```

Keep `handoff.md` short: metadata, receipt and the artifact pointers. Do not paste the body,
comments, manifest or diff into it.

## Success criteria
- `setup_ok: true`
- PR metadata and CI status in the handoff; PR body, first review, changed files and full diff
  written to their artifact files by shell redirection (never retyped)
- Full remote setup head recorded; a failed live read is blocked
- Changed-file manifest carries per-file line counts; the diff file is complete
- PR branch checked out in REPO_DIR, base merged in, and pushed; REPO_DIR recorded for downstream stages

## Failure
- PR not found / `gh` error → write handoff with `setup_ok: false` + reason (orchestrator emits a blocked outcome)
- Rebase conflict that cannot be auto-resolved → write handoff with `setup_ok: false` + conflict file list
  (orchestrator emits a blocked outcome; a human must resolve and re-dispatch)
