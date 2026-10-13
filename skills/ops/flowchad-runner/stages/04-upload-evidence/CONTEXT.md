# Stage 04: Upload Evidence — best-effort delivery, non-negotiable accounting (subagent)

## Inputs
- `.procedure-output/flowchad-runner/02-load-flows/handoff.md`
  (read `evidence_backend`)
- `.procedure-output/flowchad-runner/03-walk-flows/handoff.md`
  (read `worker_id` and the "Evidence to upload" list: per-flow `evidence_host`,
  snapshot dirs, GIFs, PNGs, and the step each file belongs to)

## Task
Push the per-flow evidence (screenshots + GIF) to the public evidence bucket, collect a **permanent**
public URL per file, and hand stage 05 a per-step mapping it can embed.

**Two rules that pull in opposite directions, and both hold:**

1. **Delivery is best-effort — an upload failure NEVER blocks the run.**
2. **Accounting is mandatory — an upload failure is NEVER silent.** Every file is either
   `uploaded` with a URL or `failed` with a reason, and the counts go into the handoff so
   stage 05 can put them in the verdict. A swallowed error reads as "no screenshots were
   needed", which is exactly how a verdict ends up being testimony instead of evidence.

## Steps

### 1. Read the evidence backend

From the stage 02 handoff. `s3` (the public evidence bucket) is the default and the only
supported backend; `none` means skip uploading (but still write the handoff). Stage 02 already
collapses `git`/`assets`/`pylot` down to `s3` — if you somehow see one here, treat it as `s3` and
note it.

### 2. Upload each file with evidence-upload

Follow the **evidence-upload** skill: `scripts/upload_evidence.sh --url-only --prefix <flow-slug>/<date> FILE...`.
It needs the `EVIDENCE_*` env secret on whichever host holds the files; without it the script
exits 2 with *"evidence upload secret is not configured for this environment"* — record every
file as `failed: no_secret`. URLs are content-addressed and permanent, and objects are served
inline with their real `Content-Type`, so the same URL works in the PR comment and in a chat
thread. Anything uploaded is public by URL: walk staging or synthetic data only.

#### Files on the operator (`evidence_host: operator` — Navvi-driven flows)

Run the script for each screenshot and GIF and collect the printed URL.

#### Files on the worker (`evidence_host: worker:<id>` — Playwright-driven flows, the common case)

The evidence lives on the worker devbox that stage 03 spawned. Do not copy files back. Prompt
the same worker with a self-contained loop that installs the public skill and prints one
`OK<TAB>FILE<TAB>URL` or `FAILED<TAB>FILE<TAB>reason` line per file, which you parse out of
`last_output`:

```bash
# Sent as a worker prompt, not run in the operator turn. The worker needs the EVIDENCE_* secret.
npx -y skills add fellowship-dev/dogfooded-skills --skill evidence-upload -y >/dev/null 2>&1
UPLOAD=$(ls ./.claude/skills/evidence-upload/scripts/upload_evidence.sh ./.agents/skills/evidence-upload/scripts/upload_evidence.sh 2>/dev/null | head -1)
for FILE in .flowchad/snapshots/${DATE}-${SLUG}/*.png .flowchad/snapshots/${DATE}-${SLUG}/*.gif; do
  [ -f "$FILE" ] || continue
  if URL=$(bash "$UPLOAD" --url-only --repo "$REPO" --prefix "${SLUG}/${DATE}" "$FILE" 2>/tmp/eu.err); then
    printf 'OK\t%s\t%s\n' "$FILE" "$URL"
  else
    printf 'FAILED\t%s\t%s\n' "$FILE" "$(tail -1 /tmp/eu.err)"
  fi
done
```

GIFs over ~10 MB render poorly on GitHub — convert to `mp4` or drop the GIF and keep the PNGs.
A failed GIF is a `failed` row, not a reason to abandon the flow's screenshots.

### 2b. If the run was requested from a conversation

Only when this mission carries a requesting conversation (`dispatched_by_conv`); empty is the
normal case. Record the uuid as `conversation_id` and copy the **one or two** URLs that carry the
verdict (the failing step, or the flow's terminal state on a pass) into `conversation_urls`.
No second upload is needed: bucket objects render inline everywhere.

### 3. Stop the worker

Stage 03 deliberately left the worker running so this stage could upload from it. **Stop it
here, and stop it even if every upload failed:**

```bash
curl -s --max-time 30 -X POST -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "${PYLOT_API:-$PYLOT_GATEWAY_URL}/missions/${PYLOT_JOB_ID}/workers/${WID}/stop" >/dev/null 2>&1 || true
```

Idempotent. If this stage is skipped or dies, stage 05 stops any `worker_id` it finds in the
stage 03 handoff as a backstop, and the harvest reaper is the last line of defence.

### 4. On failure — degrade, but say so

Record every failure with its reason (`no_secret` / `put` / `verify` / `unsupported` / `no_host`) and
keep going: partial evidence beats none. Do **not** silently rewrite a failure as "no evidence
produced", and do not fall back to a git branch — branch-hosted links die with the branch.

If the backend is `none`, skip uploading but still write the handoff (do not skip the stage).

## Output: handoff.md

Path: `.procedure-output/flowchad-runner/04-upload-evidence/handoff.md`

```markdown
# Stage 04: Upload Evidence

## Status
upload_ok: {true|partial|false|skipped}
backend: {s3|none}
uploaded: {N} / {M}
worker_stopped: {true|false|n/a}
conversation_id: {uuid or "none"}
note: {warning/reason if not fully ok, else "none"}

## Conversation URLs (only when conversation_id is set)
| Flow | Step | URL | Result |
|------|------|-----|--------|
| {name} | {step name} | {url or "—"} | uploaded / failed: {reason} |

## Per-step evidence URLs
| Flow | Step | File | URL | Result |
|------|------|------|-----|--------|
| {name} | {step name} | step-1-navigate.png | {url or "—"} | uploaded / failed: {reason} |

## Per-flow rollup
| Flow | GIF URL | Screenshots uploaded | Failures |
|------|---------|----------------------|----------|
| {name} | {url or "—"} | {N}/{M} | {reasons or "none"} |
```

`upload_ok: partial` is a first-class state — some files landed, some did not. Stage 05 must
print it rather than rounding it to success.

## Success criteria
- Handoff written for every walked flow, with a row per evidence file (URL or `—` + reason).
- Every URL in the handoff was printed by `upload_evidence.sh` (verified HTTP 200).
- `conversation_id` recorded (a uuid, or `none` — never omitted, so stage 05 knows the hop was
  evaluated rather than forgotten).
- Each URL is associated with the step it depicts, so stage 05 can embed per-step.
- The stage 03 worker is stopped.
- Stage never blocks the chain regardless of upload result.

## Failure
- N/A as a blocker. Upload errors are recorded as `upload_ok: false|partial` **with counts and
  reasons**, and the chain continues. Losing the accounting IS a stage failure, even though
  losing the upload is not.
