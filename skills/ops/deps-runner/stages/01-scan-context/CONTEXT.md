# Stage 01: Scan & Context (inline)

## Inputs
- `$0` — target `org/repo` (from `$ARGUMENTS`)
- Repo CLAUDE.md and team CLAUDE.md (read via `gh api`, no worker needed yet)

## Task
Establish the shared context every downstream stage depends on: the candidate dependency PRs,
the repo/team setup notes, the devbox worker's identity, and the PR groups. This stage runs
inline in the orchestrator — do NOT spawn a Task. The only side effects are the devbox
preflight check and (if the repo has a built image) the worker spawn itself.

## Steps

1. Resolve `REPO` (`$0`).

2. Read the repo CLAUDE.md and team CLAUDE.md for deps-runner compatibility, `merge_strategy`,
   and project caveats:
```bash
gh api "repos/$REPO/contents/CLAUDE.md" --jq '.content' | base64 -d
```

3. Fetch ALL candidate dependency PRs — the report begins with what was picked up:
```bash
gh pr list --repo $REPO --label dependencies --json number,title,author,createdAt,headRefName,url
```
   (Also note any PRs without the `dependencies` label that are clearly dep bumps, per repo
   conventions in CLAUDE.md.)

4. Preflight the target repo's devbox image:
```bash
pylot devboxes project "$REPO"
```
   No `task_def` in the response means no worker image was ever built for this repo, and a
   spawn would boot into `CannotPullContainerError`. Building one
   (`pylot deploy build-worker <org/repo> --wait`) needs an admin credential — an operator
   gets `403` — so this procedure cannot self-heal it. Record `devbox_ready: false` and the
   reason, and skip step 5 (no spawn). The orchestrator routes straight to stage 06 once this
   handoff is written.

5. If `devbox_ready` is true, spawn the worker this run will use through stage 05:
```bash
SPAWN=$(pylot workers spawn --mission "$PYLOT_JOB_ID" repo="$REPO" \
  name="deps-runner-$(echo "$REPO" | tr '/' '-')")
WID=$(printf '%s' "$SPAWN" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))')
```
   Record `worker_id` in the handoff below — every downstream stage reads it from there (or
   from the immediately-prior stage's handoff, since each stage forwards it unchanged).
   201 means the spawn was accepted; boot to `RUNNING` takes ~1-2 min but prompts queue
   server-side, so stage 02 does not need to wait idle before sending its first prompt.

6. Group the PRs for evaluation in stage 03 (e.g. by package family / companion packages such
   as react + react-dom, @strapi/strapi + @strapi/plugin-*). Grouping is for ORDERED cohesion,
   NOT for fan-out — stage 03 still processes all groups in a single sequential pass.
   Order groups lowest-risk-first (frontend devDeps/patches before backend runtime deps).

7. Detect repo type for the verification path (inline via `gh api`, no worker needed):
```bash
# Node repo: repos/$REPO/contents/package.json exists
# Rails repo: repos/$REPO/contents/Gemfile exists
# Python repo = requirements.txt or pyproject.toml exists; no test suite = no test_*.py files
# (recorded here so stage 04 knows to use docker build instead of a test suite)
```

8. Write handoff.

## Output: handoff.md

Path: `.procedure-output/deps-runner/01-scan-context/handoff.md`

```markdown
# Stage 01: Scan & Context

## Repo
{org/repo}

## Worker
devbox_ready: {true|false}
worker_id: {id, or "none — devbox unavailable"}
devbox_note: {task_def summary, or the blocker reason if devbox_ready is false}

## Repo Type
{node | rails | python-no-tests | other}
merge_strategy: {auto | label-only}
has_booster_remote: {unknown — checked in stage 02}

## Source PRs
| PR | Title | Author | Created | Branch | URL |
|----|-------|--------|---------|--------|-----|
| #N | ... | @bot | YYYY-MM-DD | branch | url |
[Total: N PRs picked up]

## PR Groups (ordered lowest-risk-first; for ordering, NOT fan-out)
1. {group name} → #N, #M
2. ...

## CLAUDE.md Notes
{deps caveats, project-specific rules}
```

## Success criteria
- Candidate PR list captured (empty list is valid — run still proceeds to produce a report)
- Devbox preflight run and recorded: either a live `worker_id`, or `devbox_ready: false` with
  a reason
- Repo type and merge_strategy recorded
- handoff.md written before any Task is spawned

## Failure
- `gh pr list` fails (auth/repo error) → record the error in handoff, set PR list empty, let
  the run continue to a report; the orchestrator notes the scan failure.
- `pylot devboxes project` reports no `task_def` (or a `404 no_project`/`no_repo`) → set
  `devbox_ready: false`, do NOT attempt a spawn, and note in the handoff that stages 02-05
  are skipped — the orchestrator routes straight to 06-report (blocked).
