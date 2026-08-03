# Stage 04: Upload Evidence — best-effort delivery, non-negotiable accounting (subagent)

## Inputs
- `.procedure-output/flowchad-runner/02-load-flows/handoff.md`
  (read `evidence_backend`)
- `.procedure-output/flowchad-runner/03-walk-flows/handoff.md`
  (read `worker_id` and the "Evidence to upload" list: per-flow `evidence_host`,
  snapshot dirs, GIFs, PNGs, and the step each file belongs to)

## Task
Push the per-flow evidence (screenshots + GIF) to the assets backend, collect a **permanent**
public URL per file, and hand stage 05 a per-step mapping it can embed.

**Two rules that pull in opposite directions, and both hold:**

1. **Delivery is best-effort — an upload failure NEVER blocks the run.**
2. **Accounting is mandatory — an upload failure is NEVER silent.** Every file is either
   `uploaded` with a URL or `failed` with a reason, and the counts go into the handoff so
   stage 05 can put them in the verdict. A swallowed error reads as "no screenshots were
   needed", which is exactly how a verdict ends up being testimony instead of evidence.

## Steps

### 1. Read the evidence backend

From the stage 02 handoff. `assets` is the default and the only supported backend;
`none` means skip uploading (but still write the handoff). Stage 02 already collapses a
config that asks for `git` down to `assets` — if you somehow see `git` here, treat it as
`assets` and note it.

### 2. Upload each file — evidence-class, or the receipts expire

Follow the **evidence-upload** skill, and pass **`--evidence-class visual`** for every file.

> This is not optional. Without it the capability URL 410s after 30 days
> (`PYLOT_PUBLIC_TOKEN_TTL_DAYS`, #2622 M7) and the verdict's screenshots rot —
> [fellowship-dev/pylot#2063](https://github.com/fellowship-dev/pylot/pull/2063)'s
> screenshots are already unreadable for exactly this reason. `evidence_class` also
> requires `override_policy: true` at publish or the gateway returns
> **403 `publish_restricted_evidence_class`**. See evidence-upload's
> "Pick the retention mode FIRST" section for the verified request shapes and the
> attachment-disposition caveat.

`$PYLOT_GATEWAY_URL` and `$PYLOT_DISPATCH_TOKEN` are present in every operator **and**
worker environment — no static AWS keys.

#### Files on the operator (`evidence_host: operator` — Navvi-driven flows)

Run `/evidence-upload --evidence-class visual` for each screenshot and GIF and collect the
returned `public_url`.

#### Files on the worker (`evidence_host: worker:<id>` — Playwright-driven flows, the common case)

The evidence lives on the worker devbox that stage 03 spawned, and **workers cannot read
operator skills**. Do not try to copy files back. Instead, prompt the same worker with a
self-contained upload loop (the 4-step flow from evidence-upload, inlined) and have it print
one `OK<TAB>FILE<TAB>URL` line per file, which you parse out of `last_output`:

```bash
# Sent as a worker prompt, not run in the operator turn.
for FILE in .flowchad/snapshots/${DATE}-${SLUG}/*.png .flowchad/snapshots/${DATE}-${SLUG}/*.gif; do
  [ -f "$FILE" ] || continue
  case "$FILE" in *.png) CT=image/png ;; *.gif) CT=image/gif ;; *) continue ;; esac
  BYTES=$(wc -c < "$FILE")
  PRESIGN=$(curl -sS -X POST "$PYLOT_GATEWAY_URL/assets/presign" \
    -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"repo\":\"$REPO\",\"content_type\":\"$CT\",\"size\":$BYTES,\"evidence_class\":\"visual\"}")
  AID=$(echo "$PRESIGN" | python3 -c "import sys,json;print(json.load(sys.stdin)['asset_id'])") \
    || { printf 'FAILED\t%s\tpresign\n' "$FILE"; continue; }
  UP=$(echo "$PRESIGN" | python3 -c "import sys,json;print(json.load(sys.stdin)['upload_url'])")
  curl -sS -X PUT "$UP" --data-binary @"$FILE" -H "Content-Type: $CT" -o /dev/null \
    || { printf 'FAILED\t%s\tput\n' "$FILE"; continue; }
  URL=$(curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$AID" \
    -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H 'Content-Type: application/json' \
    -d '{"visibility":"public","override_policy":true}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('public_url',''))")
  [ -n "$URL" ] && printf 'OK\t%s\t%s\n' "$FILE" "$URL" || printf 'FAILED\t%s\tpublish\n' "$FILE"
done
```

GIFs over 25 MB are rejected by presign — convert to `video/mp4` or drop the GIF and keep the
PNGs. A rejected GIF is a `failed` row, not a reason to abandon the flow's screenshots.

### 2b. If the run was requested from a conversation — a second, unclassed copy

Only when this mission carries a requesting conversation. Resolve it once, up front:

```bash
CONV=$(curl -sS "$PYLOT_GATEWAY_URL/missions/$PYLOT_JOB_ID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("dispatched_by_conv") or "")')
```

**Empty is the normal case — skip this step entirely.** `flowchad-on-double-checked`
fires the vast majority of runs and is automation-dispatched: no requester, no thread,
nothing to deliver. Only a run someone asked for ("walk the checkout flow on #123")
has a `dispatched_by_conv`, and that owner is reading the thread, not the PR.

When `CONV` is set, pick the **one or two** shots that carry the verdict — the failing
step, or the flow's terminal state on a pass — and upload each a **second** time with
**no** `evidence_class`, publishing with `conversation_id` instead of `override_policy`:

```bash
# Same presign/PUT as above but WITHOUT "evidence_class", then:
curl -sS -X PATCH "$PYLOT_GATEWAY_URL/assets/$AID" \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"visibility\":\"public\",\"conversation_id\":\"$CONV\",\"alt\":\"$STEP_NAME\"}"
```

Two uploads of the same bytes is deliberate, not waste. The classed copy is permanent
but is served `Content-Disposition: attachment`; the unclassed copy is served `inline`,
which is what makes it render in the thread at all. See evidence-upload's *"One image
with two destinations is two uploads"* — and delete this second upload when pylot#2834
child 14 makes disposition MIME-driven.

Record the resulting `public_url`s under `conversation_urls` in the handoff so stage 05
can post them into the Slack thread. A failure here is a `failed` row like any other and
**never** touches the classed URLs the PR comment depends on.

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

Record every failure with its reason (`presign` / `put` / `publish` / `size` / `no_host`) and
keep going: partial evidence beats none. Do **not** silently rewrite a failure as "no evidence
produced", and do not fall back to a git branch — branch-hosted links die with the branch.

If the backend is `none`, skip uploading but still write the handoff (do not skip the stage).

## Output: handoff.md

Path: `.procedure-output/flowchad-runner/04-upload-evidence/handoff.md`

```markdown
# Stage 04: Upload Evidence

## Status
upload_ok: {true|partial|false|skipped}
backend: {assets|none}
evidence_class: visual
uploaded: {N} / {M}
worker_stopped: {true|false|n/a}
conversation_id: {uuid or "none"}
note: {warning/reason if not fully ok, else "none"}

## Conversation copies (unclassed, inline — only when conversation_id is set)
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
- Every asset destined for the PR comment carries `evidence_class: visual`, so its URL does not
  expire — and every conversation copy carries **no** class, so it renders inline.
- `conversation_id` recorded (a uuid, or `none` — never omitted, so stage 05 knows the hop was
  evaluated rather than forgotten).
- Each URL is associated with the step it depicts, so stage 05 can embed per-step.
- The stage 03 worker is stopped.
- Stage never blocks the chain regardless of upload result.

## Failure
- N/A as a blocker. Upload errors are recorded as `upload_ok: false|partial` **with counts and
  reasons**, and the chain continues. Losing the accounting IS a stage failure, even though
  losing the upload is not.
