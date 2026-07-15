---
name: vercel-ops
description: Safe Vercel env var, domain, and deployment verification operations — use when reading, writing, or auditing Vercel environment variables, attaching/verifying custom domains, or confirming NEXT_PUBLIC_* variables are compiled into deployments.
allowed-tools: Read, Bash
---

# vercel-ops

Safe patterns for Vercel environment variable writes, domain operations, and deployment verification. Designed to prevent the class of mistakes that cause production incidents: trailing-newline corruption, wrong-project mutations, and missing redeploys.

> **The most dangerous mistake**: using `echo` to write env var values. `echo "$VAL"` appends a trailing newline — it will silently corrupt the value in Vercel. Always use `printf '%s'`.

## When to Use

- Reading, writing, or auditing Vercel env vars on any fellowship-dev project
- Verifying a `NEXT_PUBLIC_*` variable is compiled into a deployment
- Attaching or inspecting custom domains
- Checking that a redeploy is needed after env changes
- Running the regression checklist before sign-off

## When NOT to Use

- **Deploying to production** — use `vercel-deploy` skill for the full deploy pipeline
- **Creating new Vercel projects** — separate procedure, not covered here
- **Connecting git repos to Vercel** — all deploys are CLI pushes, not git-triggered

## Required Secrets

- `VERCEL_TOKEN` — from worker secret store

## Required Inputs (from repo playbook)

- `VERCEL_PROJECT_ID` — project ID (starts with `prj_`)
- `VERCEL_ORG_ID` — team ID (starts with `team_`)

> **Never hardcode** project IDs, org IDs, or domain values in this skill. Pass them from the repo playbook at invocation.

## Forbidden Actions

1. **NEVER use `echo` to write env var values** — it appends a trailing newline that corrupts the value
2. **NEVER print secret values to stdout/stderr** — use length/checksum comparison only
3. **NEVER use `vercel env pull`** for reading sensitive values — it writes plaintext to disk
4. **NEVER use `vercel link`** — it prompts interactively; write `.vercel/project.json` directly
5. **NEVER mutate any Vercel resource before verifying project ID/name match**
6. **NEVER globally enable automatic preview deployments** — use explicit `vercel deploy` calls
7. **NEVER use `wc -c <<< "$VAL"`** — bash heredoc adds a newline

---

## Operation 1: Project Verification (Run Before ANY Mutation)

Verify that `VERCEL_PROJECT_ID` resolves to the expected project name. **Always run this before any write operation.**

```bash
[ -z "$VERCEL_TOKEN" ]      && { echo "[vercel-ops] MISSING: VERCEL_TOKEN"; exit 1; }
[ -z "$VERCEL_PROJECT_ID" ] && { echo "[vercel-ops] MISSING: VERCEL_PROJECT_ID"; exit 1; }
[ -z "$VERCEL_ORG_ID" ]     && { echo "[vercel-ops] MISSING: VERCEL_ORG_ID"; exit 1; }

PROJECT_JSON=$(curl -sf \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$VERCEL_PROJECT_ID?teamId=$VERCEL_ORG_ID")

[ -z "$PROJECT_JSON" ] && {
  echo "[vercel-ops] ERROR: project $VERCEL_PROJECT_ID not found or token lacks access — STOP"
  exit 1
}

ACTUAL_NAME=$(printf '%s' "$PROJECT_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)

echo "[vercel-ops] Project verified: $ACTUAL_NAME ($VERCEL_PROJECT_ID)"

# If you have an expected name, assert it:
# EXPECTED_NAME="quantic-v2"
# [ "$ACTUAL_NAME" != "$EXPECTED_NAME" ] && {
#   echo "[vercel-ops] ERROR: expected project '$EXPECTED_NAME', got '$ACTUAL_NAME' — STOP"
#   exit 1
# }
```

---

## Operation 2: Write an Environment Variable (Safe Pattern)

> **Critical**: `printf '%s'` only. Never `echo`, never here-string (`<<<`).

```bash
# Inputs required: VERCEL_TOKEN, VERCEL_PROJECT_ID, VERCEL_ORG_ID
# VAR_NAME    — e.g. NEXT_PUBLIC_TURNSTILE_SITE_KEY
# VAR_VALUE   — the value (from secret store or passed securely)
# VAR_TARGET  — "production", "preview", "development", or "production,preview,development"
# VAR_TYPE    — "plain" (default) or "secret"

# Step 1: verify project before mutation (see Operation 1)

# Step 2: write the value via API using printf to avoid trailing newlines
printf '%s' "$VAR_VALUE" | vercel env add "$VAR_NAME" "$VAR_TARGET" \
  --token="$VERCEL_TOKEN" \
  --yes

# Step 3: fingerprint immediately after write to confirm no trailing newline
WRITTEN_LEN=$(printf '%s' "$VAR_VALUE" | wc -c)
echo "[vercel-ops] Wrote $VAR_NAME to $VAR_TARGET — expected length: $WRITTEN_LEN bytes"

# Step 4: record in playbook (never in this skill)
# playbook entry: VAR_NAME, VAR_TARGET, length, sha256, last-set date
```

**If using the Vercel REST API directly** (preferred for programmatic writes):

```bash
curl -sf -X POST \
  "https://api.vercel.com/v10/projects/$VERCEL_PROJECT_ID/env?teamId=$VERCEL_ORG_ID" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, sys
payload = {
  'key': '$VAR_NAME',
  'value': '$VAR_VALUE',
  'target': $(python3 -c "import json; print(json.dumps('$VAR_TARGET'.split(',')))"),
  'type': 'plain'
}
print(json.dumps(payload))
")" | python3 -c "import sys,json; d=json.load(sys.stdin); print('Created env var id:', d.get('id',''))"
```

---

## Operation 3: Trailing-Newline Detection (No Secret Exposure)

Check the **length** and **checksum** of an env var value without printing it.

```bash
# VAL — the value retrieved securely (e.g. from vercel env pull into a tmpfile, then read)
# EXPECTED_LEN — known good byte count (e.g. 25 for Turnstile site key)

ACTUAL_LEN=$(printf '%s' "$VAL" | wc -c)
ACTUAL_SUM=$(printf '%s' "$VAL" | sha256sum | awk '{print $1}')

echo "[vercel-ops] Byte length: $ACTUAL_LEN  (expected: $EXPECTED_LEN)"
echo "[vercel-ops] SHA256:      $ACTUAL_SUM"

if [ "$ACTUAL_LEN" -ne "$EXPECTED_LEN" ]; then
  echo "[vercel-ops] WARNING: length mismatch — possible trailing newline or truncation"
  echo "[vercel-ops] Difference: $((ACTUAL_LEN - EXPECTED_LEN)) bytes"
else
  echo "[vercel-ops] Length OK — no trailing newline detected"
fi
```

> **quantic-v2 Turnstile key reference**: the correct value is 25 bytes. If `wc -c` returns 26, a trailing newline was introduced (most likely by `echo`).

---

## Operation 4: Environment Variable Audit (List + Fingerprint, No Values)

List env vars and emit length/checksum for each — never the value itself.

```bash
# Fetch all env vars for the project
ENV_JSON=$(curl -sf \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v10/projects/$VERCEL_PROJECT_ID/env?teamId=$VERCEL_ORG_ID&decrypt=false")

# List var names and targets only (values are encrypted at this endpoint)
printf '%s' "$ENV_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
envs = data.get('envs', [])
for e in envs:
    print(f\"{e['key']} [{','.join(e.get('target', []))}] type={e.get('type','plain')} id={e.get('id','')}\")
"
```

> **Note**: `decrypt=false` (the default) returns encrypted values — safe to log. If you need the plaintext value to fingerprint it, use `vercel env pull` into a temp file and delete it immediately after.

---

## Operation 5: NEXT_PUBLIC_* Compile Verification

`NEXT_PUBLIC_*` variables are baked into the JavaScript bundle at build time. A new value only takes effect after a redeploy. Verify it is present in the bundle:

```bash
# DEPLOY_URL — the deployment URL (e.g. https://quantic-v2.vercel.app)
# VAR_NAME   — e.g. NEXT_PUBLIC_TURNSTILE_SITE_KEY
# EXPECTED_PREFIX — first N chars of the expected value (non-secret prefix only)

# Fetch the main bundle index
BUNDLE_URL=$(curl -sf "$DEPLOY_URL" \
  | grep -oE 'src="/_next/static/chunks/[^"]+\.js"' \
  | head -1 \
  | grep -oE '/_next/static/chunks/[^"]+')

[ -z "$BUNDLE_URL" ] && {
  echo "[vercel-ops] Could not find JS bundle URL in HTML — check DEPLOY_URL"
  exit 1
}

# Search bundle for variable prefix (never print secret value in full)
curl -sf "${DEPLOY_URL}${BUNDLE_URL}" \
  | grep -qF "$EXPECTED_PREFIX" \
  && echo "[vercel-ops] CONFIRMED: $VAR_NAME prefix found in bundle" \
  || echo "[vercel-ops] NOT FOUND: $VAR_NAME prefix absent — redeploy required"
```

**Redeploy requirement**: env changes do not take effect until a new deployment. After any `NEXT_PUBLIC_*` change:

```bash
# Trigger a new deployment (must be from the project's deploy directory)
# See vercel-deploy skill for the full pipeline
# Minimum: verify the new deployment URL contains the updated value
echo "[vercel-ops] NEXT_PUBLIC_* change recorded — redeploy required before change is live"
```

---

## Operation 6: Custom Domain Attachment and DNS Verification

> **Warning**: Do NOT assume nameserver changes are safe. Only add domains; never remove or transfer.

```bash
# DOMAIN — e.g. app.quantic.io
# Requires: VERCEL_TOKEN, VERCEL_PROJECT_ID, VERCEL_ORG_ID

# Step 1: check current domain config
curl -sf \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$VERCEL_PROJECT_ID/domains?teamId=$VERCEL_ORG_ID" \
  | python3 -c "
import sys, json
domains = json.load(sys.stdin).get('domains', [])
for d in domains:
    print(f\"{d['name']} verified={d.get('verified')} redirect={d.get('redirect','')}\")
"

# Step 2: add domain (idempotent — safe to re-run)
curl -sf -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.vercel.com/v9/projects/$VERCEL_PROJECT_ID/domains?teamId=$VERCEL_ORG_ID" \
  -d "{\"name\": \"$DOMAIN\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Domain:', d.get('name'), 'verified:', d.get('verified'))"

# Step 3: inspect DNS verification status
curl -sf \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$VERCEL_PROJECT_ID/domains/$DOMAIN?teamId=$VERCEL_ORG_ID" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('verification', [])
print('Verified:', d.get('verified'))
for rec in v:
    print(f\"  DNS record required: type={rec['type']} name={rec['domain']} value={rec['value']}\")
"

# Step 4: smoke-test domain reachability (HTTP 200/301/302 = OK)
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 "https://$DOMAIN" 2>/dev/null || echo "000")
echo "[vercel-ops] https://$DOMAIN → HTTP $HTTP_STATUS"
[ "$HTTP_STATUS" = "000" ] && echo "[vercel-ops] WARNING: domain not yet reachable — DNS propagation may still be in progress"
```

---

## Operation 7: Deployment Protection Inspection

```bash
# List recent deployments and their protection state
curl -sf \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v13/deployments?projectId=$VERCEL_PROJECT_ID&teamId=$VERCEL_ORG_ID&limit=5" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for d in data.get('deployments', []):
    print(f\"{d['url']} state={d.get('state')} protected={d.get('isInSystemProtection', False)}\")
"
```

---

## Operation 8: Write .vercel/project.json (Direct Link, Never vercel link)

```bash
# DEPLOY_DIR — local directory to deploy from
mkdir -p "$DEPLOY_DIR/.vercel"
cat > "$DEPLOY_DIR/.vercel/project.json" <<'PROJECTEOF'
{
  "orgId": "VERCEL_ORG_ID_PLACEHOLDER",
  "projectId": "VERCEL_PROJECT_ID_PLACEHOLDER"
}
PROJECTEOF

# Replace placeholders with real values
python3 -c "
import json
with open('$DEPLOY_DIR/.vercel/project.json') as f:
    d = json.load(f)
d['orgId'] = '$VERCEL_ORG_ID'
d['projectId'] = '$VERCEL_PROJECT_ID'
with open('$DEPLOY_DIR/.vercel/project.json', 'w') as f:
    json.dump(d, f, indent=2)
print('[vercel-ops] .vercel/project.json written')
"
```

---

## Regression Checklist

Run before sign-off on any Vercel operation. Check each item explicitly.

| Check | Command / Assertion | Pass Condition |
|-------|---------------------|----------------|
| **Correct project** | Verify API returns expected `name` for `VERCEL_PROJECT_ID` | Name matches expected |
| **Correct target env** | Confirm `target` in env var payload is intentional | `production`, `preview`, or `development` as intended |
| **No trailing newline** | `printf '%s' "$VAL" \| wc -c` | Byte count matches known-good length |
| **NEXT_PUBLIC_* redeployed** | Bundle search for value prefix | Prefix present in bundle after redeploy |
| **Redeploy triggered** | New deployment exists with READY state | Deployment URL is new, state=READY |
| **Domain verified** | API returns `verified: true` | No pending DNS records |
| **No secrets in logs** | Scan stdout/stderr for value patterns | Zero matches |
| **No secrets in git** | `git diff --cached` | No secret values staged |

---

## Playbook Recording Pattern

After any operation that mutates project state, record in the repo playbook (never in this skill):

```
# Playbook entry format:
# VERCEL_PROJECT_ID: prj_xxxxx
# VERCEL_ORG_ID: team_xxxxx
# domains: [app.example.com]
# env_vars:
#   NEXT_PUBLIC_TURNSTILE_SITE_KEY: target=production,preview len=25 sha256=<sum> last_set=2026-07-15
# last_verified: 2026-07-15
```

---

## Error Handling

| Error | Likely Cause | Remedy |
|-------|-------------|--------|
| `project not found` | Wrong `VERCEL_PROJECT_ID` or token lacks access | Verify ID from Vercel dashboard; check token scope |
| `403 Forbidden` | Token expired or insufficient scope | Rotate `VERCEL_TOKEN` |
| `domain already in use` | Domain attached to a different project | Check which project owns it via API before proceeding |
| `length mismatch on env var` | Trailing newline from `echo` | Delete and re-write using `printf '%s'` |
| `NEXT_PUBLIC_* not in bundle` | Change made but no redeploy | Trigger new deployment via `vercel-deploy` skill |
| `DNS not verified` | Nameserver/CNAME not yet propagated | Wait and re-check; do not make other changes |

---

## Provenance

- Vercel API reference: https://vercel.com/docs/rest-api
- Vercel CLI env commands: https://vercel.com/docs/cli/env
- Vercel project linking: https://vercel.com/docs/cli/project
- `NEXT_PUBLIC_*` compile behavior: https://nextjs.org/docs/app/building-your-application/configuring/environment-variables#bundling-environment-variables-for-the-browser
- Trigger incident: quantic-v2#44 — `NEXT_PUBLIC_TURNSTILE_SITE_KEY` written with `echo`, introduced 26-byte value (1 trailing newline), broke Turnstile widget
