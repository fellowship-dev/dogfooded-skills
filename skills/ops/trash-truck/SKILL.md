---
name: trash-truck
description: Investigate and retire unused product, code, operational, or infrastructure surfaces using real usage evidence. Use when a repository needs active pruning, when a specific capability may no longer be necessary, or when a scheduled review should preserve retirement candidates without executing them. Do not use for routine lint cleanup, broad refactoring, or dependency updates.
---

# Trash Truck

Challenge whether a surface should continue to exist. Prefer deleting over simplifying, simplifying over optimizing, and optimizing over automating. A well-supported `keep`, `insufficient evidence`, or no-change result is complete work.

## Invocation

```text
/trash-truck OWNER/REPO mode:interactive
/trash-truck OWNER/REPO mode:interactive candidate:"<description>"
/trash-truck OWNER/REPO mode:scheduled
/trash-truck OWNER/REPO mode:scheduled persist:github
```

`OWNER/REPO` is required. `candidate:"<description>"` is optional and only valid in interactive mode. Quote the complete description; do not treat trailing free text as part of the candidate. `persist:github` is optional and only valid in scheduled mode; it must come from an owner-configured schedule or an explicit current owner request. Stop with an input error if these combinations are invalid or the mode is missing or unknown.

Resolve mode before investigating:

| Situation | Mode | Allowed outcome |
|---|---|---|
| A user is present and `mode:interactive` is explicit | Interactive discovery or named-target review | Present a recommendation; offer selection only for eligible `retire` or `prune/simplify` candidates; execute at most one approved manifest |
| A schedule or automation invokes the skill without `persist:github` | Scheduled | Investigate, report `issue_persistence: not-requested`, then STOP |
| An owner-authorized schedule invokes `mode:scheduled persist:github` | Scheduled with persistence | Investigate, conditionally persist one canonical review issue, then STOP |
| Presence of an interactive owner is unclear | Scheduled fail-safe | Report only; never mutate product or repository state |

Normalize the parsed inputs and run `python3 <skill-dir>/scripts/rank_candidates.py mode <invocation-json>` before continuing. Stop on validator error.

## Non-Negotiable Boundaries

- Scheduled mode never edits code, deletes anything, opens a retirement PR, disables a job, changes a schema or data, mutates infrastructure, merges, deploys, or syncs a live skill.
- Interactive investigation is read-only until the owner selects the exact candidate fingerprint and retirement manifest shown to them.
- Selection is not blanket deletion authority. Schema, data, infrastructure, external integrations, merge, deployment, and other owner-gated actions still require their own explicit authorization.
- A GitHub issue, prior opinion, stale approval, or candidate score is evidence, not execution authority.
- Never interpret unavailable, failed, stale, or wrong-environment telemetry as zero use.
- Never pad the result. Return zero to three candidates.

## Workflow

### 1. Preflight the Repository and Authority

1. Read the target repository's active instructions, issue-filing policy, and destructive-action rules.
2. Confirm the repository identity, current revision, default branch, dirty state, and available read-only evidence capabilities.
3. In scheduled mode, treat persistence as not requested unless `persist:github` is explicit. When it is explicit, verify the owner-configured grant, repository policy, credential scope, and repository-scoped serialization or atomic lock separately.
4. Keep secrets out of commands, worker briefs, evidence packets, and issue content.

If the repository cannot be identified or the requested scope violates its policy, stop with the blocker.
If a named candidate could refer to more than one conceptual surface, ask the owner to resolve that boundary before fingerprinting or gathering evidence.

### 2. Bound the Investigation

Start with the named repository. Follow only direct operational dependencies identified by its configuration, deployment manifests, runtime identifiers, or authoritative documentation, such as:

- deployed services and revisions;
- jobs, schedules, queues, and workers;
- databases, buckets, topics, and infrastructure directly owned by the surface;
- analytics events, logs, integrations, and external callbacks emitted or consumed by it;
- directly referenced repositories or packages.

Do not fan out into vendor-wide accounts, unrelated repositories, or transitive dependencies. If `candidate:<description>` is present, investigate that target only; record unrelated findings as out of scope without nominating them.

### 3. Gather Evidence and Try to Disprove Retirement

Read [references/candidate-packet.md](references/candidate-packet.md) before collecting evidence.

Use the evidence surfaces that actually exist. Prefer independent read-only workers for separable surfaces when the harness supports them:

| Surface | Useful evidence |
|---|---|
| Code and dependencies | References, imports, routes, feature flags, generated clients, dynamic lookup, tests, configuration |
| GitHub and git | Open and closed issues, merged and abandoned PRs, commits, blame, code owners, deprecation decisions, successor work |
| Runtime | Deployed revision, service inventory, traffic, invocation logs, errors, queue or job activity |
| Product analytics | PostHog, Mixpanel, or equivalent events and funnels with identity, denominator, environment, and adequate time window |
| Operations | CloudWatch or equivalent logs, schedules, alerts, runbooks, infrastructure state, integration delivery records |
| People and ownership | Known consumers, owner confirmation, support or compliance obligations, exceptional or seasonal use |

Each worker receives one bounded read-only question and returns evidence envelopes. Workers do not rank candidates, mutate state, or decide retirement. One curator reconciles identities, environments, contradictions, freshness, and recurrence windows.

For every lead, actively search for counterevidence. A code-only absence of references is not enough. Distinguish passive installation or loading from actual invocation. Positive verified use blocks retirement of the used scope, but may justify a narrower simplification that preserves it.

### 4. Build Candidate Packets and Rank

Use the eligibility, materiality, scoring, tie-breaking, and approval rules in [references/candidate-packet.md](references/candidate-packet.md). Normalize corroborated leads as described there, then run `python3 <skill-dir>/scripts/rank_candidates.py rank <candidate-json>` when the bundled validator is available. If it cannot run, apply the same rubric manually and disclose that the ranking was not mechanically verified.

For discovery, rank all eligible candidates and present only the top zero to three. For a named target, do not build an alternatives list; return one of:

- `retire` — evidence supports removing the complete declared slice;
- `prune/simplify` — part of the surface remains necessary;
- `keep` — verified use or obligation defeats retirement;
- `insufficient evidence` — the evidence cannot support a safe decision.

Every eligible `retire` or `prune/simplify` candidate includes its fingerprint, score components, evidence for and against retirement, unresolved gaps, known owners and consumers, last verified use, retirement manifest, exclusions, reversibility, and owner gates. A `keep` or `insufficient evidence` assessment includes the fingerprint, decisive evidence, source coverage, known owners and consumers, and gaps, but it has no retirement score or executable manifest.

### 5. Branch by Mode

#### Scheduled

Read [references/canonical-issue.md](references/canonical-issue.md). Normalize the preflight result and run `python3 <skill-dir>/scripts/rank_candidates.py persistence <persistence-json>`. Without `persist:github`, report `not-requested` and STOP. Perform the returned `create` or `update` only when the deterministic decision says so; otherwise report its `not-needed` or `blocked` result and STOP.

1. Converge on at most one canonical retirement-review issue.
2. Record only a materially changed investigation.
3. Read the stored issue or comment back and verify the marker and content.
4. Report persistence as `verified`, `not-requested`, `not-needed`, `blocked`, or `failed`.
5. STOP.

No candidate, including a high-confidence one, permits scheduled execution.

#### Interactive Discovery

If the ranking is empty, report no change and STOP without asking for selection. Otherwise present the ranked candidate packets, ask the owner to select one exact fingerprint or stop, then STOP and wait.

#### Interactive Named Target

For `retire` or `prune/simplify`, present the verdict and exact manifest, ask for go/no-go against that fingerprint and boundary, then STOP and wait. For `keep` or `insufficient evidence`, present the assessment and STOP without offering an execution choice.

### 6. Refresh Before Acting

After selection, refresh every drift-prone source that materially supported eligibility or scoring. Reuse stable evidence that is still fresh. Run `python3 <skill-dir>/scripts/rank_candidates.py approval <approval-json>` against the displayed and refreshed packets. If the validator is unavailable, errors, or returns `valid: false`, do not execute.

Invalidate the selection and re-present the candidate when any of these occurs:

- positive verified use appears;
- the target or deployed revision changed materially;
- confidence falls below eligibility;
- a source used to justify retirement becomes stale, failed, or wrong-environment;
- the retirement manifest or irreversible blast radius expands;
- a new owner gate is discovered.

The refreshed outcome may be `keep`, `insufficient evidence`, or no change.

### 7. Execute One Approved Slice

Execute at most one selected candidate. Follow the target repository's normal implementation, testing, review, and delivery workflow.

Remove the complete authorized slice across every included surface: code, tests, documentation, configuration, jobs, integrations, schemas, data, and infrastructure. Do not touch excluded or separately gated surfaces. If complete retirement is unsafe but an approved smaller simplification is valuable, prefer that over optimization or automation.

Before editing, capture a clean baseline and the characterization or usage evidence that protects behavior outside the slice. After editing, verify:

- static consumers and dynamic entry points no longer depend on the retired surface;
- targeted and full tests or builds pass;
- configuration, jobs, integrations, documentation, and alerts agree with the new state;
- migrations, data, and rollback posture are safe where applicable;
- the exact deployed revision and post-deploy evidence are checked when deployment is separately authorized.

An open or merged PR means retirement is proposed or landed in source. Mark a production surface `retired` only after deployed-revision and post-deploy evidence prove the full manifest is gone.

## Output

Always report:

- mode, repository, candidate scope, repository revision, and deployed revision when known;
- evidence coverage, failures, blind spots, and adequate recurrence windows;
- zero to three ranked candidates or the named-target verdict;
- the selected fingerprint and approved manifest, if any;
- exact mutations performed and separate gates not crossed;
- verification receipts and final candidate state;
- canonical issue URL and readback result, `not-requested` when no persistence grant was supplied, `not-needed` when no durable write was required, or why persistence was blocked.

## Critical Rules

1. Investigate necessity, not tidiness.
2. Real usage and operational obligations outrank static absence.
3. Missing telemetry is unknown, never zero.
4. Scheduled means report-only, even when an issue write is allowed.
5. Selection is bound to one fingerprint and manifest.
6. Changed evidence or blast radius voids selection.
7. One run retires at most one candidate.
8. A PR is not production retirement.
9. Fewer than three candidates and no change are healthy outcomes.
