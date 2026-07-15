# Tasks: Harden Flowchad Production and On-Demand Preview Verification

**Input**: `/specs/94-harden-flowchad-production/` — plan.md + spec.md

---

## Phase 1: Stage 01 — Config Validation and Preview Provisioning

Adds the two new gate checks in `stages/01-preflight/CONTEXT.md` and updates the handoff
schema. These are foundational — US1 (config validation), US5 (on-demand preview), and US6
(cron flow selection) all depend on this stage's handoff shape.

**Independent test**: Run flowchad-runner with a `config.yml` that has `name: booster-pack`
and `trigger=cron` — stage 01 must block immediately; no flows are walked.

- [ ] T001 [US1] Add Step 1b "Config Identity Validation" to
  `skills/ops/flowchad-runner/stages/01-preflight/CONTEXT.md`:
  validate `name ≠ booster-pack` and `url` not localhost for `cron`/`merge` triggers;
  write `blocked: true`, `block_reason: stale template identity in config.yml` and exit.

- [ ] T002 [US1] Add FR-002 check to the same Step 1b block:
  when `trigger=cron`, confirm `environments.production.url` is non-empty;
  if absent, write `blocked: true`, `block_reason: no production URL for cron trigger`.

- [ ] T003 [US1] Update the stage 01 handoff schema section in `01-preflight/CONTEXT.md`
  to add `config_validated: true/false` and `stale_identity: true/false` fields.

- [ ] T004 [P] [US5] Add "PR Relevance Check + On-Demand Deploy" block to
  `stages/01-preflight/CONTEXT.md` (Step 2b, after existing URL resolution):
  check PR labels for `dependencies` and PR files for docs-only pattern;
  if exempt, set `on_demand_deploy: skipped` in handoff;
  if relevant and no preview URL exists, trigger on-demand Vercel deploy and wait
  for success, then set `TARGET_URL` and `on_demand_deploy: triggered`.

- [ ] T005 [P] [US5] Update stage 01 handoff schema to add
  `on_demand_deploy: triggered/skipped/n/a` field.

**Checkpoint**: Stage 01 blocks stale configs and provisions previews selectively.

---

## Phase 2: Stage 03 — CAPTCHA Enforcement and No-Browser Blocking

Updates `stages/03-walk-flows/CONTEXT.md`. Depends on the updated stage 01 handoff
(T003, T005) for `navvi_available` and `trigger` values.

**Independent test**: Run a flow with `captcha: true` and `navvi_available=false` on
`trigger=cron` — the flow must record `blocked`, not `pass`.

- [ ] T006 [US2] Add "Browser Availability Pre-check" section at top of the per-flow loop
  in `stages/03-walk-flows/CONTEXT.md`:
  check `playwright-core` availability and `navvi_available`;
  if both unavailable, mark ALL flows `blocked` with
  `blocked_reason: no browser available (Playwright missing, Navvi unavailable)`,
  write handoff, exit stage 03.

- [ ] T007 [US2] Add "CAPTCHA Pre-check" per-flow (before walking steps) in
  `stages/03-walk-flows/CONTEXT.md`:
  if any non-optional step has `captcha: true` AND `navvi_available=false`
  AND `trigger` is `cron` or `merge` → set flow status `blocked`,
  `blocked_reason: CAPTCHA step requires Navvi; Navvi unavailable`; skip walking.

- [ ] T008 [US2] Update step-level CAPTCHA failure handling in
  `stages/03-walk-flows/CONTEXT.md` step 2b:
  when CAPTCHA widget fails to render (step has `captcha: true`, no `optional: true`)
  → record step status `fail` (not `skip`); propagate to flow-level `fail`.

- [ ] T009 [US4] Update the stage 03 handoff schema section to add per-flow
  `blocked_reason` field and include `blocked` as a valid flow `Status` value.

**Checkpoint**: Flows are blocked/failed correctly for CAPTCHA and missing browser.

---

## Phase 3: Stage 05 — Blocked Outcome and Issue Deduplication

Updates `stages/05-report/CONTEXT.md`. Depends on stage 03 handoff `blocked` status (T006–T009).

**Independent test**: Feed stage 05 a stage 03 handoff where all flows are `blocked` —
outcome must be `status=blocked`, a GitHub issue created, no `status=success` emitted.

- [ ] T010 [US4] Add blocked-outcome aggregation to step 1 of
  `stages/05-report/CONTEXT.md`:
  if any flow has `status=blocked` → overall status is `BLOCKED`;
  `status=success` MUST NOT be emitted when any flow is blocked.

- [ ] T011 [US4] Add "Blocked capability issue creation" to step 3 of
  `stages/05-report/CONTEXT.md`:
  when overall status is `BLOCKED`, create a GitHub issue
  "FlowChad blocked: {blocked_reason} — {REPO}" labeled `ready-to-work`
  with the missing-capability explanation.

- [ ] T012 [US4] Update the outcome marker logic in step 5 of
  `stages/05-report/CONTEXT.md`:
  add `[pylot] outcome="flowchad {flow} on {repo}: blocked — {reason}" status=blocked`
  as a third outcome path alongside success and failure.

- [ ] T013 [P] [US6] Add issue deduplication to step 3 of
  `stages/05-report/CONTEXT.md`:
  before `gh issue create` for any failing flow, query
  `gh issue list --state open --search "FlowChad failure: ${FLOW_NAME}"`;
  skip creation if an open issue already exists and log the dedup.

**Checkpoint**: Blocked runs produce a `status=blocked` marker and a single GitHub issue;
repeated cron failures do not duplicate issues.

---

## Phase 4: SKILL.md and CONTEXT.md Documentation

Updates the top-level skill docs. Depends on finalized behavior from phases 1–3.

**Independent test**: Read SKILL.md — confirm a "Cron Mode" section exists and describes
trigger value, critical flow selection, deduplication, and scheduling contract.

- [ ] T014 [US6] Add `## Cron Mode` section to
  `skills/ops/flowchad-runner/SKILL.md`:
  document `trigger=cron`, critical flow selection (`smoke.flows[].critical: true`),
  production URL requirement, deduplication contract, and that Pylot handles scheduling.

- [ ] T015 [P] [US6] Update `skills/ops/flowchad-runner/CONTEXT.md` key invariants
  to note: stage 01 validates config identity for cron/merge; stage 03 pre-checks
  browser availability and CAPTCHA capability before walking.

**Checkpoint**: SKILL.md is self-contained documentation for cron mode.

---

## Phase 5: quantic-v2 Reference Flow Updates (Dogfood)

Updates flow YAMLs in `fellowship-dev/quantic-v2` (separate commits, not in this skill repo).
These are the regression fixtures from quantic-v2#44 and quantic-v2#45.

**Independent test**: Re-run flowchad-runner against quantic-v2 production after these changes —
`contact-form` and `language-switch` flows must produce `fail` for the known regressions
(pre-fix) and `pass` after the upstream bugs are resolved.

- [ ] T016 [US3] Update `.flowchad/flows/language-switch.yml` in `fellowship-dev/quantic-v2`:
  strengthen the `nav` assert (FR-007): require English nav titles visible,
  reject Spanish titles under `/en/`;
  add `main` hero-copy assert for both `/en/` and `/es/` directions.

- [ ] T017 [US2] Update `.flowchad/flows/contact-form.yml` in `fellowship-dev/quantic-v2`:
  remove "Optional:" qualifier from Turnstile CAPTCHA expect (FR-008);
  add `captcha: true` to the scroll/CAPTCHA step so stage 03 routes it through Navvi;
  make CAPTCHA widget render a hard assertion (widget not visible = FAIL).

- [ ] T018 [P] Update `.flowchad/config.yml` in `fellowship-dev/quantic-v2`:
  add `name: quantic-v2` (replacing `booster-pack`), set `url:` to production URL,
  add `auto_preview: false`, add `smoke.flows[].critical: true` for contact-form,
  language-switch, and page-load.

**Checkpoint**: quantic-v2 config and flows pass the FR-001 validation gate and carry
the regression assertions from #44 and #45.

---

## Dependencies

- T001 → T002 → T003 (sequential: same section, config validation block)
- T004 → T005 (T004 writes the block, T005 updates the schema)
- T003, T005 → T006–T009 (stage 03 reads stage 01 handoff fields)
- T006–T009 → T010–T013 (stage 05 reads stage 03 handoff `blocked` status)
- T010–T013 → T014, T015 (SKILL.md docs reference finalized behavior)
- T016, T017, T018 are independent of each other (`[P]` within phase 5)
- T018 must satisfy FR-001 validation from T001 — do T001 first

## Notes

- All changes are to Markdown/YAML files — no compilation, no test runner required.
- Commit after each phase boundary.
- Phase 5 targets a different repo (`fellowship-dev/quantic-v2`) — commit and PR separately.
- `[P]` tasks within a phase touch different files and can be done in any order.
