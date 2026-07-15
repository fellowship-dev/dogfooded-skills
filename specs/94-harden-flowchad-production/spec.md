# Feature Specification: Harden Flowchad Production and On-Demand Preview Verification

**Feature Branch**: `feat/94-harden-flowchad-production`
**Created**: 2026-07-15
**Status**: Draft
**Input**: Issue #94 — harden Flowchad production and on-demand preview verification for interactive flows

## Background

FlowChad (flowchad-runner skill) correctly caught quantic-v2's broken contact form
([fellowship-dev/quantic-v2#44](https://github.com/fellowship-dev/quantic-v2/issues/44)) and
filed a bug. However, several gaps in the surrounding setup made detection weaker than it
should be:

1. **Identity leakage** — `config.yml` kept template-shaped `name: booster-pack` and
   `url: http://localhost:3000`; production/cron runs inherit stale identity.
2. **Soft CAPTCHA assertion** — `contact-form.yml` marked CAPTCHA as `optional`, so a
   broken Turnstile widget (site key with trailing newline) produced only a partial failure.
3. **Weak i18n coverage** — `language-switch.yml` only asserted URL and `<html lang>`,
   allowing Spanish navigation to appear under `/en`
   ([fellowship-dev/quantic-v2#45](https://github.com/fellowship-dev/quantic-v2/issues/45)).
4. **Fallback silently certifies** — when browser/Navvi is unavailable, curl/static analysis
   produced diagnostics but the run still passed, hiding the interactive-CAPTCHA gap.
5. **No recurring smoke** — no weekly production smoke is defined.
6. **Costly auto-previews** — no guard against Dependabot/docs-only PRs spawning Vercel
   preview deployments.

---

## User Scenarios & Testing

### User Story 1 — Environment-aware config validation (P1)

A worker running flowchad-runner on a production or cron trigger receives an immediate
hard error if the project's `.flowchad/config.yml` still carries template identity
(`booster-pack`, `localhost`), rather than silently inheriting wrong values.

**Acceptance**:
1. **Given** a `config.yml` with `name: booster-pack` and `url: http://localhost:3000`,
   **When** flowchad-runner runs with `trigger=cron` or `trigger=merge`,
   **Then** stage 01 writes `blocked: true`, `block_reason: stale template identity in config.yml`, and exits; no flows are walked.
2. **Given** a valid config with real `name` and resolved `url`,
   **When** flowchad-runner runs on any trigger,
   **Then** stage 01 resolves the URL and proceeds normally.
3. **Given** a `config.yml` with no production URL defined,
   **When** trigger is `cron`,
   **Then** stage 01 blocks with `block_reason: no production URL for cron trigger`.

---

### User Story 2 — CAPTCHA is non-optional in production flows (P1)

A contact-form flow step with CAPTCHA must not be skippable in production or cron contexts;
failing to complete the CAPTCHA widget must mark the flow as failed, not warn-and-continue.

**Acceptance**:
1. **Given** a flow YAML with a CAPTCHA step that lacks `optional: true`,
   **When** the CAPTCHA widget fails to render (Turnstile site key missing or malformed),
   **Then** stage 03 records the step as `fail` (not `skip`) and marks the flow `fail`.
2. **Given** a flow YAML with `captcha: true` on any step and `trigger=cron` or `trigger=production`,
   **When** `navvi_available=false`,
   **Then** stage 03 records the flow as `blocked` with `block_reason: CAPTCHA step requires Navvi; Navvi unavailable`; it does NOT pass.
3. **Given** a flow that has `captcha: true` and Navvi is available,
   **When** flowchad-runner walks it,
   **Then** the CAPTCHA step uses Navvi (not headless Playwright) and the flow is walked interactively.

---

### User Story 3 — i18n flows assert visible copy (P1)

Language-switch flows and any locale-specific flow must assert representative visible text
in header, main content, forms, and footer — not just URL and `<html lang>`.

**Acceptance**:
1. **Given** a `language-switch.yml` that navigates to `/en/`,
   **When** stage 03 evaluates the `nav` assert step,
   **Then** the expect string requires English-language nav titles (e.g. "Home", "Services")
   and MUST NOT accept Spanish titles under `/en/` as a passing result.
2. **Given** a language-switch flow that switches to `/es/`,
   **When** stage 03 evaluates the `main` assert step,
   **Then** the expect requires Spanish hero copy (e.g. "Consultora de Software") and
   rejects English copy as passing.
3. **Given** the current `language-switch.yml` assertions (URL + `<html lang>` only),
   **When** a static analysis agent or spec-conformance check inspects the flow,
   **Then** it flags the assertions as insufficient (visible copy not asserted).

---

### User Story 4 — Browser unavailability blocks, not certifies (P1)

If Playwright and Navvi are both unavailable, flowchad-runner must not certify interactive
flows as passed. Curl/static analysis may produce diagnostics, but the run outcome must be
`blocked` or `failed`, not `success`.

**Acceptance**:
1. **Given** Playwright is unavailable and Navvi is also unavailable,
   **When** a flow requires browser interaction (any `navigate`, `click`, `fill`, `scroll` step),
   **Then** stage 03 marks every such flow as `blocked` with `block_reason: no browser available (Playwright missing, Navvi unavailable)`.
2. **Given** the run is blocked due to no browser,
   **When** stage 05 aggregates,
   **Then** it emits `status=blocked` (not `status=success`), and creates a GitHub issue
   with the missing-capability reason.
3. **Given** curl/static HTML analysis succeeds for some subset of checks,
   **When** interactive steps are missing,
   **Then** the report clearly distinguishes static findings from interactive certifications;
   the overall outcome does NOT include a `status=success` marker for blocked flows.

---

### User Story 5 — On-demand preview only when explicitly triggered (P2)

When a relevant PR is sent to flowchad-runner and no staging URL is configured, the skill
provisions a single Vercel preview deployment for that PR on-demand and tests it. Dependabot,
docs-only, and unrelated PRs do NOT trigger preview deployment.

**Acceptance**:
1. **Given** a PR is dispatched to flowchad-runner with `trigger=pr`,
   **When** no preview URL exists yet and the PR touches application code (not only docs/deps),
   **Then** stage 01 triggers an on-demand Vercel preview deploy for that PR (via Vercel API
   or via a dispatch to the deployment-checker skill), waits for it to succeed, and sets
   `TARGET_URL` to the preview URL.
2. **Given** a PR labeled `dependencies` or with only `docs/` file changes,
   **When** dispatched to flowchad-runner with `trigger=pr`,
   **Then** stage 01 detects the exemption (label or file-diff check), writes a note in the
   handoff, and proceeds with whatever URL is already available (no new deploy triggered).
3. **Given** a Vercel project with `auto_preview: false` in `.flowchad/config.yml`,
   **When** any PR trigger arrives,
   **Then** flowchad-runner never enables provider auto-preview and only provisions the
   explicit on-demand deploy if the PR passes the relevance check above.

---

### User Story 6 — Cron mode for weekly production smoke (P2)

flowchad-runner must support a `cron` trigger that runs the critical flow set against
production, creates deduplicated failure issues with browser evidence, and is documented
as the interface for scheduling.

**Acceptance**:
1. **Given** `trigger=cron` is passed,
   **When** stage 01 resolves the production URL from config,
   **Then** only the `smoke.flows` list marked `critical: true` (or lacking an `optional: true`
   flag) is walked; P2/optional flows are excluded.
2. **Given** one or more critical flows fail,
   **When** stage 05 creates failure issues,
   **Then** it deduplicates by checking for open issues with the same title before creating;
   it does not create a duplicate issue if one already exists for that flow on that date.
3. **Given** `cron` mode with Navvi available,
   **When** a CAPTCHA-gated flow is in the critical set,
   **Then** it is walked with Navvi and the browser evidence (GIF + screenshots) is attached
   to the failure issue.
4. The `cron` argument, behavior, and scheduling contract are documented in the skill's
   `SKILL.md` under a **Cron mode** section.

---

### Edge Cases

- What happens when `config.yml` exists but has no `environments.production.url`? → stage 01 blocks with `block_reason: no production URL for cron trigger`.
- What if Navvi starts but fails to connect mid-flow? → step is marked `error`, CAPTCHA step is marked `fail`, flow fails; evidence is collected up to the point of failure.
- What if a preview deploy times out (>deploy_timeout)? → stage 01 blocks, GitHub issue created, chain stops.
- What if the same flow fails on multiple consecutive cron runs? → stage 05 deduplicates by checking open issues; does not flood with identical issues.
- What if a language-switch flow is run without Navvi? → headless Playwright is used (no CAPTCHA); assert steps still evaluate visible copy.

---

## Requirements

### Functional

- **FR-001**: Stage 01 MUST validate `config.yml` identity fields; reject `name: booster-pack` or `url: http://localhost` (or any `localhost` URL) for `cron` and `merge` triggers.
- **FR-002**: Stage 01 MUST validate that a production URL exists before accepting a `cron` trigger.
- **FR-003**: Stage 03 MUST treat a non-optional CAPTCHA step failure as a flow-level `fail`, not a skip.
- **FR-004**: Stage 03 MUST block a flow with `block_reason: CAPTCHA step requires Navvi; Navvi unavailable` when `captcha: true` is on any non-optional step, `navvi_available=false`, and `trigger` is `cron` or `merge`.
- **FR-005**: Stage 03 MUST block all interactive flows (not skip, not pass) when neither Playwright nor Navvi is available.
- **FR-006**: Stage 05 MUST emit `status=blocked` (not `status=success`) when any flow is blocked due to missing browser capability.
- **FR-007**: `language-switch.yml` MUST be updated to assert representative visible copy (header nav titles, main hero copy) in both locale directions, not only URL and `<html lang>`.
- **FR-008**: `contact-form.yml` MUST NOT mark any CAPTCHA step as `optional`; the CAPTCHA widget render and interaction are required assertions in production-targeted runs.
- **FR-009**: Stage 01 MUST support on-demand preview provisioning for `trigger=pr` when no preview URL is present and the PR is relevant (not deps-only/docs-only).
- **FR-010**: Stage 01 MUST skip preview provisioning for PRs with `dependencies` label or with only docs/infra file changes.
- **FR-011**: `cron` trigger MUST run only the critical flow set and MUST deduplicate failure issues.
- **FR-012**: `SKILL.md` MUST document `cron` mode: what it walks, what it creates, how it deduplicates, and the scheduling contract.

### Key Entities

- **config.yml**: Per-repo FlowChad configuration. Extended with `smoke.critical` flag per flow and `auto_preview: false` global guard.
- **flow YAML**: Per-flow step definitions. Updated to require CAPTCHA assertions and locale-copy assertions.
- **handoff.md** (stage 01): Extended with `config_validated: true/false`, `stale_identity: true/false`, `on_demand_deploy: triggered/skipped/n/a`.
- **handoff.md** (stage 03): Extended with per-flow `blocked_reason` for browser/CAPTCHA missing.

### Config schema additions

```yaml
# .flowchad/config.yml additions
name: <required — not "booster-pack">
url: <required for cron/merge triggers — not localhost>

smoke:
  flows:
    - name: contact-form
      critical: true     # new field — included in cron/smoke run
    - name: language-switch
      critical: true
    - name: page-load
      critical: true

auto_preview: false    # new field — disables provider auto-preview globally
```

---

## Success Criteria

- **SC-001**: A cron or merge run against a `booster-pack`/`localhost` config is blocked immediately at stage 01 with a clear reason — no flows are walked.
- **SC-002**: A contact-form flow against a site with missing `NEXT_PUBLIC_TURNSTILE_SITE_KEY` produces `fail` (not `pass` or `warn`) — the CAPTCHA widget assertion is non-optional.
- **SC-003**: A `language-switch` flow that encounters Spanish navigation under `/en/` produces `fail` — the visible-copy assertions catch the regression from quantic-v2#45.
- **SC-004**: A run with no browser available produces `status=blocked`, not `status=success`, and a GitHub issue is created explaining the missing capability.
- **SC-005**: A PR from Dependabot does not trigger a Vercel preview deployment when dispatched to flowchad-runner.
- **SC-006**: A `cron` run on a site with a failing critical flow creates exactly one GitHub issue for that flow (deduplication).
- **SC-007**: The skill is dogfooded against quantic-v2 and at least two other sites with evidence attached.

---

## Assumptions

- Navvi availability check (stage 01 `navvi_status` call) is sufficient to determine if CAPTCHA-gated flows can run; no pre-flight browser launch is needed.
- The Vercel on-demand preview provisioning in US-2 (FR-009/FR-010) may be implemented as a call to the `deployment-checker` skill or via direct Vercel API; the interface is the resolved `TARGET_URL` in the stage 01 handoff.
- "Docs-only" PR detection uses the GitHub Files API to check that all changed paths match `docs/**` or `*.md` patterns, plus the `dependencies` label check.
- Config validation (FR-001) only applies to `cron` and `merge` triggers; `manual` and `pr` triggers allow localhost URLs for local development convenience.
- i18n copy assertions in `language-switch.yml` reference quantic-v2's specific nav keys; generalizing to arbitrary sites is out of scope for this issue.
- Weekly cron scheduling is handled by Pylot separately; this skill only needs to expose a reliable `cron` mode, not the scheduling mechanism.
