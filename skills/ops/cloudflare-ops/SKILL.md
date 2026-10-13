---
name: cloudflare-ops
description: Use when auditing, configuring, or verifying Cloudflare accounts, zones, DNS, Workers, Turnstile, Email Routing, or Redirect Rules — onboarding an account, changing client DNS, deploying a Worker, configuring contact-form email, checking token capabilities, consolidating credentials, or implementing canonical-host redirects.
allowed-tools: Read, Write, Edit, Bash
---

# cloudflare-ops

Operate Cloudflare accounts and zones through the API without leaking tokens, mutating the wrong zone, or discarding unrelated DNS records and rules.

## When to Use

- Onboard a Cloudflare account or zone into a repo's operational docs
- Audit or change DNS records, including cutovers to a new destination service
- Deploy or inspect Workers, Turnstile widgets, or Email Routing for a contact form
- Verify what a token can actually do before relying on it
- Redirect a source hostname (for example `www`) to a canonical host

## When Not to Use

- Changing nameservers at the registrar; treat that as a separate, explicitly approved change
- Vercel or Fly.io platform configuration; use [`vercel-ops`](../vercel-ops/SKILL.md) or [`fly-io`](../fly-io/SKILL.md)
- New legacy Page Rules; Cloudflare is deprecating them

## Source of truth

- Read the target repo's operational playbook or docs (for example `AGENTS.md`, `docs/`, or a runbook) first.
- Keep account IDs, zone IDs, endpoints, current state, secret location, and `Last verified: YYYY-MM-DD` in the target repo's docs.
- Make every repo's operational record self-contained: operators load the current repo's docs, not a parent or registry document. Repeat required account facts deliberately and use verification dates to expose drift.
- Keep secret values only in the repo's own secret store (local `.env` excluded from git, AWS Secrets Manager, Fly secrets, Vercel environment variables, or CI secrets, whichever the repo uses). Use `CLOUDFLARE_API_TOKEN`; prefer one token per Cloudflare account.
- Never copy client-specific IDs or token values into this skill, issues, logs, or git.

## Token baseline

Use an account-owned token when several operators or repos share the account. Scope resources to the relevant account and zones; use all zones only when intentional.

Required permissions for the standard DNS + contact-form workflow:

| Scope | Permission | Level |
| --- | --- | --- |
| Account | Workers Scripts | Edit |
| Account | Turnstile | Edit |
| Account | Email Routing Addresses | Edit |
| Account | Account Settings | Read |
| Zone | DNS | Edit |
| Zone | Email Routing Rules | Edit |
| Zone | Zone | Read |
| Zone | Zone Settings | Read |

`Edit` includes read/list access; do not add a duplicate Read grant. Add Workers Routes or storage permissions only when the implementation actually uses routes, KV, D1, or R2.

Zone Settings Read is sufficient for audit and DNS/contact-form work. Add Zone Settings Edit only when the operator must change settings such as Always Use HTTPS; the API returns an authentication error for those writes with Read alone.

## Audit before mutation

1. Load the token from the repo's secret store into `CLOUDFLARE_API_TOKEN`; never print it.
2. Verify the correct token type:
   - Account-owned: `GET /accounts/{account_id}/tokens/verify`
   - User-owned: `GET /user/tokens/verify`
   - Do not call a user-token endpoint and conclude an account token is invalid.
3. Verify the account and zone IDs recorded in the repo's docs against the API.
4. Read the full existing DNS/routing/Worker configuration before changing it.
5. Check the exact capability needed. A successful read does not prove Edit access.

For a DNS write probe, PATCH an existing record with its current TTL only when write verification is requested. Preserve every other field and confirm the record is unchanged afterward. Do not create disposable records that require cleanup.

Useful probes:

- DNS: `/zones/{zone_id}/dns_records`
- Zone discovery: `/zones?account.id={account_id}`
- Zone settings: `/zones/{zone_id}/settings/always_use_https`
- Email rules: `/zones/{zone_id}/email/routing/rules`
- Email destinations: `/accounts/{account_id}/email/routing/addresses`
- Workers: `/accounts/{account_id}/workers/scripts`
- Turnstile: `/accounts/{account_id}/challenges/widgets`

## Change safely

- Never delete, overwrite, or cut over production DNS without explicit approval.
- Diff desired versus current state. Preserve unrelated records, TTLs, proxy flags, comments, and settings.
- Treat nameserver changes separately from record changes; most cutovers need no NS change.
- Verify the destination service before DNS cutover, then verify public DNS, TLS, HTTP, and critical flows afterward.
- Permission changes do not require token rotation. Rotate only for compromise, expiry, inactivity, or an intentional credential replacement.

## Record the result

Update the repo's operational docs after verification:

- Cloudflare account name and ID
- Zone name and ID
- Credential env name and secret store location, never its value
- Workers.dev subdomain and relevant service names
- Current DNS/deployment state and pending cutovers
- Capabilities actually verified
- `Last verified: YYYY-MM-DD`

An infrastructure or registry document may remain the human-facing inventory, but it never replaces the complete operational block in each repo's own docs.

## Canonical-host Redirect Rules

Use this procedure when you need all traffic to a source hostname (e.g. `www`) to redirect to a canonical host (e.g. the apex or a preferred subdomain). Do not use legacy Page Rules for new work; Cloudflare is deprecating them.

### Token permissions

Add **Zone > Zone > Edit** to the token permissions listed in the baseline above. The rulesets API requires it.

| Scope | Permission | Level |
| --- | --- | --- |
| Zone | Zone | Edit |
| Zone | DNS | Edit |
| Zone | Zone Settings | Read |

### 1. Audit DNS and proxy state

```bash
# List all DNS records for the zone
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records" \
  | jq '.result[] | {name, type, content, proxied}'
```

Confirm the source hostname record exists and note its current `proxied` value. Redirect Rules only process proxied (orange-cloud) traffic; DNS-only (grey-cloud) traffic bypasses them entirely.

### 2. Audit existing rulesets before mutation

```bash
# List all rulesets on the http_request_dynamic_redirect phase
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/phases/http_request_dynamic_redirect/entrypoint" \
  | jq '.'
```

If a 404 is returned, the entrypoint ruleset does not exist yet. If rules are returned, record every existing rule's `id`, `description`, `expression`, and `action_parameters` before any mutation — never discard unrelated rules.

### 3. Enable proxy on the source hostname (if not already proxied)

Redirect Rules only see proxied traffic. If the source hostname is DNS-only, enable the Cloudflare proxy first.

```bash
# Get the record ID for the source hostname
RECORD_ID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={source_hostname}" \
  | jq -r '.result[0].id')

# PATCH to enable proxy — preserve all other fields
curl -s -X PATCH -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/$RECORD_ID" \
  -d '{"proxied": true}'
```

Confirm the record now shows `"proxied": true` in the response.

### 4. Build the redirect rule expression and target URL

Use the `http.host` field to match the exact source hostname. Build the target URL from the canonical scheme, canonical host, the original request path, and — deliberately — the original query string.

**Expression:**

```text
(http.host eq "{source_hostname}")
```

**Target URL** (dynamic redirect, preserving path and query string):

```text
concat("https://{canonical_host}", http.request.uri.path)
```

> The query string is preserved because both Step 5 examples explicitly set `preserve_query_string: true`. Do not omit that flag — Cloudflare defaults it to disabled.

**Loop-prevention check:** `{canonical_host}` must not equal `{source_hostname}`. Before applying, verify that the expression does not match the destination host.

Use HTTP **301** for an established canonical-host policy. Use 302 only during testing.

### 5. Apply the redirect rule

#### Case A — entrypoint ruleset already exists (has existing rules)

Fetch the current ruleset to get its `id` and full rules array, then PUT the entire updated rules array (existing rules plus the new rule). Never omit existing rules.

```bash
# Fetch current rules
RULESET=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/phases/http_request_dynamic_redirect/entrypoint")
RULESET_ID=$(echo "$RULESET" | jq -r '.result.id')

# Append new rule to existing rules and PUT the full array
curl -s -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/$RULESET_ID" \
  -d '{
    "rules": [
      <existing rules verbatim>,
      {
        "description": "Redirect {source_hostname} to canonical host",
        "expression": "(http.host eq \"{source_hostname}\")",
        "action": "redirect",
        "action_parameters": {
          "from_value": {
            "status_code": 301,
            "target_url": {
              "expression": "concat(\"https://{canonical_host}\", http.request.uri.path)"
            },
            "preserve_query_string": true
          }
        },
        "enabled": true
      }
    ]
  }'
```

#### Case B — no entrypoint ruleset yet

```bash
curl -s -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets" \
  -d '{
    "name": "default",
    "kind": "zone",
    "phase": "http_request_dynamic_redirect",
    "rules": [
      {
        "description": "Redirect {source_hostname} to canonical host",
        "expression": "(http.host eq \"{source_hostname}\")",
        "action": "redirect",
        "action_parameters": {
          "from_value": {
            "status_code": 301,
            "target_url": {
              "expression": "concat(\"https://{canonical_host}\", http.request.uri.path)"
            },
            "preserve_query_string": true
          }
        },
        "enabled": true
      }
    ]
  }'
```

Record the rule `id` returned in the response.

### 6. Decision table

| Scenario | Action |
| --- | --- |
| Source hostname is DNS-only (grey cloud) | PATCH DNS record to `proxied: true` before creating rule |
| Source hostname is already proxied | Skip DNS change; create rule only |
| Entrypoint ruleset exists with other rules | PUT full rules array (existing + new); never POST a new ruleset |
| Entrypoint ruleset does not exist | POST new ruleset with the redirect rule |
| Canonical host and source host would match | Stop; fix the expression — this would create a redirect loop |
| Existing Page Rule covers the same path | Document it; do not delete without explicit approval |

### 7. Verify

Allow up to 30 seconds for the rule to propagate, then verify all of the following:

```bash
# Root
curl -sI "https://{source_hostname}/" | grep -E "HTTP|location"

# Nested path
curl -sI "https://{source_hostname}/some/path" | grep -E "HTTP|location"

# Locale path
curl -sI "https://{source_hostname}/en/page" | grep -E "HTTP|location"

# Query string preserved
curl -sI "https://{source_hostname}/?utm_source=test" | grep -E "HTTP|location"

# Static asset
curl -sI "https://{source_hostname}/favicon.ico" | grep -E "HTTP|location"

# API path
curl -sI "https://{source_hostname}/api/health" | grep -E "HTTP|location"
```

For each case, confirm:

- Response is `301` (not 302, not 200, not loop).
- `location:` header points to `https://{canonical_host}` + the original path.
- Query string is present in the `location:` header when it was in the request.
- No second hop (the canonical host must not redirect again).

Also verify the canonical host itself remains healthy:

```bash
curl -sI "https://{canonical_host}/" | grep -E "HTTP"
```

Expect `200` (or the application's normal response). A redirect loop registers as an infinite chain of 301s; stop at 2 hops.

### 8. Record the result

Add to the repo's operational docs:

```markdown
## Canonical-host redirect

| Field | Value |
| --- | --- |
| Rule ID | {rule_id} |
| Rule name / description | Redirect {source_hostname} to canonical host |
| Source hostname | {source_hostname} |
| Canonical host | {canonical_host} |
| Source DNS proxy state | proxied (pre-existing / enabled by this procedure on YYYY-MM-DD — delete as appropriate) |
| Redirect type | 301 Single Redirect, http_request_dynamic_redirect phase |
| Path / query string preserved | Yes |
| Last verified | YYYY-MM-DD |
```

Never write client-specific domains, account IDs, zone IDs, or token values into this skill.

### 9. Rollback

If the redirect is incorrect or causing a loop, disable or delete the rule and restore the previous DNS proxy state.

```bash
# Disable the rule (safe — leaves other rules intact)
# Fetch current ruleset to get rule position, then PUT with "enabled": false for this rule only.

# Delete the rule (fetch ruleset, remove the rule from the array, PUT the remainder)
RULESET=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/phases/http_request_dynamic_redirect/entrypoint")
RULESET_ID=$(echo "$RULESET" | jq -r '.result.id')

# PUT all rules except the one you are removing
curl -s -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets/$RULESET_ID" \
  -d '{"rules": [<all rules except the redirect rule>]}'
```

If you enabled the proxy on the source hostname during step 3 and want to revert it:

```bash
curl -s -X PATCH -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}" \
  -d '{"proxied": false}'
```

Confirm the redirect no longer fires after rollback with `curl -sI "https://{source_hostname}/"`. Verify the canonical host is still healthy.
