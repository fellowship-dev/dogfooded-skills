# Interactive Flow Contract

Use this contract for production and on-demand preview verification. Keep client identifiers,
deployment IDs, and secret values in the target repository or its playbook, never in this skill.

## Configuration

Declare identity and every target explicitly:

```yaml
identity:
  repo: fellowship-dev/quantic-v2

environments:
  local:
    url: http://localhost:3000
    captcha:
      mode: disabled
  preview:
    mode: on-demand       # on-demand | existing | disabled
    provider: vercel
  production:
    url: https://quantic.cl
    captcha:
      mode: required
      site_key_env: NEXT_PUBLIC_TURNSTILE_SITE_KEY

smoke:
  critical:
    - contact
    - locale-switch
```

`identity.repo` must equal the requested repository. Production and cron runs reject missing,
template-shaped, or localhost identities and targets. Keep preview configuration explicit even
when preview verification is disabled.

## CAPTCHA flow

```yaml
name: contact
interactive: true
affects: ["app/contact/**", "components/contact-*.tsx"]
evidence:
  browser: required
contract:
  captcha:
    - renders
    - token
    - submission
    - success-ui
    - backend-boundary
steps:
  - name: Turnstile renders
    action: wait
    selector: iframe[src*="turnstile"], input[name="cf-turnstile-response"]
    captcha: true
    optional: false
    expect: A visible challenge or completed Turnstile response control exists
  - name: Complete and submit
    action: submit
    selector: form
    expect: A non-empty Turnstile token is submitted and localized success UI appears
  - name: Confirm backend boundary
    action: wait
    expect: The expected request succeeds and the configured delivery boundary records receipt
```

For production and cron, a CAPTCHA step is never optional. Verify all five contract assertions.
A rendered script tag, bundle match, or static HTML control is diagnostic evidence only.

When a site key is available through the configured environment variable, validate it without
printing it:

```bash
SITE_KEY_ENV=$(yq '.environments.production.captcha.site_key_env // ""' .flowchad/config.yml)
if [ -n "$SITE_KEY_ENV" ]; then
  SITE_KEY=$(printenv "$SITE_KEY_ENV")
  [ -n "$SITE_KEY" ] || { echo "BLOCKED: CAPTCHA site key is empty"; exit 1; }
  TRIMMED=$(printf %s "$SITE_KEY" | awk '{$1=$1};1')
  [ "$SITE_KEY" = "$TRIMMED" ] || { echo "BLOCKED: CAPTCHA site key has surrounding whitespace"; exit 1; }
fi
unset SITE_KEY TRIMMED
```

## Localization flow

```yaml
name: locale-switch
interactive: true
affects: ["app/**", "messages/**"]
evidence:
  browser: required
contract:
  kind: i18n
  locales: [es, en]
  visible_regions: [header, main, form, footer]
steps:
  - name: Switch to English
    action: click
    selector: '[hreflang="en"]'
    expect: URL and html lang are en; representative English header text is visible
  - name: Check English main and form
    action: wait
    expect: Representative English main copy, form labels, validation, and submit text are visible
  - name: Check English footer
    action: wait
    expect: Representative English footer text is visible
```

Use exact representative strings or stable selectors from the target repo. URL and `<html lang>`
are necessary but insufficient. Assert header, main content, forms, and footer for every locale.

## Result states

| State | Meaning | Automation action |
| --- | --- | --- |
| `PASSED` | Every required step passed with browser evidence | Record run and preserve evidence |
| `FAILED` | Browser ran and demonstrated a product/flow regression | Create or update a deduplicated issue |
| `BLOCKED` | Required browser, credentials, target, or deploy capability was unavailable | Report capability; never certify a pass |
| `N/A` | PR is docs-only, Dependabot, or affects no declared flow | Do not create a preview |

Static HTML and curl may add diagnostics to `FAILED` or `BLOCKED`; they cannot produce `PASSED`
for an interactive flow.

## Recurring production smoke

Invoke the critical set with an explicit cron trigger:

```bash
/flowchad-runner all org/repo none cron
```

Cron reads only `smoke.critical`, requires `environments.production.url`, and never skips a
production-critical control. On failure, search for an open issue carrying the same repository,
flow, environment, and failure fingerprint before creating another. Append fresh browser evidence
to the existing issue when one exists.

The scheduler belongs to Pylot or the target repository. This public skill owns the stable cron
invocation and result contract, not the schedule.
