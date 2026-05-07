# Implement

Dispatch a worker to run the full speckit pipeline on the target issue. Wait for completion and capture the result.

## Inputs

| Source | File/Location | Section/Scope | Why |
|--------|--------------|---------------|-----|
| Previous stage | `.procedure-output/speckit-proc/01-triage/triage.md` | Full file | Issue context and dedup decision |
| Reference | `references/worker-dispatch.md` | Full file | Prompt template and dispatch mechanics |

## Process

1. Read the triage output. Extract issue number, repo, title, and context summary.

2. Start the worker environment (if `PYLOT_HEALTH_GATE_URL` is set):
   ```bash
   /start-worker
   ```
   Wait for health gate to pass. Skip if no health gate is configured.

3. Build the worker prompt using the template in `references/worker-dispatch.md`. Include issue number, repo, and key context from triage.

4. Spawn the worker:
   ```bash
   bash scripts/spawn-worker.sh "$ENV" "$JOB_ID" "$SESSION" "$REPO_DIR" "$PROMPT" "$MODEL"
   ```

5. Wait for worker completion:
   ```bash
   bash scripts/wait-for-worker.sh "$ENV" "$HANDLE" "$JOB_ID" "$SESSION"
   ```
   On exit code 2 (stall): read last 30 lines of worker log, retry spawn (max 3 attempts).

6. Stop the worker environment:
   ```bash
   /stop-worker
   ```

7. Read worker log tail. Find the `[pylot] outcome=` marker. Record worker exit status.

8. Check for a PR via GitHub API:
   ```bash
   gh pr list --repo $1 --state open --json number,title,headRefName --limit 10
   ```
   Match by branch name or issue reference in the title.

9. Write implementation output with: worker status, outcome text, PR number (if any), branch name, log excerpt.

## Audit

| Check | Pass Condition |
|-------|---------------|
| Worker completed | Outcome marker found in worker log |
| PR created | `gh pr list` returns at least one matching PR |

## Outputs

| Artifact | Location | Format |
|----------|----------|--------|
| Implementation result | `.procedure-output/speckit-proc/02-implement/result.md` | Markdown: worker status, PR number, branch, outcome, log excerpt |
