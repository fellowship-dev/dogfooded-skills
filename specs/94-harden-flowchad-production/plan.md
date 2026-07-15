# Implementation Plan: Harden Flowchad Production and On-Demand Preview Verification

**Branch**: `feat/94-harden-flowchad-production` | **Date**: 2026-07-15 | **Spec**: [spec.md](./spec.md)
**Input**: `/specs/94-harden-flowchad-production/spec.md`

---

## Summary

Update the `flowchad-runner` skill (stages 01, 03, 05 and SKILL.md) to enforce
environment-aware config validation, treat CAPTCHA failures as non-optional, block on
missing browser capability instead of silently certifying, add on-demand PR preview
provisioning with Dependabot/docs-only exemption, and document a `cron` mode with issue
deduplication. As dogfood evidence, update two reference flow files in `fellowship-dev/quantic-v2`
to carry the stronger CAPTCHA and i18n visible-copy assertions.

---

## Technical Context

- **Language/Version**: Markdown / YAML / Bash (skill instruction files — no compiled artifact)
- **Primary Dependencies**: None (skill files are read by the Claude operator at runtime)
- **Storage**: N/A
- **Testing**: Manual skill invocation and dogfood evidence against quantic-v2 + one other site
- **Target Platform**: Pylot Fargate operator, read from S3 at runtime
- **Project Type**: skill-definition (Markdown/YAML)
- **Performance Goals**: N/A
- **Constraints**: All stage CONTEXT.md changes must stay within the existing 5-stage ICM
  structure; no new stages, no new handoff file locations
- **Scale/Scope**: One skill (flowchad-runner), 5 stage files + SKILL.md + 2 downstream
  flow YAMLs in quantic-v2

---

## Constitution Check

No violations — skill changes are additive guards that enforce quality, consistent with the
project constitution's testing and correctness principles.

---

## Project Structure

```text
skills/ops/flowchad-runner/
├── SKILL.md                        # invocation reference — add Cron mode section
├── CONTEXT.md                      # architecture overview — minor update
├── stages/
│   ├── 01-preflight/CONTEXT.md     # add: config validation, cron URL check, on-demand preview
│   ├── 02-load-flows/CONTEXT.md    # unchanged
│   ├── 03-walk-flows/CONTEXT.md    # add: CAPTCHA blocking, no-browser blocking, blocked_reason
│   ├── 04-upload-evidence/CONTEXT.md  # unchanged
│   └── 05-report/CONTEXT.md        # add: blocked outcome, deduplication, capability issue
specs/94-harden-flowchad-production/
├── spec.md
├── plan.md                         # this file
└── tasks.md                        # phase 2 output
```

Cross-repo changes (dogfood evidence — separate commits to `fellowship-dev/quantic-v2`):
```text
.flowchad/config.yml                # add name, auto_preview: false, smoke.critical flags
.flowchad/flows/contact-form.yml    # harden CAPTCHA assertion (remove "Optional:" qualifier)
.flowchad/flows/language-switch.yml # add visible-copy assertions for nav + hero content
```

---

## Approach by Requirement

### FR-001 & FR-002 — Config validation in stage 01

In `stages/01-preflight/CONTEXT.md`, add a **Step 1b: Config Identity Validation** block
immediately after setup, before URL resolution. It runs only when `TRIGGER` is `cron` or
`merge`:

```bash
# Validate config identity (cron and merge only)
if [ "$TRIGGER" = "cron" ] || [ "$TRIGGER" = "merge" ]; then
  CONFIG_NAME=$(yq '.name // ""' .flowchad/config.yml)
  CONFIG_URL=$(yq '.url // ""' .flowchad/config.yml)

  if [ "$CONFIG_NAME" = "booster-pack" ] || echo "$CONFIG_URL" | grep -q "localhost"; then
    # Write handoff blocked: true, block_reason: stale template identity in config.yml
    exit 1
  fi

  # FR-002: production URL required for cron
  if [ "$TRIGGER" = "cron" ]; then
    PROD_URL=$(yq '.environments.production.url // ""' .flowchad/config.yml)
    if [ -z "$PROD_URL" ]; then
      # Write handoff blocked: true, block_reason: no production URL for cron trigger
      exit 1
    fi
  fi
fi
```

The handoff gains two new fields: `config_validated: true/false` and `stale_identity: true/false`.

### FR-009 & FR-010 — On-demand preview for PR trigger

In stage 01, after URL resolution for `pr` trigger, add a **PR Relevance Check + On-Demand
Deploy** block. Only runs when `TRIGGER=pr` AND no preview URL was resolved from existing
deployments:

```bash
if [ "$TRIGGER" = "pr" ] && [ -z "$TARGET_URL" ] && [ -n "$PR_NUMBER" ]; then
  # Check relevance exemptions
  LABELS=$(gh api repos/${REPO}/issues/${PR_NUMBER}/labels --jq '.[].name')
  FILES=$(gh api repos/${REPO}/pulls/${PR_NUMBER}/files --jq '.[].filename')

  IS_DEPS=$(echo "$LABELS" | grep -cx "dependencies")
  IS_DOCS_ONLY=$(echo "$FILES" | grep -cvE '^docs/|\.md$')  # 0 = all docs

  if [ "$IS_DEPS" -gt 0 ] || [ "$IS_DOCS_ONLY" -eq 0 ]; then
    ON_DEMAND_DEPLOY="skipped"   # exempt — write note in handoff
  else
    # Trigger on-demand Vercel preview deploy via deployment-checker skill or Vercel API
    ON_DEMAND_DEPLOY="triggered"
    # ... wait for deploy, set TARGET_URL to the preview URL
  fi
fi
```

Handoff adds: `on_demand_deploy: triggered/skipped/n/a`.

### FR-003 & FR-004 — CAPTCHA enforcement in stage 03

In `stages/03-walk-flows/CONTEXT.md`, update the **2b. Execute each step** section:

- When a step has `captcha: true` and is NOT marked `optional: true`:
  - A CAPTCHA render failure (widget not visible) → step status `fail` (not `skip`)
  - Flow-level verdict: `fail`
- Add a **CAPTCHA pre-check** before walking the flow:
  - If any non-optional step has `captcha: true` AND `navvi_available=false` AND trigger is
    `cron` or `merge` → mark flow `blocked`, `blocked_reason: CAPTCHA step requires Navvi; Navvi unavailable`; skip walking.

### FR-005 — No-browser blocked outcome in stage 03

Add a **Browser Availability Pre-check** at the top of stage 03, before the per-flow loop:

```bash
PLAYWRIGHT_OK=false
node -e "require('playwright-core')" 2>/dev/null && PLAYWRIGHT_OK=true

if [ "$PLAYWRIGHT_OK" = "false" ] && [ "$NAVVI_AVAILABLE" = "false" ]; then
  # Mark ALL flows as blocked
  for FLOW in $FLOWS_TO_RUN; do
    # record: status=blocked, blocked_reason=no browser available
  done
  # write handoff, exit stage
fi
```

### FR-006 — Blocked outcome in stage 05

In `stages/05-report/CONTEXT.md`, add outcome logic:

- If any flow has `status=blocked` → overall status is `BLOCKED`
- Emit `[pylot] outcome="flowchad ... blocked: {reason}" status=blocked`
- Create a GitHub issue: "FlowChad blocked: no browser available — {REPO}" with
  the missing-capability explanation; label `ready-to-work`
- The `status=success` marker is NEVER emitted when any flow is blocked

### FR-007 — language-switch.yml visible copy (quantic-v2)

The `nav` assert step expects only URL + `<html lang>`. Strengthen to:
```yaml
  - action: assert
    selector: "nav"
    expect: >
      English navigation titles "Home", "Services", "Clients", "Contact" are visible.
      Spanish titles "Inicio", "Servicios", "Clientes", "Contacto" MUST NOT appear.
```
Add a `main` assert step that verifies the hero section shows English copy ("Software
Consultancy") and not Spanish copy ("Consultora de Software") on the `/en/` page.
Mirror for the `/es/` direction.

### FR-008 — contact-form.yml CAPTCHA (quantic-v2)

The scroll step expect says `Optional: Turnstile CAPTCHA widget`. Remove "Optional:"; make
it a required assertion. The click/submit step's CAPTCHA note becomes a hard expect:

```yaml
  - action: scroll
    selector: "section#contacto"
    expect: >
      Contact section is visible with name, email, and message inputs.
      Turnstile CAPTCHA widget renders inside div.flex.justify-center (min-height: 72px).
      Widget must be visible and interactive — a missing or non-rendering widget is a FAIL.
    captcha: true
```

### FR-011 — Cron deduplication in stage 05

Before `gh issue create`, check for existing open issues:
```bash
EXISTING=$(gh issue list --repo "$REPO" --state open \
  --search "FlowChad failure: ${FLOW_NAME}" --json number --jq '.[0].number // empty')
if [ -z "$EXISTING" ]; then
  gh issue create ...
else
  echo "Dedup: open issue #${EXISTING} already exists for ${FLOW_NAME} — skipping create"
fi
```

### FR-012 — Cron mode docs in SKILL.md

Add a **## Cron Mode** section covering: what trigger value to pass, which flows are walked
(critical set from `smoke.flows[].critical: true`), how failure issues are created and
deduplicated, the expected weekly cadence, and that Pylot schedules the dispatch separately.

---

## Execution Order (sequential, each task unblocks the next)

1. Stage 01 config validation (FR-001, FR-002) — foundational gate, all stories depend on it
2. Stage 01 on-demand preview (FR-009, FR-010) — builds on step 1 handoff schema
3. Stage 03 CAPTCHA enforcement (FR-003, FR-004) — depends on stage 01 handoff schema
4. Stage 03 no-browser blocking (FR-005) — same file, sequential
5. Stage 05 blocked outcome + dedup (FR-006, FR-011) — reads stage 03 handoff
6. SKILL.md cron docs (FR-012) — references finalized behavior from steps 1–5
7. quantic-v2 contact-form.yml (FR-008) — downstream dogfood
8. quantic-v2 language-switch.yml (FR-007) — downstream dogfood
9. quantic-v2 config.yml schema additions — downstream dogfood
