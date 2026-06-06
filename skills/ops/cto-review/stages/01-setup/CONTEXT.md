# Stage 01: Setup — Gather Context, Diff, and Merge State (subagent)

## Inputs
- Arguments only: `PR_NUMBER` and `REPO` (org/repo). No upstream handoff.

## Task
Build everything the review stage needs in one place: repo architectural context, PR metadata, the
FULL diff, and the authoritative merge state. Detect the CLOSED-not-merged case and short-circuit so
the review stage is skipped.

## Steps

1. Set up environment and token:
```bash
export PR=$PR_NUMBER
export REPO=$REPO
export GH_TOKEN=$(grep 'GH_PAT_FELLOWSHIP' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)
```
(For a specific team, use the team's `token_var` from crew config instead.)

2. Verify prerequisites:
```bash
gh auth status
gh pr view $PR --repo $REPO   # verify PR exists
```

3. Fetch merge state FIRST — it gates everything downstream:
```bash
gh pr view $PR --repo $REPO --json state,mergedAt,mergeCommit,isDraft \
  --jq '{state:.state, mergedAt:.mergedAt, mergeCommit:.mergeCommit.oid, draft:.isDraft}'
```
- If `state == "CLOSED"` and `mergedAt == null` → **short-circuit**: this PR was closed without
  merging. Set `merge_state: closed-no-merge` and `short_circuit: closed-no-merge` in the handoff,
  skip the remaining gathering steps, and write the handoff. The orchestrator will skip stage 02.
- If `mergedAt != null` → the PR is **already merged**. Set `merge_state: merged`. Continue
  gathering so stage 02 can produce a post-merge review note; stage 03 will NOT attempt a merge.
- Otherwise (`state == "OPEN"`) → set `merge_state: open`. Continue normally.

4. Gather repo architectural context:
```bash
# Read repo CLAUDE.md for architectural direction
gh api repos/$REPO/contents/CLAUDE.md --jq '.content' | base64 -d 2>/dev/null || echo "(no CLAUDE.md)"

# Recent commit history
gh api "repos/$REPO/commits?per_page=10" --jq '.[].commit.message'

# Open issues — see what the team is working on
gh api "repos/$REPO/issues?state=open&per_page=10" --jq '.[].title'
```

5. Fetch PR metadata:
```bash
gh pr view $PR --repo $REPO --json number,title,body,headRefName,baseRefName,url,files,labels,author,additions,deletions,commits

# Existing labels
gh pr view $PR --repo $REPO --json labels --jq '.labels[].name'

# Changed file list
gh pr diff $PR --repo $REPO --name-only
```

6. Fetch the FULL diff (the review reads this whole, in cohesion):
```bash
gh pr diff $PR --repo $REPO
```
Also pull dependency-manifest changes explicitly so they are easy to spot:
```bash
gh pr diff $PR --repo $REPO -- "**/package.json" "**/Gemfile" "**/requirements.txt" "**/go.mod" "**/pyproject.toml"
```

7. Fetch CI status (the review and act stages must honor it):
```bash
gh pr checks $PR --repo $REPO || echo "CHECKS_UNAVAILABLE"
```

8. Resolve the team merge strategy (default `auto`):
```bash
MERGE_STRATEGY=$(python3 -c "
import yaml
with open('$PYLOT_DIR/crew.yml') as f:
    data = yaml.safe_load(f)
for team, cfg in data.get('crew', {}).items():
    if not isinstance(cfg, dict): continue
    for r in cfg.get('repos', []):
        if r.lower() == '$REPO'.lower():
            print(cfg.get('merge_strategy', 'auto'))
            exit()
print('auto')
" 2>/dev/null || echo "auto")
echo "merge_strategy=$MERGE_STRATEGY"
```
(Crew config may live in the DB rather than a YAML file; if `crew.yml` is absent, default `auto`.)

9. Write handoff (capture the full diff verbatim — stage 02 reviews it from here).

## Output: handoff.md

Path: `.procedure-output/cto-review/01-setup/handoff.md`

```markdown
# Stage 01: Setup

## PR Identity
- PR: #{N}
- Repo: {org/repo}
- Title: {title}
- URL: {url}
- Author: {author}
- Branch: `{headRefName}` -> `{baseRefName}`
- Labels: {comma-separated current labels}
- Additions/Deletions: +{N} / -{N}

## Merge State
- merge_state: {open | merged | closed-no-merge}
- mergedAt: {timestamp or null}
- mergeCommit: {oid or null}
- short_circuit: {none | closed-no-merge}
- ci_status: {passing | failing | pending | unavailable}
- merge_strategy: {auto | label-only}

## Repo Context
- CLAUDE.md direction: {summary or "(no CLAUDE.md)"}
- Recent commits: {bullet list}
- Open issues: {bullet list}

## PR Description / Linked Issue
{PR body; linked issue number+title if extractable from body or branch}

## Changed Files
{file list}

## Full Diff
```diff
{the complete `gh pr diff` output}
```

## Dependency-Manifest Changes
{manifest diff, or "none"}
```

## Success criteria
- Merge state resolved and recorded BEFORE gathering (gates the short-circuit).
- For `open`/`merged`: full diff, metadata, repo context, CI status, and merge strategy all captured.
- For `closed-no-merge`: `short_circuit: closed-no-merge` set; remaining gathering skipped.

## Failure
- PR does not exist or `gh auth` fails → write handoff with `status: error` and the reason; the
  orchestrator emits the failure marker.
