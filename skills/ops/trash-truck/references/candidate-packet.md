# Candidate and Evidence Packet

Use this protocol for every named target and every nominated candidate. It is the normative owner for evidence envelopes, eligibility, scoring, fingerprints, and retirement manifests.

## Evidence Envelope

Record one envelope per source:

| Field | Meaning |
|---|---|
| `surface` | Code, GitHub, git, runtime, analytics, logs, operations, infrastructure, integration, owner, or another named source |
| `status` | `observed`, `unavailable`, `failed`, or `not-applicable` |
| `query` | What was checked without embedding credentials or sensitive payloads |
| `window` | Start/end dates or another explicit coverage boundary |
| `collected_at` | Timestamp with timezone |
| `environment` | Production, staging, local, or another explicit environment |
| `identity_denominator` | Relevant user/account/event identity and denominator when interpreting usage |
| `revision` | Repository and deployed revision relevant to the observation |
| `receipt` | Secret-free link, command summary, log locator, query ID, or artifact reference |
| `finding` | Evidence for retirement, evidence against it, or an unresolved gap |
| `fresh_until` | Date or event that makes this observation stale |

`Unavailable` means the capability does not exist or cannot be reached. `Failed` means a relevant attempt errored. `Not-applicable` means the surface does not govern this candidate. None of these means zero use.

Choose windows from the surface's expected recurrence. Cover the longest known business, compliance, billing, seasonal, or exceptional-use cycle that could reasonably invoke it. If that window cannot be observed, cap confidence and record the gap.

## Eligibility

A lead becomes eligible only when all are true:

1. The conceptual surface and direct operational boundary are identifiable.
2. At least two independent evidence classes corroborate retirement, including one real-world ownership, runtime, analytics, logs, schedule, infrastructure, or integration check.
3. Counterevidence and known consumers were actively investigated.
4. No verified positive use or binding obligation remains unresolved.
5. Evidence freshness and environment are adequate for the expected recurrence.
6. The retirement payoff reaches the materiality floor.

A static no-reference result is a lead, not corroboration by itself. Positive verified use makes the candidate ineligible. Conflicting evidence lowers confidence or yields `insufficient evidence`.

## Score

Score only eligible candidates.

- `confidence`: 0.00-1.00, based on evidence coverage, independence, freshness, environment, counterevidence, and recurrence adequacy.
- `payoff`: integer 0-4 for meaningful reduction in cognitive load, operating cost, incident surface, maintenance burden, or product complexity.
- `effort`: integer 0-4 for the work required to retire and verify the complete slice.
- `risk`: integer 0-4 for irreversible impact, hidden consumers, rollback difficulty, and production sensitivity.
- Materiality floor: `payoff >= 2`.
- Ranking score: `confidence * payoff - 0.25 * effort - 0.5 * risk`.

Sort by score descending, then confidence descending, payoff descending, and fingerprint ascending. Persist every component and a short rationale so identical inputs produce identical rankings.

Confidence cannot exceed 0.65 without a relevant real-world evidence class. A failed source that would materially decide eligibility caps confidence at 0.50. An inadequate recurrence window caps confidence below the retirement threshold chosen for the run. Do not invent a universal retirement threshold when repository policy or the candidate's risk requires a stricter owner judgment.

Risk and reversibility remain visible beside the score. A high score never bypasses an owner gate.

## Fingerprint

Build the fingerprint from normalized `OWNER/REPO` plus the stable conceptual surface, for example `acme/app:legacy-export`. Exclude repository SHA, timestamps, evidence text, score, and current file paths so refreshed evidence updates the same candidate.

Material evidence changes update the packet and may move its lifecycle state. Cosmetic rewording does not mint a new fingerprint.

## Candidate Packet

Present and persist:

- fingerprint and current lifecycle state;
- verdict and deterministic score with component rationale;
- evidence for retirement and evidence against it;
- known owners, consumers, obligations, and last verified use;
- unresolved gaps and source coverage table;
- repository HEAD, deployed revision, evidence cutoff, and freshness;
- exact retirement manifest;
- excluded surfaces;
- rollback or recovery posture;
- separate owner gates;
- selection invalidators.

## Retirement Manifest

List each affected surface explicitly:

| Surface | Included change | Evidence | Reversibility | Separate gate |
|---|---|---|---|---|
| Code/modules | Delete, detach, or simplify | References and runtime identity | Revert or replacement | Repository write/review |
| Tests/docs/config | Remove or update | Consumer and contract search | Revert | Repository write/review |
| Jobs/schedules | Disable or delete | Invocation history and ownership | Restore schedule | Schedule authority |
| Integrations | Deregister or detach | Delivery/callback history | Provider-specific | External-system authority |
| Schema/data | Preserve, migrate, archive, or drop | Query and retention obligations | Often limited | Explicit destructive-data authority |
| Infrastructure | Decommission resource | Runtime and dependency inventory | Provider-specific | Infrastructure authority |

Anything not listed as included is excluded. Selection binds the owner only to the fingerprint, manifest, exclusions, and evidence cutoff displayed at selection time.

## Refresh and Invalidation

Before execution, refresh every drift-prone source that materially supports eligibility or score. Re-present instead of acting when:

- positive use or a consumer appears;
- HEAD or the deployed revision changes the target materially;
- the candidate becomes ineligible;
- a decisive source expires, fails, or resolves to another environment;
- the manifest expands or reversibility worsens;
- a new destructive or external gate appears.
