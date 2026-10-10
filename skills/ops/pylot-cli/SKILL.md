---
name: pylot-cli
description: Use when operating the Pylot gateway through its CLI — dispatch, monitor, secrets, assets, workers, and automations.
user-invocable: false
allowed-tools: Bash, Read
---

## Choose the execution mode

Work with a human in the loop belongs on a devbox, not a mission. Missions are
autonomous operator runs (cron, auto-pylot, skill-routed tasks).

Devboxes are isolated environments by default, so they do not need Git
worktrees. Work in the devbox's normal repository checkout; do not create
worktrees inside it. Select the intended branch and base there, preserve existing
changes, and verify the application and tests in that checkout. If a branch
change interrupts an app service, recover through the documented devbox
lifecycle rather than creating another checkout.

- Use an **autonomous mission** when the task contract is complete enough for a
  worker to execute, review, and report without live steering. Dispatch it and
  let the factory own the implementation loop.
- Use an **interactive devbox** when the work genuinely requires live choices,
  iterative diagnosis, cross-worker relays, or frequent user direction. The
  active session owns prompts, verification, snapshots, and shutdown.
- Interactive does not imply continuous steering. Prefer one self-contained
  prompt that lets the selected skill or runner own its normal phases, then
  wait for a question, failure, or result before adding direction.
- Do not turn an autonomous mission into an interactive one merely because its
  progress can be watched. If a recurring mission needs steering, improve the
  factory skill that should have handled the case.

## Dispatch a Mission

```bash
CONV_ID=$(ls ~/.claude/session-env/ | head -1)
pylot dispatch "<task>" --agent <team>.<role> --repo <org/repo> --context "conversation_id=$CONV_ID"
```

Always pass `--context conversation_id=…` for auto-wake. Every dispatch payload must satisfy:

- **`/skill` prefix**: task text must start with an explicit `/skill`; free text fails at boot with `routing failed: task has no explicit /skill` (exit 1, zero tokens) — except the `auto-pylot` and `investigate … report findings` keyword fallbacks.
- **`team.role`**: team names and roles drift, so `pylot teams list` is truth and `pylot route` validates a `<team>.<role>` before you spend a dispatch.
- **Prompt size**: ~2560 bytes (`ECS_OVERRIDES_LIMIT_BYTES` 8192 − `DISPATCH_OVERRIDES_RESERVED_BYTES` 5632) — put full specs in issue comments.
- **No secrets**: the task contract must be self-contained and contain no secrets.

**Cross-org:** the repository owner and the selected credential are separate
inputs. Outside the CLI's default org, select the credential explicitly with the
global option first: `pylot --org <Org> context <Org>/<repo> …`. A plain
`403 forbidden` from an unscoped cross-org call does not prove the repo, playbook
or capability is unavailable — retry with the repo's org before diagnosing
authorization. `pylot auth status` shows which orgs hold a credential.

Before diagnosing credentials, record the actual CLI executable and `pylot
--version`, selected gateway base URL, and explicit `--org <Org>`. For the hosted
service the gateway is `https://hooks.fellowship.dev`; `pylot.fellowship.dev` is
the web app. HTML instead of JSON, an absent flag, or an unscoped cross-org denial
requires checking routing/version first. Use credential-status diagnostics only
after those checks; never print credential stores, tokens, or full environments.

## Monitor Missions

```bash
pylot missions list                      # recent missions
pylot missions view <job-id>             # full detail
pylot missions logs <job-id> --follow    # tail CloudWatch logs
```

Terminal statuses: `done`, `failed`, `cancelled`, `timeout`.

## Secrets Discovery

```bash
pylot secrets tree                       # full secrets tree
pylot secrets get <path>                 # bundle keys + fingerprints (no values)
```

Load into conversation: `pylot conversations resources-add <conv-id> type=secret ref=pylot/<path>`

## Assets

You do not have S3; you have the assets API. Anything durable — a screenshot, a
long report, a recording — has to go through `pylot assets`, never a direct
write and never a link to somewhere else. Never `raw.githubusercontent.com` on
a feature branch, never a static S3 key: both rot once the branch or retention
window is gone — see the [Hosting and durability
rule](https://github.com/fellowship-dev/pylot/blob/develop/docs/visual-evidence.md#hosting-and-durability-rule)
for the receipts.

**Three lifetimes** — pick the one that matches what you're making, before you make it:

| Lifetime | What it's for | How |
|---|---|---|
| Ephemeral scratch | A draft you're still iterating on in this turn | nothing — stays in-turn |
| Resumable checkpoint | A private draft/report that must survive a turn ending | `presign --conversation <id>` → `PUT` → `finalize` (finalize takes only `--sha256`/`--size`, no scope flag) |
| Published artifact | Evidence meant for a human or another repo (screenshot, PR proof) | the full presign → finalize → publish recipe below |

Do not reach for `publish --conversation <id>` as a shortcut or retry path for a
checkpoint — it sets `visibility: public`, which is a privacy regression for
what is meant to be a private draft. Ownership is already fixed at `presign`
time via `--conversation <id>`; there is no separate "attach to conversation"
step for a checkpoint.

A checkpoint's retention is not tied to `evidence_class` — there is no special
TTL exemption for it. `retention_policy` already defaults to indefinite, so
passing it explicitly changes nothing. That said, in staging every asset (any
class, any `retention_policy` value) still auto-expires after 30 days — an
S3 object-lifecycle rule outside the API, with no per-asset override. Treat a
staging checkpoint as staging-ephemeral: good for surviving a turn boundary,
not a substitute for promoting the finished artifact once the report is done.
See [Retention](https://github.com/fellowship-dev/pylot/blob/develop/docs/assets.md#retention)
for the full policy.

Ephemeral scratch is not durable: a turn can end more abruptly than a normal
function return drops it (see the [Lambda Freeze
Convention](https://github.com/fellowship-dev/pylot/blob/develop/docs/lambda-freeze.md)
for that failure shape in miniature). Concrete trigger, don't wait for a
vaguer sense of "running low": if a `context capacity` system message shows up
in the conversation (fires at ~90% of context, per issue #944), that turn is
your last chance — checkpoint what you have as a private conversation asset
before you do anything else. If no such message has fired yet but you're
about to end a turn with a report still incomplete, checkpoint anyway; the
warning is a backstop, not a permission slip to wait for it.

Use the CLI for the complete Pylot asset lifecycle. The only operation outside
the CLI is the direct `PUT` to the short-lived presigned object URL; never call a
Pylot gateway asset endpoint with `curl`.

```bash
FILE=/path/to/evidence.png
CONTENT_TYPE=image/png
SIZE=$(wc -c < "$FILE" | tr -d ' ')
if command -v sha256sum >/dev/null 2>&1; then
  SHA256=$(sha256sum "$FILE" | awk '{print $1}')
else
  SHA256=$(shasum -a 256 "$FILE" | awk '{print $1}')
fi

# Choose the ownership scope required by the destination: --repo, --job, or --conversation.
PRESIGN=$(pylot assets presign \
  --content-type "$CONTENT_TYPE" --size "$SIZE" \
  --repo <org/repo> --filename "$(basename "$FILE")" \
  --evidence-class visual --retention-policy <repo-policy>)  # use the retention policy required by the owning repo (e.g. indefinite, 90d)
ASSET_ID=$(printf '%s' "$PRESIGN" | jq -r '.asset_id')
UPLOAD_URL=$(printf '%s' "$PRESIGN" | jq -r '.upload_url')

# The presigned URL carries its own credentials; do not add a Pylot auth header.
curl -fsS -X PUT "$UPLOAD_URL" -H "Content-Type: $CONTENT_TYPE" --data-binary @"$FILE" && \
  pylot assets finalize "$ASSET_ID" --sha256 "$SHA256" --size "$SIZE"
```

`visual` is the evidence class for screenshots and recordings intended as
durable review evidence. Use the retention and evidence policy required by the
owning repo; do not class a transient conversation image as permanent evidence
unless that is intentional.

After finalization, use the verb that matches the destination:

```bash
pylot assets view "$ASSET_ID"                              # metadata + temporary GET URL
pylot assets attach "$ASSET_ID" --mission "$PYLOT_JOB_ID" # private mission evidence
pylot assets publish "$ASSET_ID"                          # public capability URL
pylot assets publish "$ASSET_ID" --conversation <id> --alt "description"
pylot assets unpublish "$ASSET_ID"                         # revoke public capability URL
```

Publishing returns `public_url`. Start with ordinary publish. Add
`--override-policy` only when the owning policy explicitly calls for an audited
override or the server returns the corresponding policy restriction; never use
it preemptively to bypass policy. Conversation publishing
both publishes and attaches the asset; `attach --mission` records private mission
evidence without publishing it. All six lifecycle actions — `presign`, `finalize`,
`view`, `attach`, `publish`, and `unpublish` — remain gateway operations and must
go through `pylot assets`.

## Team Settings

One command, one round-trip, visible proof — prints the value read back from
the server after the PATCH (#3094):

```bash
pylot teams config <team> deploy.release_mode=ship   # dotted-path set + read-back
pylot teams config <team> budget_daily_usd=600
pylot teams get <team> --fields deploy,cron          # scoped read of stored config
pylot teams update <team> key=value [...]            # multi-field PATCH (no read-back print)
```

Mutable fields (server-validated; a 400 lists the live set as `valid_fields`):
`budget_daily_usd` `enabled` `org` `chains` `provider_chain` `cron` `fargate`
`fargate_size` `deploy` `operators` `worker_images` `repos` `distill_enabled`
`context_warn_pct` `context_hard_pct` `slack_channels`.

Read-back guarantee: a field the server cannot persist is rejected with 400 —
never accepted-and-dropped (the round-trip corpus test enforces this; team-level
`skills` was removed from the set for exactly that reason — operator skills live
under `operators.<role>.skills`). If a write "succeeds" but reads back null,
that is a bug — file it; do not retry with creative payloads.

## Runner contract

A skill whose name ends in `-runner` is **run from outside a devbox and requires
one**. That is the whole definition. It applies wherever the caller sits: a
Pylot operator on a cron, or this session on this Mac spawning a devbox through
the gateway. Consequences:

- A runner never executes the engine itself. It spawns or targets a devbox,
  sends the prompt, polls, verifies, and reports. If you catch yourself running
  the engine's steps inline, you are in the wrong skill.
- A runner depends on **engine skills being installed inside the devbox** (for
  example `improve-code-quality-runner` needs `improve-code-quality` and
  `test-in-staging` in the worker). Today that dependency is a prose line in
  the runner's Prerequisites and nothing installs it; the worker only has the
  engine if the target repo vendors it. Until the Pylot frontmatter contract
  and worker-boot install land (fellowship-dev/pylot#3540), check
  the target repo's `.claude/skills/` before dispatching a runner at it.
- Engines carry no suffix and must work inside any checkout with no gateway
  access. Wrappers that only dispatch a worker on a schedule are runners too,
  and stay private in `pylot-skills`.
- `pylot skills list --kind runner` is the filter contract for runners.

## Preflight and dispatch

Before dispatch, confirm:

- the authenticated CLI can reach Pylot;
- the live team, role, skill route, repository, worker image, and budget support
  the selected mode;
- relevant automations will not duplicate or conflict with the work;
- the task contract is self-contained, contains no secrets, and names the
  intended skill explicitly.

Dispatch through the CLI and retain the returned mission or worker identifier.
Do not substitute raw gateway calls or undocumented local state. For evidence
and assets, follow `pylot-cli`; do not reproduce its lifecycle here.
For substantial remote work, settle branch/base, Git identity and evidence
visibility up front, and prove a small authorized durable checkpoint early.
Do not accumulate hours of work before discovering that publication is blocked.
Preserve prior scoped authorization; distinguish an actual tool rejection from
an agent's interpretation, and investigate the latter using current evidence.
After recovery or compaction, verify claimed blockers against actual tool receipts
and the accepted task. A missing named model tool does not establish that an
installed CLI is unavailable; check its help through the available shell. Resume
with concrete bounded actions, preserved authority and explicit artifact destinations
rather than an elaborate handoff narrative. Never override an actual access denial.

## Workers — Spawn, Drive, Stop

A worker is a Fargate devbox running the target repo. Ownership is by scope:
`spawn` and `list` need **exactly one** of `--mission` / `--conversation`; the
per-worker verbs take `--mission` or fall back to the unscoped `/workers/:wid`
route. Verify flags with `--help` — image CLIs vary in age.

### 1. Preflight the repo

```bash
pylot devboxes project <org/repo>    # → task_def{family,revision}, required_env_ok
```

No `task_def` means no image was ever built and the spawn boots into
`CannotPullContainerError`. Build first: `pylot deploy build-worker <org/repo> --wait`
(admin credential — an operator gets 403; see §6). Spawn failures are typed:
`404 no_project`/`no_repo` (repo not in any team's devbox config), `409` mission
already terminal, `422 provider_required`, `502` ECS/secrets.

### 2. Choose reuse, resume, or spawn

For another round of the **same active deliverable**, first inspect its recorded
worker, scope, task ARN and completed turn. Reuse a running, healthy devbox and
its native context after the checks below; a new round alone is not a reason to
spawn or start a fresh native session. Never borrow another owner's box or
reuse an incompatible repository, execution identity or unfinished turn.

- **Warm reuse:** continue the recorded worker when its prior turn is complete,
  native identity is intact, and workspace/application checks still pass.
- **Resume:** if that worker is stopped, use §4's verified snapshot and durable
  restore procedure, then verify native continuity and application readiness.
- **Spawn:** use a new box when no compatible reusable worker exists or an
  explicit recovery decision requires it. Record why reuse was unsuitable.

Keep warm reuse within the authorized working window and budget. Prefer short
idle exposure and verified stop when the active work ends; do not add keepalive,
raise TTL, or hold compute overnight to improve a timing result. Record resource
lifetimes and allocated CPU/memory separately from measured billed cost; an
allocation estimate is not a bill.


```bash
# Choose one spawn path; retain the receipt and stop if any command fails.
# inside a mission — your own job
SPAWN_RECEIPT=$(pylot --org <Org> workers spawn --mission "$PYLOT_JOB_ID" repo=<org/repo>) &&
WORKER_ID=$(printf '%s' "$SPAWN_RECEIPT" | jq -er '.worker_id | select(type == "number" and . > 0 and . == floor)') &&
TASK_ARN=$(printf '%s' "$SPAWN_RECEIPT" | jq -er '.task_arn | select(type == "string" and length > 0)')
```

```bash
# from a conversation — name= is the human-readable pretty name (tag pylot:name)
SPAWN_RECEIPT=$(pylot --org <Org> workers spawn --conversation "$CONV_ID" repo=<org/repo> name=<short-purpose>) &&
WORKER_ID=$(printf '%s' "$SPAWN_RECEIPT" | jq -er '.worker_id | select(type == "number" and . > 0 and . == floor)') &&
TASK_ARN=$(printf '%s' "$SPAWN_RECEIPT" | jq -er '.task_arn | select(type == "string" and length > 0)')
```

```bash
# from a local session (a laptop running `pylot auth login`, no mission context):
SPAWN_RECEIPT=$(pylot --org <Org> devboxes spawn <org/repo> --idle-ttl 3600 name=<short-purpose>) &&
WORKER_ID=$(printf '%s' "$SPAWN_RECEIPT" | jq -er '.worker_id | select(type == "number" and . > 0 and . == floor)') &&
TASK_ARN=$(printf '%s' "$SPAWN_RECEIPT" | jq -er '.task_arn | select(type == "string" and length > 0)') &&
pylot --org <Org> devboxes view "$TASK_ARN"   # wait for RUNNING before the first prompt
```

```bash
# persistent-conversation variant — capture only the id so the session credential is never printed
CONV_ID=$(pylot conversations create --org <org> --team <team> --repos <repo-name> --title "<task>" | jq -r .id)
pylot devboxes connect <task-arn>      # → ssh_command; drive by SSH when direct command control beats prompting
```
201 → `{worker_id, task_arn, last_status}`. Boot runs PROVISIONING → RUNNING
(~1–2 min). Prompts are queued server-side and claimed once the in-container
daemon boots, so an early prompt is not lost; if you need RUNNING confirmed,
`pylot workers list --mission "$PYLOT_JOB_ID"` carries live `ecs_status` (the
single-worker `view` does not). `name=` is honoured on the conversation path only.

Retain `WORKER_ID`, `TASK_ARN`, organization and owner scope before driving the
worker. Never prompt with an empty/null id. On a gateway/CLI supporting worker-id
reads, `devboxes view <task-arn>` and `devboxes list` expose `worker_id` while
running, and `spawn --wait` retains it; use normal reads to recover an existing
worker's identity. Do not infer an id from SSH environment or scan id ranges.

For environment variable **names only**, use
`python3 -c 'import os; print(sorted(os.environ))'`. Never use `env | cut`,
`printenv`, or `set`: multiline secret values can expose inner lines as apparent
variable names or entries.

### 3. Drive

```bash
pylot workers prompt <wid> --mission "$PYLOT_JOB_ID" "<text>"     # 202 {turn_seq} | 409 busy|stopped
pylot workers prompt <wid> --mission "$PYLOT_JOB_ID" --wait --timeout 3600 "<text>"
pylot workers view   <wid> --mission "$PYLOT_JOB_ID" --turn <N>  # exact turn receipt
pylot workers output <wid> --mission "$PYLOT_JOB_ID" --turn <N>  # retained output for N
pylot workers wait   <wid> --mission "$PYLOT_JOB_ID" --turn <N> --timeout 900 # observe only
pylot workers logs   <wid> --mission "$PYLOT_JOB_ID"             # CloudWatch tail (--mission required)
```

Verify `pylot --version`, `workers view --help`, `workers output --help` and
`workers wait --help` before relying on `--turn`. The gateway must also support
exact-turn history for the worker's owner scope. For standalone/conversation
workers omit `--mission` and ensure `PYLOT_JOB_ID` does not route the call to an
unrelated mission. Retain the organization, scope, worker id and `turn_seq`
acknowledged by each prompt. `prompt --wait` must observe that acknowledged turn;
use `workers wait --turn N` to reconnect without submitting another prompt.

Completion belongs to that exact worker/turn pair. A later `turn_seq`, current
idle state, or latest output cannot prove turn N's result. Read completed N with
`view/output --turn N` while N+1 is running and after stopping the worker. Keep
the receipt identity with its exit/error evidence and output; a missing or
mismatched receipt is unresolved evidence, not success.

A wait timeout or disconnected observer ends observation, not the provider turn.
Reconnect to the saved turn before deciding what to do next; do not resubmit
because waiting timed out. Inspect that turn's exit/error evidence and any native
continuity failure even if the worker is idle or a command exited 0. A nonzero
provider exit or explicit continuity failure remains a failed phase. Resolve it
before prompting onward or claiming success. `--follow` streams container logs
to stderr and requires `prompt --wait`; logs do not replace exact-turn evidence.

History currently retains an `output_excerpt` capped to a 16KiB tail. Exact-turn
retrieval does not make that excerpt full output, and a client-local log is not
proof of complete server output. Retain full output when available; if only an
excerpt exists, record that limitation and do not claim complete evidence.

Continue the same bounded task on the **same worker id** after its prior turn
completes. Retain scope, worker id, `session_id`, completed `turn_seq`, and output
with its completeness limits. A passing turn proves that turn's result;
application readiness still requires the intended build, tests, running services,
and functional checks. Do not report readiness from an idle worker alone.

#### Safe refresh between rounds

Before any source update, inventory the intended repository and real checkout
path, current branch/HEAD and upstream, and staged, unstaged, untracked and linked
worktree state. For example, from the intended checkout:

```bash
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' # absent upstream needs an explicit target
git status --short --untracked-files=all
git diff --stat
git diff --cached --stat
git worktree list --porcelain
```

Verify the remote's repository identity without exposing credential-bearing URLs.
Inspect relevant diffs privately when needed; do not dump secrets or unrelated
work. Dirty state is work to preserve, not a startup failure. Fetch the verified
remote (`git fetch <remote>`) to inspect incoming commits without changing the
branch, index or worktree. Do not automatically pull, reset, stash, clean, switch
branches or rebase. Continue with the current source when that is the intended
state. Fast-forward only a clean checkout on the intended branch to an explicitly
verified target, after confirming the current HEAD is its ancestor and reviewing
the incoming scope (`git merge --ff-only <verified-target>`). For divergence,
dirty state or a different intended branch, retain the inventory and resolve the
integration plan without moving or discarding someone else's work.

A code-only commit does not itself invalidate a healthy environment. Compare the
changed inputs against the repository's readiness contract: dependency locks,
runtime/image, startup/service configuration, schema/migrations and required
configuration changes can invalidate prior evidence. Run the affected setup or
readiness checks when those inputs change; an unknown fingerprint requires
verification. Never rerun destructive setup or recreate a database merely to
refresh readiness. Before claiming the next round ready, verify required service
health and perform a useful task action (focused check and browser/job flow where
applicable). Reuse caches and unaffected readiness evidence, but retain the full
repository-required service gate and record source and runtime revisions.

Before invoking a remote slash command, send a plain-text discovery prompt to list
the worker's installed commands and skills and the repo's instructions — local
skills are not installed remotely. An `Unknown command` result is a failed turn
even when the harness reports exit code 0.

Two boot failures, both fixable without archaeology:
- Prompt queues forever, `view` shows `queued → idle`, `last_exit_code: -1`,
  `session_id: null`, frozen `heartbeat_at`, and `/ecs/pylot-workers` has no
  `[worker-prompt-daemon]` boot line → the worker image predates the prompt
  daemon. `pylot deploy build-worker <org/repo>` and respawn.
- A turn fails `403 unknown job` / `unknown devbox worker` → proxy-principal
  regression; check the worker row's `job_id` and file it against the gateway.

If the required commands or `--turn` flags are absent, record the unsupported
CLI version and use the authorized supported-version adoption path. Do not
replace exact-turn evidence with a latest-state polling loop.

In a chat/Lambda runtime there is no budget to block on `--wait` — never busy-poll.
Prompt, retain its turn identity, then schedule a wake (see Async Wake Pattern)
and re-check that exact turn next time.

### 4. Stop (destructive) and resume

```bash
pylot workers stop   <wid> --mission "$PYLOT_JOB_ID" --force
pylot workers resume <wid> --mission "$PYLOT_JOB_ID" --wait --timeout 900
# Observe the acknowledged attempt without initiating another restore.
pylot workers restore-status <wid> --attempt <restore-attempt-uuid> --wait --timeout 900
```

`--force` is mandatory — the CLI refuses the stop without it. Ask a human before
stopping a box someone is working in. Stop is idempotent; always stop a mission
worker when the skill finishes (harvest-on-complete is the backstop, not the plan).
Conversation-owned devboxes snapshot on stop; mission-worker snapshots are
opt-in and OFF by default (cost control), so treat a mission worker's stop as
final unless you know the flag is on. Retain the completed turn's exact identity
and output (including completeness limits) **before** stopping. Retrieve the same
turn afterward with `view/output --turn N`; stop can replace latest `last_output`
with a truncated snapshot transcript, which is not that turn's result.
`stopped: true` does not mean recovery is available — require
`snapshot_status: verified` before relying on `resume`. Retain the stop receipt
and snapshot status/reason; failed or missing snapshots need an explicit recovery
decision, not an optimistic resume claim.

**Durable restore requires CLI 0.9.14 or newer and a gateway with asynchronous
restore support.** Check `pylot workers resume --help` for `--wait` and
`pylot workers restore-status --help` before starting; an older CLI or worker
image is not proof these semantics are available.

Resume initiates one durable attempt. HTTP `202` with `restore_status: pending`
is acknowledgment, not restore success, even if the CLI exits 0. Immediately
retain `worker_id`, `restore_attempt_id`, snapshot id, destination `task_arn`
when available, and the original scope in the task checkpoint. `--wait` observes
that attempt with short status reads. A timeout or disconnected observer does
not cancel the restore: reconnect with `restore-status` and the saved worker
and attempt ids. Do not repeat the resume POST because waiting timed out. If an
acknowledgment was lost, inspect `restore-status <wid>` and worker state to
recover the attempt identity before deciding whether another initiation is safe.
The runtime restore deadline and cleanup lifecycle are independent of the CLI
observer timeout. Status observation can reconcile/finalize the attempt and
drive cleanup, including stopping a failed or expired destination; it does not
initiate a new restore. Retain `cleanup_pending` reasons and verify terminal
cleanup rather than treating an observer timeout or StopTask acceptance as
confirmed shutdown.

Accept completion only when the status still names the saved worker and attempt,
`restore_status` is `succeeded`, the restore receipt matches that attempt and
snapshot, and the destination task is `RUNNING`. Retain the new task ARN; never
continue against the stopped source ARN. A `failed` status or identity mismatch
requires inspecting the recorded reason and resolving recovery before another
prompt or retry. Gateway restore success proves the restore, while workspace,
native context, and application readiness still need the checks below.

For a standalone devbox, use:

```bash
pylot devboxes resume <stopped-task-arn> --wait --timeout 900
# Use the destination task_arn from the completed attempt for subsequent calls.
pylot devboxes view <destination-task-arn>
pylot devboxes connect <destination-task-arn>
```

`devboxes resume --wait` follows the completed attempt's destination ARN, then
waits for it to be `RUNNING` and reachable. If its observer times out, recover
with the saved `worker_id` and `restore_attempt_id` through `workers restore-status`
as above, then check and connect to that destination. A reachable daemon alone
does not prove the application's services are ready.

**Native context continuity is provider-specific.** The gateway `session_id`
identifies the drive loop; it is not proof of a Codex native thread. A worker
image with native Codex continuity must persist the mapping from that gateway
session to the `thread.started` identity under `~/.codex`, then resume that exact
native thread. Never substitute `--last`, infer an id from another session, or
silently start fresh when its rollout is missing. The source-supported binding is
`$HOME/.codex/pylot-worker-sessions/<sha256-of-gateway-session-id>.json`:
inspect only its gateway id, `thread_id`, and `identity` fields to compare the
saved provider/credential route and paths; never dump raw rollout history or
credential values. Verify the same execution
identity (provider, provider type, credential reference, real working directory,
and native home) before continuing. Model changes within the same provider and
credential route are supported; record the model used for each turn rather than
treating a model change alone as incompatible.
Claude uses its own session/history and `--resume` semantics; do not apply a
Codex identity rule to Claude or assume either provider can resume the other's
history.

1. Before stop, retain the worker and gateway session ids, provider/native
   identity evidence, completed turn sequence, full result, and any unfinished
   work checkpoint. Record paths and identifiers without dumping credentials,
   environment variables, or raw native history.
2. After a verified snapshot, resume the **same worker id** with the same scope.
   Observe the same restore attempt to verified success as above; a new task
   ARN is expected. Check restored workspace and native session
   evidence before the next prompt; unchanged `session_id` alone is insufficient.
3. Send the next bounded prompt to that worker. Verify the sequence advanced and
   the provider resumed the saved native history (for example, it recalls a
   prior turn's unique task fact without being supplied it again). Capture the
   result and finish the application's functional checks before claiming readiness.

Source support does not prove the published worker image contains it. Verify the
image/version and observed resume behavior before claiming native continuity.
For older Codex workers that never saved a native mapping or rollout, lost
history cannot be inferred from the gateway session id. Preserve filesystem and
output evidence, report the missing history, and resolve an explicit fresh-session
migration or recovery decision. Do not label that migration a native resume.
Deleting a conversation is destructive; never do it without an explicit ask.

### 5. Multi-box work — you are the message bus

Boxes never talk to each other. Preflight and spawn one per repo with distinct
purpose names, then relay by hand: `workers view` A → extract the load-bearing
evidence (request id, stack trace, payload shape) → `workers prompt` B with it.
Keep relayed context small and factual; never pass secrets between boxes — each
box already carries its own bundle as env. Two boxes burn budget twice as fast,
so only spawn a second when both repos genuinely need code or log access.

### 6. What your credential can call

The capability gate fires **only** on the operator JWT a mission container runs on
(`PYLOT_OPERATOR_TOKEN`, aliased to `PYLOT_DISPATCH_TOKEN`). Operators hold every
operator capability, so the gate reduces to one question: is the route mapped at
all? Mission-scoped worker routes are; unscoped ones are not.

**Exception — session JWT (`$PYLOT_API_TOKEN`)**: the following conversation-scoped routes
ARE mapped at `org:member` tier (`route-capability.mts:224-229`) and ARE reachable
with a session JWT — the capability gate passes them through, and each handler enforces
its own authorization server-side:

| Route | Since | Auth boundary |
|---|---|---|
| `POST /conversations/:id/slack-post` | #2622 | handler: org member |
| `POST /conversations/:id/slack-pickup` | #2622 | handler: org member |
| `POST /conversations/:id/admin-action` | #2891 | handler: org-admin check via turn-trigger |
| `POST /conversations/:id/admin-action/confirm` | #2891 | handler: org-admin check via turn-trigger |

These are the only conversation-scoped routes that accept a session JWT. All other
conversation-scoped routes and all `/admin/*` routes remain 403 for session JWTs — by design.

| Call | Mission operator | Devbox worker · local `pylot auth login` |
|---|---|---|
| `workers spawn`/`list`/`view`/`prompt`/`output`/`stop`/`resume`/`logs` **with `--mission`** | yes | yes |
| the same verbs **without** `--mission` (unscoped `/workers/:wid`) | **403** | yes |
| `workers restore-status` (GET observation, no `--mission` flag) | yes, own worker | yes |
| `workers spawn`/`list --conversation` | **403** | yes |
| `devboxes projects`, `devboxes project <org/repo>` | yes | yes |
| `devboxes spawn`/`view`/`connect`/`delete`/`list` | **403** | yes |
| `deploy build-worker`, `deploy promote` | **403** | yes |
| `deploy status <build_id>` | yes | yes |

A gate 403 reads `{"error":"forbidden","reason":"capability_required","capability":"unknown"}`.
Nothing outside the operator JWT is capability-gated, but handler-level org fences
still apply to org-scoped tokens. **Inside a mission, always pass
`--mission "$PYLOT_JOB_ID"`** on verbs that accept it. `restore-status` instead
uses the saved worker/attempt ids on its authorized GET observation route; it
can reconcile the existing attempt and drive cleanup as described above.

### 7. Fallback when there is no usable CLI

Only for containers whose image carries no `pylot` or one too old for the verb you
need. `PYLOT_JOB_ID`, `PYLOT_API`/`PYLOT_GATEWAY_URL` and `PYLOT_DISPATCH_TOKEN` are
set in both operator and mission-worker containers.

```bash
AUTH=(-H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" -H "Content-Type: application/json")
BASE="${PYLOT_API:-$PYLOT_GATEWAY_URL}/missions/${PYLOT_JOB_ID}/workers"

WID=$(curl -s --max-time 90 -X POST "${AUTH[@]}" -d "{\"repo\":\"$REPO\"}" "$BASE" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("worker_id",""))')
SEQ=$(curl -s --max-time 30 -X POST "${AUTH[@]}" -d "{\"prompt\":\"$PROMPT\"}" "$BASE/$WID/prompt" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("turn_seq",""))')
# poll GET "$BASE/$WID" until turn_state=idle AND turn_seq=$SEQ, then read last_output
curl -s --max-time 30 -X POST "${AUTH[@]}" "$BASE/$WID/stop" >/dev/null 2>&1 || true
```

Same routes, same semantics as §2–4. Prefer the CLI wherever it exists — one
transport, one source of truth.

## Supervise a run

After starting a worker or prompt, make one immediate compact status check to
confirm it was accepted and is starting; queued/provisioning is not yet running.
Prefer a completion event or a detached status monitor that wakes the session
only on a terminal state. When scheduled checks are necessary, use adaptive
**10–30 minute intervals**: about 10 minutes near an expected result or a known
failure, 20–30 minutes for healthy hour-long implementation or test work. An
unchanged healthy check should lengthen the next wait, not trigger another
prompt. Use shorter checks only for a concrete startup or failure diagnosis.
Keep at most one follow-up owner per task; pause the old follow-up when another
session takes over, and pause on completion or a decision that blocks safe work.
An automation error or safety rejection is a reason to inspect and stop repeated
retries, not to keep waking the same blocked action or change routes to evade it.

Intervene only when evidence shows the factory cannot continue safely: a
materially ambiguous task contract, an unrecoverable execution condition, or a
result that would violate scope or safety. Prefer resuming from durable remote
state. Do not coach routine implementation, rewrite merely imperfect work, or
build session-local workarounds for a recurring factory defect.

## Verify the terminal result

A successful process exit is not the deliverable. Independently verify the
requested outcome against the task scope:

- terminal mission state, report, and cost are coherent;
- the expected branch or PR exists with the correct target and scope;
- PR claims match the actual diff and recorded checks;
- review suggestions and any remaining risks are visible;
- for delivery tasks, review findings are resolved and authorized release work
  proceeds through target-environment workflow acceptance, with deployed revision
  and runtime evidence; a PR or worker completion is an intermediate result;
- attached evidence is accessible through the intended Pylot asset flow;
- the execution resource is stopped or otherwise left in its intended terminal
  state.

The coordinator owns the remaining delivery tail after worker completion.
Explicit PR-only tasks can finish at a verified PR. When verification exposes a
reusable defect, correct the owning skill rather than working around it here.

## Filing findings — never a raw `gh issue create`

Every automated finding (a bug, gap or follow-up noticed during any mission,
stage or review) goes through this helper, which ships with this skill on
every operator:

```bash
FF="${PYLOT_WORKSPACE:-$HOME/.claude}/skills/pylot-cli/scripts/file-finding.sh"
bash "$FF" --repo <org/repo> --title "<title>" --search "<root-cause terms>" \
  --body-file <evidence.md> [--severity P0|P1|P2|P3] [--incident] [--blocking] [--label <l>]...
```

It enforces the owner rule (2026-10-06, cut issue inflow):

1. An open issue matching `--search` (the root cause: symbol, file, error
   text or fingerprint) gets a comment instead of a new issue.
2. A finding that is not P0/P1, not an incident and not blocking a PR or
   release goes to the repo's one rolling `Weekly findings digest — YYYY-Www`
   issue (label `digest`) as a comment, once per title. A new week's digest
   closes the previous one.
3. At most 3 new issues per filer run across all repos (`FINDING_CYCLE`,
   default the mission id). P0 and `--incident` are exempt; over-cap findings
   go to the digest.

It prints `commented N`, `digest N <reason>` or `created N`; cite that number.
`--dry-run` writes nothing. Without the helper, follow the same three rules by
hand. Exempt: tracking issues a stage maintains by a fixed label (one per
label), and closed-issue reopens.

## GitHub Auth Through the CLI

`pylot auth login` stores per-org credentials in `~/.pylot/credentials`;
`pylot auth git-token --repo <org>/<repo>` mints a one-off short-lived App
installation token. The App has org-wide access, but each minted token is scoped
to the single repo you asked for — a narrow `gh repo list` under that token is
not an App limit; mint another token for another repo. A repo "lacking pylot
support" means its devbox config is missing (not in a team, no worker image),
never that the App cannot reach it. **Never export a session-wide `GH_TOKEN`.**
App tokens cannot read user-specific surfaces (GitHub notifications); those need
a logged-in `gh` identity or event-ledger routing. Secrets: never in prompts or
payloads — `pylot secrets`, then reference env var names.

Git needs a credential helper; `gh` needs its own per-invocation token shim.
Verify both with repository-targeted commands. In managed cloud environments,
check whether the outbound proxy replaces caller-supplied GitHub authentication.
A private repository read that also succeeds with an intentionally invalid token
does not prove Pylot-token access. Resolve credential routing through the
supported environment configuration, preserve proxy and TLS settings, and repeat
the real repository read and push before accepting authentication. Installation
or token minting alone is insufficient evidence.

## Org Setup From a Conversation (admin-action)

> **Requires [pylot#2978](https://github.com/fellowship-dev/pylot/issues/2978)** —
> `pylot convo admin-action` must be present in the worker image before workers are
> directed here. Verify: `pylot convo admin-action --help` must succeed in the container.

Session JWTs carry scopes `[dispatch, missions:read, heartbeat]` — `/admin/*` routes
always 403 by design. `/conversations/:id/admin-action` is a separate authorization
boundary (see §6 exception table) that accepts session JWTs; the endpoint enforces
org-admin authorization server-side via the turn's triggering message sender.

### Primary path

```bash
# auto-detects $CONVERSATION_ID from environment
pylot convo admin-action <op> [key=value ...]

# explicit conversation id override
pylot convo admin-action <op> --conversation <id> [key=value ...]

# confirm a staged (confirm-tier) operation after org admin replies
pylot convo admin-confirm <code>

# reject a pending confirm-tier operation
pylot convo admin-confirm <code> --reject
```

### Operations

Op list is **closed** — any value not in this table returns 400.
**Never pass credentials or API keys in op args** — the gateway returns 400 and
nothing is stored (hard boundary: credential-looking args are explicitly rejected).

| op | tier | effect |
|---|---|---|
| `setup-status` | read (any conversation member) | onboarding state: App install, teams, repo bindings + worker-image presence, goals, operators/skills, provider chain, budget |
| `team-create` | immediate (org admin requester) | create a team in this org |
| `team-rename` | immediate (org admin requester) | rename a team |
| `repos-add` | immediate (org admin requester) | bind a repo to a team; response includes worker-image presence |
| `goals-set` | immediate (org admin requester) | set team goals (the store auto-pylot stage 00 reads) |
| `operator-add` | immediate (org admin requester) | create an operator on a team |
| `skill-assign` | immediate (org admin requester) | assign a skill to an operator |
| `instructions-set` | immediate (org admin requester) | set operator instructions |
| `org-update` | **confirm** | org settings (Slack default team, max_concurrent, …) |
| `budget-set` | **confirm** (spend) | team daily budget cap |
| `provider-assign` | **confirm** (model/spend routing) | attach an existing platform provider chain to org/team |

### Confirm-tier flow

Confirm-tier ops (`org-update`, `budget-set`, `provider-assign`) are staged first,
then approved by an org admin's reply — the approver's identity is proven by their
own conversation turn, not supplied by the worker.

1. `pylot convo admin-action <confirm-op> [args]` → gateway returns `202 {code, summary}`
2. Worker relays to the user: *"An org admin must reply `confirm <CODE>` within 10 minutes."*
   (`summary` describes exactly what will change — relay it verbatim.)
3. The org admin sends a reply; the approval turn's own message sender proves their identity.
4. `pylot convo admin-confirm <CODE>` (called in the approval turn) → `200`, executed.
5. Rejected or expired: `pylot convo admin-confirm <CODE> --reject` kills the pending action;
   an expired code (>10 min) returns `410` and never executes.

### Errors

| error | meaning | user-facing guidance |
|---|---|---|
| `no_human_trigger` | Turn has no human sender (scheduled wake-up, automation) | Retry from a conversation turn triggered by a human message |
| `unlinked_slack` | Sender's Slack account is not linked to a GitHub account | Ask the user to link their GitHub account in the Slack app settings |
| `not_org_admin` | Linked GitHub account is not an admin of this org | Immediate ops need an org admin in the thread; confirm-tier: anyone can stage, an org admin must confirm |
| `terminal_only` | Op would require a credential or secret value | Use the terminal CLI — credentials cannot transit the conversation |
| `code_expired` | Confirm code is older than 10 minutes | Re-run the original op to get a fresh code |

### Transition-window curl fallback (pre-#2978 images only)

Use this only if the container image predates `pylot convo admin-action`.
`$CONVERSATION_ID` is set in chat-worker containers. **Use `$PYLOT_API_TOKEN`
(session JWT) — NOT `$PYLOT_DISPATCH_TOKEN`** (operator token 403s this endpoint
by design; using it here is the exact mis-behavior pylot#2979 corrects).

```bash
# immediate op
curl -s -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"op\":\"$OP\"}" \
  "${PYLOT_API:-$PYLOT_GATEWAY_URL}/conversations/$CONVERSATION_ID/admin-action"

# confirm a staged op (after org admin replies with the code)
curl -s -X POST \
  -H "Authorization: Bearer $PYLOT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"code\":\"$CODE\"}" \
  "${PYLOT_API:-$PYLOT_GATEWAY_URL}/conversations/$CONVERSATION_ID/admin-action/confirm"
```

## Automations

```bash
pylot automations list           # inventory with run stats
pylot automations get <name>     # single rule detail
```

Per-repo coverage: filter `only_repos`/`skip_repos` from list output.

Org-specific admin runbooks that automations dispatch live in that org's repo
docs and team playbook (`pylot context <org/repo>`), not in this skill.

## Measures and annotations

Requires CLI 0.9.12 or newer.

```bash
pylot measures list                                  # stored measures with latest version and grains
pylot measures points <measure> --grain day|week|month [--since] [--until] [--measure-version] [--scope <scope_ref>]
                                                     # read one measure series
pylot measures put --file points.json                # upsert a batch of points ({"points": [...]})
pylot annotations add --kind deploy|pause|incident|change|skill_update --start <iso> [--end <iso>] --label <text> \
  [--affects a,b] [--scope <scope_ref>] [--detail <text>] [--source-ref <ref>]
                                                     # record a dated event; no --end = an instant, --end = a period
pylot annotations list [--since] [--until] [--affects <measure>] [--include-superseded]
                                                     # annotations overlapping a range
pylot annotations supersede <id> --by <id>           # replace a wrong annotation (the log is append-only)
```

For how to define measures, annotate, chart and evaluate Objectives, use the `pylot-objectives` skill.

## Slack Channel Routing

Bind Slack channels to teams for message routing. Many channels can bind to the same team (many-to-one). CLI is the primary interface — no UI equivalent.

```bash
# Bind a channel to a team (additive; channel must already be known to the bot)
pylot teams channels bind <channel-id> --team <team> [--org <org>]

# List all Slack channels with their bound team (null = unbound)
pylot teams channels list [--org <org>]

# Set the org-level fallback team for unbound channels
pylot orgs set-slack-default <team> --org <org>

# Clear the org-level fallback team
pylot orgs clear-slack-default --org <org>
```

Default-team fallback: when a Slack message arrives on a channel with no explicit binding, it is routed to the org-level default team (if set). Unbound channels with no org default are dropped.

## Async Wake Pattern

Dispatch with `--context conversation_id=…` → auto-wake on mission terminal + PR lifecycle.
Self-wake fallback: `pylot conversations wakes-add <conv-id> in_seconds=300 content="check X"`
One wake at a time; re-schedule rather than stack.
