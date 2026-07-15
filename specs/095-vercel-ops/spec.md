# Feature Specification: vercel-ops Skill

**Feature Branch**: `095-vercel-ops`
**Created**: 2026-07-15
**Status**: Draft
**Input**: build a public vercel-ops skill for safe env, deployment and domain operations

## User Scenarios & Testing

### User Story 1 — Safe Env Var Write (P1)

Agent writes a Vercel env var without introducing trailing-newline corruption.

**Acceptance**:
1. **Given** a VERCEL_TOKEN and project context, **When** the agent sets an env var, **Then** `printf '%s' "$VAL" | wc -c` matches expected byte count with no trailing newline
2. **Given** a quantic-v2 Turnstile key, **When** the agent checks its length, **Then** it reports 25 bytes without printing the value

---

### User Story 2 — Wrong-Project Guard (P1)

Agent verifies project identity before any mutation.

**Acceptance**:
1. **Given** a mismatched VERCEL_PROJECT_ID, **When** the agent calls the Vercel API, **Then** it aborts with a clear error before any write

---

### User Story 3 — NEXT_PUBLIC_* Compile Verification (P2)

Agent confirms a NEXT_PUBLIC_ variable is compiled into a real deployment.

**Acceptance**:
1. **Given** a deployed URL, **When** the agent fetches the deployment bundle, **Then** it confirms the value appears in the built output

---

### Edge Cases

- What if `vercel env pull` is used? Forbidden — writes plaintext to disk
- What if `echo` is used? Forbidden — adds trailing newline

## Requirements

### Functional

- **FR-001**: Skill MUST use `printf '%s'` (never `echo`) for all env var writes
- **FR-002**: Skill MUST verify project ID/name via API before any mutation
- **FR-003**: Skill MUST use `wc -c` and `sha256sum` for fingerprint comparison without printing secrets
- **FR-004**: Skill MUST include a named regression checklist section
- **FR-005**: Skill MUST live at `skills/ops/vercel-ops/SKILL.md` with frontmatter `name: vercel-ops`
- **FR-006**: Skill MUST NOT duplicate `vercel-deploy` pipeline — link to it

## Success Criteria

- **SC-001**: Trailing-newline detection identifies quantic-v2 Turnstile key as 25 bytes without printing it
- **SC-002**: Wrong-project guard produces clear failure before any mutation on mismatched project ID
- **SC-003**: Skill invoked 5 times across 4+ projects (repository publication requirement met)
- **SC-004**: No secret values in any log, report, or git at any workload run
- **SC-005**: README catalog entry added with correct name, description, path

## Assumptions

- `VERCEL_TOKEN` available in worker secret store; project IDs come from repo playbook
- Skill does NOT create new Vercel projects — separate procedure
- All Vercel CLI calls use `--token="$VERCEL_TOKEN"` and `--yes`
- `.vercel/project.json` written directly, never via `vercel link`
