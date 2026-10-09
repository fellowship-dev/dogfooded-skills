# Quickstart: Verify the Dispatch Section Fix

## Manual verification (happy path)

1. Open `skills/ops/pylot-cli/SKILL.md`, jump to `## Dispatch a Mission`.
2. Confirm the section reads as: the existing `pylot dispatch` example and cross-org guidance,
   unchanged, plus exactly 4 one-line dispatch-contract rules:
   - `/skill` prefix requirement
   - `team.role` validation
   - prompt size: ~2560 bytes (not "4 KB")
   - no-secrets
3. Confirm `git diff` touches only `skills/ops/pylot-cli/SKILL.md`, only within the Dispatch
   section (plus the single-line edit if headings shift).
4. Confirm the existing no-secrets sentence under `## GitHub Auth Through the CLI` is byte-for-byte
   unchanged (`grep -n "Secrets: never in prompts or payloads" skills/ops/pylot-cli/SKILL.md`).
5. Run `npx markdownlint-cli2 skills/ops/pylot-cli/SKILL.md` — warnings only, not a blocking gate.

## Must-fail-before (regression check)

Revert the edit (`git checkout main -- skills/ops/pylot-cli/SKILL.md`) and re-run step 2 — the
section must show the old "4 KB" prose and only 3 scattered rules, confirming the fix is what
changed the observed state.
