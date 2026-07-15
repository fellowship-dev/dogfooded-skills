---
name: vercel-ops
description: Use when safely inspecting or changing an existing Vercel project's environment variables, root-directory link, preview deployments, deployment protection, or custom domains.
allowed-tools: Read, Bash
---

# vercel-ops

Operate an existing Vercel project without leaking values, targeting the wrong project or environment, or mistaking an environment change for a deployed change.

## When to Use

- Audit, add, update, or synchronize Vercel environment variables
- Diagnose trailing whitespace or cross-provider value mismatches without printing values
- Verify a `NEXT_PUBLIC_*` value was compiled into a new deployment
- Inspect deployment protection or smoke-test a protected deployment
- Attach or verify a custom domain without assuming a DNS-provider change
- Create an explicit, on-demand Preview deployment

## When Not to Use

- Production deployment execution; use [`vercel-deploy`](../vercel-deploy/SKILL.md)
- Creating a Vercel project or connecting a Git repository
- Enabling automatic Preview deployments for every branch
- Editing DNS at an external provider without that provider's runbook and explicit authorization

## Prerequisites

Read the repository playbook first. Resolve these inputs there; never add site-specific values to this public skill:

| Input | Purpose |
| --- | --- |
| `VERCEL_ORG_ID` | Expected team ID |
| `VERCEL_PROJECT_ID` | Expected existing project ID |
| `EXPECTED_PROJECT_NAME` | Second factor for the project guard |
| `DEPLOY_DIR` | Directory from which Vercel CLI must run |
| Expected Root Directory | Empty for a root app, or the project setting for a monorepo app |
| Domains and canonical host | Domain attachment and redirect expectations |
| Environment requirements | Required keys in Production, Preview, and Development |
| Preview policy | On-demand only, unless the playbook explicitly says otherwise |
| Last verification date | `YYYY-MM-DD` |

Verify tools and the only required credential:

```bash
[ -n "$VERCEL_TOKEN" ] || { printf '%s\n' '[vercel-ops] VERCEL_TOKEN is missing'; exit 1; }
command -v curl >/dev/null || exit 1
command -v python3 >/dev/null || exit 1
command -v npx >/dev/null || exit 1
command -v sha256sum >/dev/null || command -v shasum >/dev/null || exit 1
```

> **Warning:** Never pass a literal secret on the command line. Load it into `VAL` from the authorized secret store without logging it. Disable shell tracing with `set +x` before handling values.

## Workflow

### 1. Guard the project before every mutation

Call the API before writing `.vercel/project.json`, changing an environment variable, attaching a domain, or starting a deployment:

```bash
set +x

PROJECT_JSON=$(curl --fail --silent --show-error \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$VERCEL_PROJECT_ID?teamId=$VERCEL_ORG_ID") || exit 1

ACTUAL_PROJECT_ID=$(printf '%s' "$PROJECT_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('id',''))")
ACTUAL_PROJECT_NAME=$(printf '%s' "$PROJECT_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('name',''))")
ACTUAL_ROOT_DIRECTORY=$(printf '%s' "$PROJECT_JSON" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('rootDirectory') or '')")

[ "$ACTUAL_PROJECT_ID" = "$VERCEL_PROJECT_ID" ] || {
  printf '%s\n' '[vercel-ops] STOP: project ID mismatch'
  exit 1
}
[ "$ACTUAL_PROJECT_NAME" = "$EXPECTED_PROJECT_NAME" ] || {
  printf '[vercel-ops] STOP: expected project %s, API returned %s\n' \
    "$EXPECTED_PROJECT_NAME" "$ACTUAL_PROJECT_NAME"
  exit 1
}

printf '[vercel-ops] guarded project=%s rootDirectory=%s\n' \
  "$ACTUAL_PROJECT_NAME" "${ACTUAL_ROOT_DIRECTORY:-<root>}"
```

If either comparison fails, stop. Never search for a similarly named project and continue automatically.

### 2. Set the CLI root and link directly

Vercel's Root Directory setting also applies to CLI operations. For a configured monorepo Root Directory, run the CLI at the repository root; do not append the Root Directory again through `--cwd` or by changing into that subdirectory.

| API `rootDirectory` | `DEPLOY_DIR` | Rule |
| --- | --- | --- |
| Empty | App/project root | Run CLI there |
| `frontend`, `apps/web`, or another path | Repository root | Let Vercel apply the configured path once |
| Different from the playbook | None | Stop and reconcile before linking |

After the project guard passes, write the link without `vercel link`:

```bash
[ -d "$DEPLOY_DIR" ] || { printf '[vercel-ops] missing DEPLOY_DIR: %s\n' "$DEPLOY_DIR"; exit 1; }
mkdir -p "$DEPLOY_DIR/.vercel"
printf '{\n  "orgId": "%s",\n  "projectId": "%s"\n}\n' \
  "$VERCEL_ORG_ID" "$VERCEL_PROJECT_ID" > "$DEPLOY_DIR/.vercel/project.json"
```

Do not commit `.vercel/project.json`. Verify `.vercel/` is ignored before continuing:

```bash
git check-ignore "$DEPLOY_DIR/.vercel/project.json" >/dev/null || {
  printf '%s\n' '[vercel-ops] STOP: .vercel/project.json is not ignored'
  exit 1
}
```

### 3. Inventory environment targets without reading values

List metadata deliberately for each default environment:

```bash
for TARGET in production preview development; do
  (cd "$DEPLOY_DIR" && npx vercel env ls "$TARGET" --token="$VERCEL_TOKEN") || exit 1
done
```

Do not infer that a key in Production also exists in Preview or Development. Preview branch overrides can supersede the default Preview value.

| Target | Used by | Mutation argument |
| --- | --- | --- |
| `production` | Next Production deployment | `production` |
| `preview` | Next Preview deployment; optional branch override | `preview [git-branch]` |
| `development` | Local development | `development` |

### 4. Fingerprint a value without printing it

Measure the authorized source value before writing it:

```bash
set +x
SOURCE_BYTES=$(printf '%s' "$VAL" | wc -c | tr -d ' ')

if command -v sha256sum >/dev/null 2>&1; then
  SOURCE_SHA256=$(printf '%s' "$VAL" | sha256sum | awk '{print $1}')
else
  SOURCE_SHA256=$(printf '%s' "$VAL" | shasum -a 256 | awk '{print $1}')
fi

case "$VAL" in
  *$'\n'|*$'\r')
    printf '[vercel-ops] STOP: source has trailing CR/LF; bytes=%s sha256=%s\n' \
      "$SOURCE_BYTES" "$SOURCE_SHA256"
    exit 1
    ;;
esac

printf '[vercel-ops] source bytes=%s sha256=%s trailing_crlf=no\n' \
  "$SOURCE_BYTES" "$SOURCE_SHA256"
```

> **Warning:** Never use `echo "$VAL"`, `wc -c <<< "$VAL"`, or a here-document for the value. Each adds a newline. A valid Turnstile site key that should be 24 bytes becomes 25 bytes under those patterns.

Compare providers only by expected byte count and SHA-256. A mismatch means stop and determine which provider is authoritative; do not copy whichever value is easiest to retrieve.

### 5. Add or update one target safely

Classify the variable before mutation:

| Variable | Classification | Verification boundary |
| --- | --- | --- |
| `NEXT_PUBLIC_*` | Public, build-time browser value | Fingerprint, new deployment, bundle/behavior check |
| Server credential/token | Secret | Fingerprint and authenticated server behavior only |
| Branch-specific Preview value | Environment override | Verify the named branch and its Preview deployment |

Repeat the project guard immediately before the mutation. Then pipe the value with `printf`:

```bash
set +x
printf '%s' "$VAL" | (cd "$DEPLOY_DIR" && \
  npx vercel env add "$ENV_NAME" "$TARGET" \
    --force --yes --token="$VERCEL_TOKEN") || exit 1
```

For an existing variable, use the explicit update operation:

```bash
set +x
printf '%s' "$VAL" | (cd "$DEPLOY_DIR" && \
  npx vercel env update "$ENV_NAME" "$TARGET" \
    --yes --token="$VERCEL_TOKEN") || exit 1
```

Add a branch name only for an authorized Preview override:

```bash
set +x
printf '%s' "$VAL" | (cd "$DEPLOY_DIR" && \
  npx vercel env add "$ENV_NAME" preview "$PREVIEW_BRANCH" \
    --force --yes --token="$VERCEL_TOKEN") || exit 1
```

Do not use `vercel env pull` to inspect sensitive values; it writes plaintext to disk. For authorized in-memory verification, run a command inside the selected environment and emit metadata only:

```bash
(cd "$DEPLOY_DIR" && npx vercel env run --environment="$TARGET" \
  --token="$VERCEL_TOKEN" -- node -e '
    const crypto = require("node:crypto");
    const key = process.argv[2];
    const value = process.env[key];
    if (value === undefined) process.exit(2);
    const bytes = Buffer.byteLength(value);
    const sha = crypto.createHash("sha256").update(value).digest("hex");
    const trailing = /[\r\n]$/.test(value);
    process.stdout.write(JSON.stringify({ key, bytes, sha256: sha, trailingCRLF: trailing }) + "\n");
  ' "$ENV_NAME") || exit 1
```

Require the remote byte count and checksum to match the source fingerprint. Never emit `value`.

### 6. Redeploy the affected environment

Environment changes apply only to new deployments. Record the mutation, then create the required new deployment:

- Production: use [`vercel-deploy`](../vercel-deploy/SKILL.md); do not reproduce its pipeline here.
- Preview: create one explicit on-demand deployment after repeating the project guard.
- Development: restart the local process that consumes the environment.

Create an explicit Preview deployment without enabling automatic previews:

```bash
PREVIEW_URL=$(cd "$DEPLOY_DIR" && \
  npx vercel deploy --token="$VERCEL_TOKEN" --yes) || exit 1
printf '[vercel-ops] preview deployment created: %s\n' "$PREVIEW_URL"
```

### 7. Verify a public build-time value

For Next.js, `NEXT_PUBLIC_*` references are inlined into browser JavaScript at build time and remain frozen in that build. Verify the new deployment, not an old URL.

The following check fetches the route and its JavaScript without printing the public value:

```bash
export VERIFY_URL="${PREVIEW_URL:-https://$PROD_DOMAIN}"
export EXPECTED_PUBLIC_VALUE="$VAL"

node <<'NODE'
const { URL } = require('node:url');

async function main() {
  const page = await fetch(process.env.VERIFY_URL, { redirect: 'follow' });
  if (!page.ok) throw new Error(`page returned ${page.status}`);
  const html = await page.text();
  const scripts = [...html.matchAll(/<script[^>]+src=["']([^"']+)["']/g)]
    .map((match) => new URL(match[1], page.url).href);
  let found = html.includes(process.env.EXPECTED_PUBLIC_VALUE);
  for (const script of scripts) {
    if (found) break;
    const response = await fetch(script);
    if (response.ok && (await response.text()).includes(process.env.EXPECTED_PUBLIC_VALUE)) {
      found = true;
    }
  }
  process.stdout.write(`public_build_value=${found ? 'found' : 'missing'} scripts_checked=${scripts.length}\n`);
  if (!found) process.exit(1);
}

main().catch((error) => {
  process.stderr.write(`[vercel-ops] bundle verification failed: ${error.message}\n`);
  process.exit(1);
});
NODE

unset EXPECTED_PUBLIC_VALUE
```

Also exercise the user-visible behavior that consumes the value. A bundle match does not prove that a widget, API, or integration accepts it.

### 8. Inspect deployment protection and smoke-test safely

Refresh the guarded project response and report only whether known protection
settings are configured. Never print a bypass configuration or secret:

```bash
PROJECT_JSON=$(curl --fail --silent --show-error \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/$VERCEL_PROJECT_ID?teamId=$VERCEL_ORG_ID") || exit 1

printf '%s' "$PROJECT_JSON" | python3 -c '
import json, sys
project = json.load(sys.stdin)
summary = {
    "ssoProtectionConfigured": bool(project.get("ssoProtection")),
    "passwordProtectionConfigured": bool(project.get("passwordProtection")),
    "protectionBypassConfigured": bool(project.get("protectionBypass")),
}
print(json.dumps(summary, sort_keys=True))
'
```

First test without credentials and record only the status and redirect destination:

```bash
curl --silent --show-error --output /dev/null \
  --write-out 'status=%{http_code} redirect=%{redirect_url}\n' \
  --max-time 15 "$VERIFY_URL"
```

If protection is expected and `VERCEL_AUTOMATION_BYPASS_SECRET` is authorized, send it only as a header:

```bash
set +x
curl --silent --show-error --output /dev/null \
  --header "x-vercel-protection-bypass: $VERCEL_AUTOMATION_BYPASS_SECRET" \
  --write-out 'protected_status=%{http_code}\n' \
  --max-time 15 "$VERIFY_URL"
```

Never put the bypass secret in a report or command output. Use the query-string form only for a third-party webhook that cannot set headers and is explicitly authorized.

### 9. Attach and verify a custom domain

Inventory before mutation:

```bash
(cd "$DEPLOY_DIR" && npx vercel domains ls --token="$VERCEL_TOKEN") || exit 1
(cd "$DEPLOY_DIR" && npx vercel domains inspect "$PROD_DOMAIN" \
  --token="$VERCEL_TOKEN") || true
dig +short NS "$PROD_DOMAIN"
dig +short A "$PROD_DOMAIN"
dig +short CNAME "$PROD_DOMAIN"
```

Repeat the project guard, obtain explicit approval for the attachment, and add without `--force`:

```bash
(cd "$DEPLOY_DIR" && npx vercel domains add \
  "$PROD_DOMAIN" "$EXPECTED_PROJECT_NAME" \
  --token="$VERCEL_TOKEN") || exit 1
```

Inspect the exact records Vercel recommends. If an external DNS provider is authoritative, change records there under its own runbook; do not switch nameservers or run `vercel dns add`:

```bash
(cd "$DEPLOY_DIR" && npx vercel domains inspect "$PROD_DOMAIN" \
  --token="$VERCEL_TOKEN") || exit 1
dig +short NS "$PROD_DOMAIN"
curl --head --silent --show-error --max-time 15 "https://$PROD_DOMAIN/"
printf '' | openssl s_client -connect "$PROD_DOMAIN:443" \
  -servername "$PROD_DOMAIN" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

Vercel provisions TLS after domain and DNS verification. Do not call the domain complete until Vercel reports it configured, HTTPS succeeds, and the certificate covers the hostname.

### 10. Record project facts in the repo playbook

Record facts in the private/project-specific playbook, never in this public skill:

```yaml
vercel:
  org_id: <team ID>
  project_id: <project ID>
  project_name: <exact name>
  cli_cwd: <repository or app root>
  root_directory: <empty or configured path>
  domains: [<canonical>, <alternates>]
  env_targets:
    production: [<required key names>]
    preview: [<required key names>]
    development: [<required key names>]
  preview_policy: on-demand
  last_verified: YYYY-MM-DD
```

Store key names and requirements, not values or fingerprints. Fingerprints can become sensitive correlation material and go stale after rotation.

## Regression Checklist

| Control | Pass evidence | Failure caught |
| --- | --- | --- |
| Project guard | API ID and exact name both match playbook | Wrong team/project |
| Root Directory | API setting matches playbook and CLI runs from the correct root | Doubled path |
| Environment target | Key listed in each intended target/branch | Wrong or missing target |
| Input integrity | Byte count and SHA match; trailing CR/LF is false | Trailing newline/whitespace |
| Secret handling | Logs contain metadata only; no pull file exists | Secret disclosure |
| Redeployment | New deployment ID/URL created after mutation | Missing redeploy |
| Public compile check | New bundle contains expected `NEXT_PUBLIC_*` value | Stale build-time value |
| Integration behavior | Representative browser/API flow succeeds | Correct bundle, broken consumer |
| Protection | Expected unauthenticated and bypassed statuses recorded | False smoke failure/challenge page |
| Domain | Project attachment, provider DNS, HTTPS, and certificate agree | Domain/DNS/TLS misconfiguration |
| Preview policy | One on-demand Preview URL; no global setting changed | Accidental automatic previews |
| Playbook | IDs, roots, domains, requirements, and date updated | Rediscovery and future drift |

## Error Handling

**API returns 401/403** — stop. Confirm token scope and team ownership without printing the token.

**Project ID exists but name differs** — stop before mutation. Treat this as a wrong-project incident, not a rename to accept automatically.

**Remote fingerprint differs** — stop. Check the selected target and branch override, then overwrite only after identifying the authoritative source.

**Value has 25 bytes instead of an expected 24** — test for trailing CR/LF and replace with the `printf '%s'` pattern. Never trim arbitrary whitespace from a credential.

**New deployment still has the old public value** — verify the deployment was built after the mutation, targeted the intended environment, and did not inherit a branch-specific override.

**Preview smoke test returns a login or challenge** — inspect Deployment Protection. Use an authorized automation-bypass header; do not report the application as down from the challenge response.

**Domain is attached but TLS is pending** — keep existing traffic unchanged, follow the records from `vercel domains inspect`, and recheck after DNS propagation.

**Domain belongs to another project** — stop. Never use `--force` without explicit reassignment approval and a rollback plan.

## Critical Rules

- Verify project ID and exact name through the API immediately before every mutation.
- Never create a project, run `vercel link`, connect Git, or globally enable automatic previews.
- Never write environment values with `echo`, a here-string, or a here-document; use `printf '%s'`.
- Never print values, enable shell tracing around values, or use `vercel env pull` for sensitive inspection.
- Target Production, Preview, Development, and Preview branches deliberately; never assume propagation between them.
- Redeploy after every environment change; old deployments retain old values.
- Treat every `NEXT_PUBLIC_*` value as public and build-time data, never as a secret.
- Do not change nameservers merely because a domain is attached to Vercel.
- Use `--token="$VERCEL_TOKEN"` on every Vercel CLI call and `--yes` on commands that expose that prompt-suppression option. `vercel domains add` has no `--yes` option; never invent unsupported flags.
- Use `vercel-deploy` as the sole Production deployment authority.

## Provenance

Primary sources used for the operational claims and command shapes:

- [Vercel CLI environment commands](https://vercel.com/docs/cli/env) — targets, branch overrides, stdin updates, `env run`, `--force`, `--yes`, and token usage
- [Vercel environment variables](https://vercel.com/docs/environment-variables) — Production/Preview/Development semantics and the new-deployment requirement
- [Vercel Root Directory configuration](https://vercel.com/docs/builds/configure-a-build#root-directory) and [monorepos](https://vercel.com/docs/monorepos) — Root Directory applies to CLI and the CLI runs at the monorepo root
- [Vercel REST API](https://vercel.com/docs/rest-api) — bearer authentication, team scoping, and project/domain resources
- [Vercel custom-domain setup](https://vercel.com/docs/domains/set-up-custom-domain) — inspect-first DNS guidance, external DNS providers, verification, and TLS provisioning
- [Vercel Deployment Protection](https://vercel.com/docs/deployment-protection) and [automation bypass](https://vercel.com/docs/deployment-protection/methods-to-bypass-deployment-protection/protection-bypass-automation) — protected scopes and the recommended bypass header
- [Vercel environments](https://vercel.com/docs/deployments/environments) — explicit Preview versus Production deployments
- [Next.js environment variables](https://nextjs.org/docs/app/guides/environment-variables#bundling-environment-variables-for-the-browser) — `NEXT_PUBLIC_*` build-time browser inlining
- Trigger incident: [fellowship-dev/quantic-v2#44](https://github.com/fellowship-dev/quantic-v2/issues/44); implementation PRD: [fellowship-dev/dogfooded-skills#95](https://github.com/fellowship-dev/dogfooded-skills/issues/95)
