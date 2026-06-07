# Stage 00: Claim Compute (inline)

## Inputs
- `$ARGUMENTS` — repo (`$0`), PR numbers in order (`$1 $2 ...`), optional trailing `(instructions)`
- Team CLAUDE.md — for Ona project ID / env name pattern
- `$HOME/projects/fellowship-dev/claude-buddy/.env` — `CODESPACE_TOKEN` (Codespaces fallback)

## Task
Claim a remote compute environment for the train and resolve the `REMOTE_EXEC` and `REPO_DIR`
abstractions all downstream stages depend on. **All work happens on remote compute. NEVER merge
locally.** This stage runs inline in the orchestrator — do NOT spawn a Task — so the claimed env
handle stays stable across stages.

## Steps

1. Parse `$ARGUMENTS`: `REPO=$0`; `PR_NUMBERS` = the remaining bare integers in order; capture any
   trailing `(...)` as complementary instructions.

2. Determine the default branch (needed to create envs):
```bash
DEFAULT_BRANCH=$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name)
```

3. Try **Ona** first if the project has it set up. Look up the Ona project ID / env name pattern
   from the team CLAUDE.md:
```bash
gitpod environment list 2>&1 | grep -i "<repo-name>"
```
   - Stopped env → `gitpod environment start <ENV_ID>`
   - No env but project exists → `gitpod environment create --project <PROJECT_ID>`
   - No project → fall back to Codespaces (step 4)

4. **Codespaces** fallback:
```bash
export GH_TOKEN=$(grep '^CODESPACE_TOKEN=' $HOME/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2)

CS_NAME=$(gh cs create \
  --repo $REPO \
  --branch $DEFAULT_BRANCH \
  --machine basicLinux32gb \
  --idle-timeout 120m \
  --retention-period 1h \
  --display-name "release-train-$(date +%m%d)")
```
   Preference: Ona if available (warm env, deps installed); Codespaces otherwise.

5. Resolve the environment abstraction for downstream stages:
   - `REMOTE_EXEC` = `gitpod environment ssh $ENV_ID --` OR `gh cs ssh -c $CS_NAME --`
   - `REPO_DIR` = workspace dir on remote (e.g. `/workspaces/rails-backend`)

6. Write handoff.

## Output: handoff.md

Path: `.procedure-output/release-train-runner/00-claim-compute/handoff.md`

```markdown
# Stage 00: Claim Compute

## Status
compute_ok: {true|false}

## Run Inputs
- REPO: {org/repo}
- PR_NUMBERS (merge order): {space-separated, in order}
- Instructions: {complementary instructions or "none"}
- DEFAULT_BRANCH: {master|main|...}

## Compute
- Provider: {ona|codespaces}
- Handle: {ENV_ID or CS_NAME}
- REMOTE_EXEC: {exact command prefix}
- REPO_DIR: {workspace path}

## Started
{ISO timestamp}
```

## Success criteria
- A remote environment is claimed and reachable
- `REMOTE_EXEC` and `REPO_DIR` resolved to concrete values
- PR numbers captured in the provided merge order
- handoff.md written before any Task is spawned

## Failure
- No Ona project and Codespaces creation fails → `compute_ok: false`, document reason.
  Orchestrator emits `status=blocked` and stops (no remote compute, no train).
