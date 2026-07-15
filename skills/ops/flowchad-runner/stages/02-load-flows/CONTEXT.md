# Stage 02: Load & Validate Flow Config (subagent)

## Inputs
- `.procedure-output/flowchad-runner/01-preflight/handoff.md`
  (read `flow_name`, `repo`, `pr_number`, `flows_to_run`)

## Task
Read the FlowChad config, confirm every flow in `flows_to_run` has a definition file, and
load each flow's YAML so the walk stage has validated input. Missing flows and invalid
production-critical contracts are blocking.

## Steps

### 1. Read config and list available flows
```bash
# Read FlowChad config
cat .flowchad/config.yml

# List available flows
ls .flowchad/flows/
```

### 2. For each flow in flows_to_run, load its definition
```bash
# Load the specific flow (run once per flow in flows_to_run)
cat .flowchad/flows/${FLOW}.yml
```

### 3. Handle a missing flow file

If a flow file does not exist:
1. Post a comment to the PR (if `pr_number` set):
   "flowchad-runner: flow `${FLOW}` not found in .flowchad/flows/"
2. Create a GitHub issue with label `ready-to-work`: "Missing FlowChad flow: ${FLOW}"
3. Mark the flow as `missing` in the handoff. If ALL requested flows are missing, set
   `blocked: true` so the orchestrator stops; otherwise drop the missing flow from the
   validated list and continue with the rest.

### 4. Record per-flow walk hints

For each loaded flow YAML, scan it so the walk stage can pick the browser without re-reading:
- `headed: true` on the flow → prefers Navvi
- any step with `captcha: true` → prefers Navvi
- otherwise → headless Playwright (fast path)

Also record:

- `interactive`: true when the flow declares it or uses click/fill/submit/select/upload/CAPTCHA
- `browser_evidence`: value of `evidence.browser`
- `captcha_contract`: renders, token, submission, success-ui, backend-boundary
- `i18n_regions`: header, main, form, footer when `contract.kind: i18n`

For preview, production, and cron, block an interactive flow unless `evidence.browser: required`.
For production and cron, block optional CAPTCHA steps or an incomplete CAPTCHA contract. Block
i18n flows that assert only URL/`<html lang>` or omit any representative visible-copy region.

### 5. Write handoff.

## Output: handoff.md

Path: `.procedure-output/flowchad-runner/02-load-flows/handoff.md`

```markdown
# Stage 02: Load Flows

## Status
blocked: {true|false}
block_reason: {reason or "none"}

## Config
config_path: .flowchad/config.yml
evidence_backend: {value of .evidence.backend // "git"}

## Validated flows
| Flow | File | Status | Interactive | Prefers | Browser evidence | Notes |
|------|------|--------|-------------|---------|------------------|-------|
| {name} | .flowchad/flows/{name}.yml | ok / missing / invalid | true/false | navvi / playwright | required / missing | captcha/i18n contract |

## Walk order
{ordered list of flow names to walk, missing flows excluded}
```

## Success criteria
- Config read; every requested flow resolved to `ok`, `missing`, or `invalid`.
- At least one `ok` flow in the walk order, OR `blocked: true` if all are missing.

## Failure
- All requested flows missing → comment + issues created, `blocked: true`, exit.
- `.flowchad/config.yml` unreadable → `blocked: true`, `block_reason: no flowchad config`.
- Any requested interactive flow has an invalid environment/evidence/CAPTCHA/i18n contract →
  `blocked: true`; do not walk it under weaker legacy semantics.
