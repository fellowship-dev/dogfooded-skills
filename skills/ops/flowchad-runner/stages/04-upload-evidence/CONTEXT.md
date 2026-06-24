# Stage 04: Upload Evidence — best-effort (subagent)

## Inputs
- `.procedure-output/flowchad-runner/02-load-flows/handoff.md` (read `evidence_backend`)
- `.procedure-output/flowchad-runner/03-walk-flows/handoff.md`
  (read the "Evidence to upload" list: snapshot dirs, GIFs, PNGs)

## Task
Push the per-flow evidence (screenshots + GIF) to the configured backend and collect the
resulting URLs for the report. **This is best-effort: upload failure NEVER blocks the run.**

## Steps

### 1. Read the evidence backend
Follow the **evidence-upload** skill pattern. Backend comes from `.flowchad/config.yml`
(`evidence_backend` in the stage 02 handoff; default `assets`).

### 2. Upload per flow

#### Assets backend (default)

Use the **evidence-upload** skill for each file. `$PYLOT_GATEWAY_URL` and
`$PYLOT_DISPATCH_TOKEN` are already available in every operator/worker environment — no
static AWS keys needed. Run `/evidence-upload` for each screenshot and GIF from the stage
03 handoff, then collect the returned `public_url` values for the report.

#### Fallback: git orphan-branch

If `evidence_backend` is explicitly set to `git` in `.flowchad/config.yml`, push
screenshots and GIFs to a git evidence branch instead:

```bash
# Git backend (explicit fallback): push screenshots + GIF to evidence branch
# Use GitHub Contents API — no local git operations needed
for screenshot in ${SNAPSHOT_DIR}/step-*.png; do
  # Upload via gh api or git push to evidence branch
done
```

Do this for each flow's snapshot dir from the stage 03 handoff. Capture the resulting URLs
for embedding in the report and GitHub comments.

### 3. On failure — degrade, don't block
If evidence upload fails, log a warning and continue. Evidence is best-effort and never
blocks the walk or the report. Record `upload_ok: false` with the reason; the report stage
will simply omit the missing URLs.

If the backend is `none`, skip uploading but still write the handoff (do not skip the stage).

## Output: handoff.md

Path: `.procedure-output/flowchad-runner/04-upload-evidence/handoff.md`

```markdown
# Stage 04: Upload Evidence

## Status
upload_ok: {true|false|skipped}
backend: {git|none|...}
note: {warning/reason if not ok, else "none"}

## Evidence URLs
| Flow | GIF URL | Screenshot base URL |
|------|---------|---------------------|
| {name} | {url or "—"} | {url or "—"} |
```

## Success criteria
- Handoff written for every walked flow (URL or `—`).
- Stage never blocks the chain regardless of upload result.

## Failure
- N/A as a blocker. Upload errors are recorded as `upload_ok: false` and the chain continues.
