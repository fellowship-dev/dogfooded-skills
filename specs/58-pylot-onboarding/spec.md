# Spec: pylot-onboarding Skill

**Issue:** fellowship-dev/dogfooded-skills#58
**Title:** feat(skills): pylot-onboarding skill — checklist-driven worker setup for new repos
**Date:** 2026-05-22

---

## Problem

Onboarding a new repo to a Pylot team (e.g. booster-pack) requires 5+ manual steps with
several non-obvious failure modes. In the `Lexgo-cl/lexgo-website` onboarding session, the
worker image setup alone burned ~4 hours across 5 failed fix attempts because:

1. `infra.ops` built the repo's app Dockerfile instead of the Pylot worker base image
2. Each operator (`cto`/`dev`/`qa`) has a **separate** ECS task definition — fixing one does not
   propagate to others
3. `null input_tokens` + 60–120 s runtime is the only signal that a worker is broken — no early
   diagnostic gate exists
4. No standard procedure verifies all operators before dispatching real work
5. New keychain entries may ship with placeholder values (e.g. `STRAPI_TOKEN: secret-v1`) that
   silently break downstream missions

With 10+ repos queued for onboarding, this procedure must be encapsulated as a reusable,
idempotent skill.

---

## Scope

Create a new skill at `skills/pylot-onboarding/` (sibling of `skills/pylot-api/` in the Lambda
workspace) with three files:

```
skills/pylot-onboarding/
├── SKILL.md          # operator-facing procedural instructions (5 steps)
└── docs/
    ├── checklist.md  # human-readable step-by-step checklist
    └── canary.md     # canary dispatch payload, wait logic, and pass/fail interpretation
```

### Out of scope

- Setting actual secret values (requires human input)
- Smoke-testing production (that is `<team>.qa`'s responsibility post-onboarding)

---

## Invocation

```
/pylot-onboarding <team> <org/repo> [operators: cto dev qa]
```

**Example:**
```
/pylot-onboarding booster-pack SomeOrg/new-site cto dev qa
```

Arguments:
- `team` — Pylot team identifier (e.g. `booster-pack`)
- `org/repo` — GitHub org and repo slug (e.g. `Lexgo-cl/lexgo-website`)
- `operators` — optional space-separated list; defaults to `cto dev qa`

---

## Five-Step Procedure

### Step 0 — Pre-flight

**Goal:** Confirm team + repo are known to Pylot, get the keychain path.

API calls:
```
GET /crew                  → assert team present, enabled: true, fargate: true
GET /fleet/projects        → check if repo already has task_def_family entry (idempotency)
GET /admin/secrets         → locate keychain path: <team>/<Org/repo>
```

Decision tree:
- If `GET /crew` shows `enabled: false` → block, instruct operator to enable team first
- If `GET /fleet/projects` already has a `task_def_family` entry → skip Step 1 (image already exists); continue from Step 2
- If `GET /admin/secrets` finds no keychain → flag as "missing secrets keychain"; continue (secrets loaded later)

### Step 1 — Crew config + worker image

**Goal:** Ensure the ECS task definitions exist for all requested operators.

Check `worker_images` in the crew config for the target team:

- **Entry present** → skip dispatch; log ✅
- **Entry missing** → dispatch `infra.ops`:

  > "Add `Org/repo` to `<team>` worker_images in crew config with the correct secrets_arn.
  > Then run `ensure-worker.sh` in the pylot repo for team `<team>`, repo `Org/repo`, to create
  > the ECR image and ECS task defs for all requested operators."

**Critical constraint:** the task is `ensure-worker.sh`, **NOT** "find and build the Dockerfile".
The app Dockerfile builds the application; the Pylot worker base image is built by
`scripts/ensure-worker.sh` in the pylot repo. Confusing these is the #1 failure mode.

Wait for infra.ops to complete before proceeding.

### Step 2 — Canary each operator

**Goal:** Confirm every requested operator's ECS task definition is healthy before dispatching
real work.

For each operator in `[cto, dev, qa]` (or the provided subset):

1. Dispatch canary task:
   ```json
   {
     "agent": "<team>.<op>",
     "task": "Canary: echo <OP>_OK",
     "repo": "Org/repo",
     "context": { "conversation_id": "<current_conv_id>" }
   }
   ```

2. Wait 150 seconds.

3. Interpret result:

   | Condition | Interpretation |
   |-----------|----------------|
   | `exit_code: 0` AND `input_tokens > 0` | ✅ healthy |
   | `exit_code: 1` AND `input_tokens: null` AND `duration_s` 60–120 | ❌ task def broken |
   | `exit_code: 0` AND `input_tokens: null` | ⚠️ suspect — treat as broken |

4. For each broken operator: dispatch `infra.ops`:

   > "Run `ensure-operator-taskdef.sh` for team `<team>`, operator `<op>`, repo `Org/repo`.
   > Do NOT rebuild the app Dockerfile."

5. Re-canary the repaired operator. If it fails again → block and report; do not proceed.

See `docs/canary.md` for the full canary dispatch payload and validation pattern.

### Step 3 — Load and validate secrets

**Goal:** Load the repo keychain into the conversation and catch placeholder values before
they cause silent mission failures.

```bash
POST /conversations/$CONV_ID/resources  {"type":"secret","ref":"<team>"}
POST /conversations/$CONV_ID/resources  {"type":"secret","ref":"<team>/Org/repo"}
```

After loading, inspect each key:

- Flag any value matching `^secret-v\d+$` or any other recognisable placeholder pattern
- Print a remediation table:

  | Key | Status | Action required |
  |-----|--------|-----------------|
  | `STRAPI_TOKEN` | ⚠️ placeholder (`secret-v1`) | Replace in AWS Secrets Manager at `<arn>` |
  | `DATABASE_URL` | ✅ real value | — |

**Gotcha:** `POST /admin/secrets/:project` takes `org%2Frepo` (URL-encoded slash), not the raw
`org/repo` string and not the full ASM path.

### Step 4 — Seed CLAUDE.md

**Goal:** Leave a Pylot Ops section in the repo's CLAUDE.md so future operators have immediate
context.

Dispatch `<team>.cto` to commit a **Pylot Ops** section to the repo's `CLAUDE.md` containing:

- Which keychain to load and what keys it provides
- Which operator to use for each task type (deploy / code / test)
- Any secrets still holding placeholder values (link to Step 3 report)
- Known gotchas for this repo's stack (from Step 0 preflight data)

### Step 5 — Report

Print a summary table before exiting:

| Check | Result |
|-------|--------|
| Crew config (`worker_images` entry) | ✅ present / ❌ missing |
| Task defs | ✅ cto / ✅ dev / ✅ qa (or per-operator status) |
| Canary validation | ✅ all passed / ❌ `<op>` failed |
| Secrets loaded | ✅ loaded / ❌ keychain not found |
| Placeholder secrets | ✅ none / ⚠️ `KEY_NAME` needs real value |
| CLAUDE.md Pylot Ops | ✅ committed / ⏭️ skipped |
| Ready to dispatch | ✅ Yes / ❌ Blocked on: `<reason>` |

Exit `0` if all checks passed or only placeholder-secret warnings remain (human action required).
Exit `1` if canary repair failed or task defs could not be verified.

---

## Idempotency Requirements

The skill must be safe to re-run on a partially-set-up repo:

- `GET /fleet/projects` check before any ECS work → skip if already present
- Label/canary steps are stateless → always re-run (fast)
- `POST /conversations/:id/resources` with same ref → idempotent (Pylot deduplicates)
- CLAUDE.md write → merge/update, never overwrite if Pylot Ops section already present

---

## Failure Modes Prevented

Derived from `Lexgo-cl/lexgo-website` onboarding incident (2026-05-22):

| Failure mode | Prevention |
|---|---|
| `infra.ops` builds app Dockerfile | Step 1 prompt names `ensure-worker.sh` explicitly; prohibits Dockerfile |
| Fix to `cto` task def does not fix `dev`/`qa` | Step 2 canaries **every** requested operator independently |
| No early signal for broken worker | 150s canary gate in Step 2 catches null `input_tokens` before real missions |
| URL-encoding error in secrets API | Step 3 documents `org%2Frepo` encoding explicitly |
| Placeholder secrets cause silent failures | Step 3 inspects and flags all placeholder values before exit |

---

## Acceptance Criteria

- [ ] `/pylot-onboarding booster-pack SomeOrg/new-site cto dev qa` completes on a brand-new
      repo without manual intervention
- [ ] Canary failures are caught and fixed before the skill exits
- [ ] Placeholder secret values are flagged with clear remediation instructions
- [ ] A CLAUDE.md Pylot Ops section is committed to the repo
- [ ] The skill is idempotent — safe to re-run on a partially-set-up repo

---

## File Contracts

### `SKILL.md`

- YAML frontmatter: `name`, `description`, `argument-hint`, `user-invocable: true`,
  `allowed-tools: Bash, Read, Write`
- Full 5-step procedure as operator instructions
- Named constants for canary wait time (150s), placeholder pattern regex, API paths

### `docs/checklist.md`

- Human-readable, sequential checklist (checkboxes)
- Maps 1:1 to SKILL.md steps — humans can follow without reading SKILL.md
- Includes "what to look for" notes for each API call result

### `docs/canary.md`

- Exact JSON dispatch payload (copy-paste ready)
- Pass/fail interpretation table (reproduced from Step 2 above)
- Fix dispatch prompt for `infra.ops` (exact wording)
- Notes on per-operator task def family naming convention

---

## Open Questions

None — all failure modes and API contracts are documented in the issue with confirmed
real-world data from the Lexgo incident.
