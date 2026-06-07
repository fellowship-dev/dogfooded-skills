# Stage 01: Scan & Context (inline)

## Inputs
- `$0` — target `org/repo` (from `$ARGUMENTS`)
- `$1` — Ona/Gitpod container or environment name (optional, from `$ARGUMENTS`)
- Repo CLAUDE.md and team CLAUDE.md (read inside the environment / from filesystem)

## Task
Establish the shared context every downstream stage depends on: the candidate dependency PRs,
the repo/team setup notes, the resolved environment ID, and the PR groups. This stage runs
inline in the orchestrator — do NOT spawn a Task. No side effects.

## Steps

1. Resolve `REPO` (`$0`) and the container/environment (`$1`).

2. Read the repo CLAUDE.md and team CLAUDE.md for container setup, deps-runner compatibility,
   `merge_strategy`, and project caveats.

3. Fetch ALL candidate dependency PRs — the report begins with what was picked up:
```bash
gh pr list --repo $REPO --label dependencies --json number,title,author,createdAt,headRefName,url
```
   (Also note any PRs without the `dependencies` label that are clearly dep bumps, per repo
   conventions in CLAUDE.md.)

4. Resolve the Ona environment ID (`ENV_ID`) for the target project. If none is running, note
   that stage 02 must spin one up (via the `ona-gitpod` skill).

5. Group the PRs for evaluation in stage 03 (e.g. by package family / companion packages such
   as react + react-dom, @strapi/strapi + @strapi/plugin-*). Grouping is for ORDERED cohesion,
   NOT for fan-out — stage 03 still processes all groups in a single sequential pass.
   Order groups lowest-risk-first (frontend devDeps/patches before backend runtime deps).

6. Detect repo type for the verification path:
```bash
# Python repo = requirements.txt or pyproject.toml exists; no test suite = no test_*.py files
# (recorded here so stage 04 knows to use docker build instead of a test suite)
```

7. Write handoff.

## Output: handoff.md

Path: `.procedure-output/deps-runner/01-scan-context/handoff.md`

```markdown
# Stage 01: Scan & Context

## Repo
{org/repo}

## Environment
ENV_ID: {id or "none — stage 02 must provision"}
container_arg: {$1 or "default"}

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
{container setup, deps caveats, project-specific rules}
```

## Success criteria
- Candidate PR list captured (empty list is valid — run still proceeds to produce a report)
- ENV_ID resolved or flagged as needing provisioning
- Repo type and merge_strategy recorded
- handoff.md written before any Task is spawned

## Failure
- `gh pr list` fails (auth/repo error) → record the error in handoff, set PR list empty, let
  the run continue to a report; the orchestrator notes the scan failure.
