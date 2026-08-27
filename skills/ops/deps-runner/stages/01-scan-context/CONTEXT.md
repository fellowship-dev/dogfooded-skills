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

5. Group the PRs for evaluation in stage 03 (e.g. by package family / companion packages such
   as react + react-dom, @strapi/strapi + @strapi/plugin-*). Grouping is for ORDERED cohesion,
   NOT for fan-out — stage 03 still processes all groups in a single sequential pass.
   Order groups lowest-risk-first (frontend devDeps/patches before backend runtime deps).

6. Detect repo type for the verification path (inline via `gh api`, no worker needed):
```bash
# Node repo: repos/$REPO/contents/package.json exists
# Rails repo: repos/$REPO/contents/Gemfile exists
# Python repo = requirements.txt or pyproject.toml exists; no test suite = no test_*.py files
# (recorded here so stage 04 knows to use docker build instead of a test suite)
```

7. If `devbox_ready` is true, spawn the worker this run will use through stage 05. This is the
   LAST side-effecting step before the handoff write — every read-only lookup (PR list, CLAUDE.md,
   grouping, repo-type detection) happens first, so a spawn is never left unrecorded behind
   later reconnaissance work:
```bash
SPAWN=$(pylot workers spawn --mission "$PYLOT_JOB_ID" repo="$REPO" \
  name="deps-runner-$(echo "$REPO" | tr '/' '-')")
printf '%s' "$SPAWN" > .procedure-output/deps-runner/01-scan-context/.spawn-raw.json
WID=$(printf '%s' "$SPAWN" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("worker_id",""))
except Exception:
    print("")')
```
   The raw spawn response is written to disk **before** parsing is attempted, so a live worker
   is never traceable only through a variable that a crashed parse could lose — if `python3`
   raises on malformed/unexpected JSON, the `except` still prints an empty string (never lets
   the parse failure abort the step), and `.spawn-raw.json` remains on disk as the recovery
   record regardless of what `WID` ends up holding.

   201 means the spawn was accepted; boot to `RUNNING` takes ~1-2 min but prompts queue
   server-side, so stage 02 does not need to wait idle before sending its first prompt.

   - If `SPAWN` was non-empty (the API call itself succeeded) but `WID` comes back empty — the
     201 body didn't parse the way expected — do NOT treat this as `devbox_ready: false` and do
     NOT silently drop it: a worker may genuinely be running with no recorded id. Record
     `worker_id: UNKNOWN — spawn accepted but response did not parse; raw response saved to
     .spawn-raw.json` in the handoff, and instruct the orchestrator to resolve it before driving
     any further stage (`pylot workers list --mission "$PYLOT_JOB_ID"` to find the just-spawned
     worker by name and recover its id by hand).

8. Write handoff immediately after step 7 returns — do not run any further lookups or
   reconnaissance between step 7 and the handoff write. **Verify the write succeeded** (read the
   file back, or check the write command's own exit status) before considering stage 01 done. If
   the write fails, retry once; if it still fails, do not lose the worker's identity to a failed
   file write — surface `worker_id` (and, if `WID` was empty, the `.spawn-raw.json` path) directly
   in the orchestrator's own reply to the operator as an explicit blocker, so a human can stop the
   worker manually even though the durable handoff never landed.

## Output: handoff.md

Path: `.procedure-output/deps-runner/01-scan-context/handoff.md`

```markdown
# Stage 01: Scan & Context

## Repo
{org/repo}

## Worker
devbox_ready: {true|false}
worker_id: {id, or "none — devbox unavailable", or "UNKNOWN — spawn accepted but response did not parse; raw response saved to .spawn-raw.json"}
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
- The raw spawn response is persisted to `.spawn-raw.json` before parsing is attempted, whenever
  a spawn call is made — the recovery record exists independent of whether parsing succeeds
- handoff.md written before any Task is spawned, and its write is verified (read back or exit
  status checked) — a failed write is retried once, then surfaced directly to the operator

## Failure
- `gh pr list` fails (auth/repo error) → record the error in handoff, set PR list empty, let
  the run continue to a report; the orchestrator notes the scan failure.
- `pylot devboxes project` reports no `task_def` (or a `404 no_project`/`no_repo`) → set
  `devbox_ready: false`, do NOT attempt a spawn, and note in the handoff that stages 02-05
  are skipped — the orchestrator routes straight to 06-report (blocked).
- Spawn call succeeds (non-empty `SPAWN`) but `worker_id` parsing fails or returns empty → do
  NOT report `devbox_ready: false` (a worker may be live and unrecorded). Record
  `worker_id: UNKNOWN — spawn accepted but response did not parse; raw response saved to
  .spawn-raw.json` and treat it as a blocker requiring manual recovery before stages 02-05 drive
  anything, exactly as if worker identity could not be established.
- The handoff.md write itself fails after a successful spawn → retry once; if it still fails,
  do not let the worker go unrecorded anywhere — surface `worker_id` (and `.spawn-raw.json`'s
  path if `worker_id` was never parsed) directly in the orchestrator's reply to the operator as
  an explicit blocker.
