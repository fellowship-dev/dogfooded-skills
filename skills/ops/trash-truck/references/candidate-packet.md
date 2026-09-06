# Candidate and Evidence Packet

Use this protocol for every named target and every nominated candidate. It is the normative owner for evidence envelopes, eligibility, scoring, fingerprints, and retirement manifests. Resolve an ambiguous named target with the owner before assigning its fingerprint.

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

A static no-reference result is a lead, not corroboration by itself. Positive verified use makes the affected scope ineligible for retirement; it may support a narrower `prune/simplify` manifest that preserves the used slice. Conflicting evidence lowers confidence or yields `insufficient evidence`.

Distinguish passive availability from use. Installation, catalog presence, baseline loading, or assignment proves reachability and potential consumers, not invocation. Count use only when an entrypoint, request, event, job, delivery, or owner-confirmed workflow exercised the surface in the relevant environment.

For a composite target, positive use of any component blocks retirement of the whole declared slice. An already-absent sibling is a no-change observation, not a `prune/simplify` candidate. Propose a narrower manifest only when the remaining unused component still exists, has independent material payoff, and receives its own stable fingerprint.

## Score

Score corroborated leads, then keep only those that clear both the confidence and score thresholds as eligible candidates.

- `confidence`: 0.00-1.00, calculated from the rubric below.
- `payoff`: integer 0-4 for meaningful reduction in cognitive load, operating cost, incident surface, maintenance burden, or product complexity.
- `effort`: integer 0-4 for the work required to retire and verify the complete slice.
- `risk`: integer 0-4 for irreversible impact, hidden consumers, rollback difficulty, and production sensitivity.
- Materiality floor: `payoff >= 2`.
- Ranking score: `confidence * payoff - 0.25 * effort - 0.5 * risk`.
- Proposal threshold: `confidence >= 0.70` and ranking score greater than `0`.

Sort by score descending, then confidence descending, payoff descending, and fingerprint ascending. Persist every component and a short rationale so identical inputs produce identical rankings.

Confidence cannot exceed 0.65 without a relevant real-world evidence class. A failed source that would materially decide eligibility caps confidence at 0.50. An inadequate recurrence window caps confidence below 0.70. Repository policy or candidate risk may require a stricter threshold but never a weaker one.

Risk and reversibility remain visible beside the score. A high score never bypasses an owner gate.

### Component Rubrics

Calculate confidence by adding each satisfied independent check once:

| Check | Weight | Satisfied when |
|---|---:|---|
| Boundary | 0.10 | Conceptual surface and direct operational dependencies are identified |
| Code/dependency | 0.15 | Static consumers, dynamic lookup, configuration, and generated entry points were checked |
| History/ownership | 0.20 | Issues, PRs, commits, successors, owners, and obligations were checked |
| Real-world use | 0.35 | A relevant deployed runtime, analytics, log, schedule, delivery, or owner-confirmed workflow was checked |
| Consumer disconfirmation | 0.10 | Known and plausible consumers were actively sought with no unresolved positive use in the proposed scope |
| Recurrence/freshness | 0.10 | Environment, revision, freshness, and observation window cover the expected use cycle |

Unavailable or failed checks add zero. Subtract 0.25 for each unresolved contradiction, then clamp to 0.00-1.00 and apply the caps above. Do not award both real-world use and consumer-disconfirmation points from the same observation unless it independently establishes both facts.

If an on-demand surface has no documented cadence, recurrence is satisfied only when the window covers all available retention and an owner or known-consumer check corroborates it. Otherwise recurrence adds zero and the gap remains visible.

Use these anchors for the integer components; choose the highest anchor whose description is fully supported:

| Value | Payoff | Effort | Risk |
|---:|---|---|---|
| 0 | No meaningful reduction | Already absent or no implementation work | No live or retained surface |
| 1 | Local cognitive or maintenance reduction | Small reversible repository-only slice | Internal and immediately reversible |
| 2 | Meaningful reduction in one maintained domain | Multiple files, tests, docs, or configuration in one repository | Production-facing with a proven rollback |
| 3 | Ongoing cross-domain operating or product reduction | Cross-service or provider coordination | External dependency, hidden-consumer uncertainty, or limited rollback |
| 4 | Removes a major product, infrastructure, incident, or sustained cost center | Migration, data, infrastructure, and rollout work | Irreversible, regulated, destructive-data, or broad production impact |

When evidence falls between anchors, use the more conservative payoff and the higher effort or risk.

### Deterministic Validator

Normalize each corroborated lead as JSON with `fingerprint`, `checks`, `payoff`, `effort`, `risk`, and `corroborated`. Add `positive_use`, `failed_decisive_source`, and `unresolved_contradictions` when applicable. Run `scripts/rank_candidates.py`; it validates inputs, derives confidence and score from this protocol, filters ineligible leads, applies deterministic tie-breaking, and returns at most three candidates. The curator remains responsible for truthful evidence normalization.

## Fingerprint

Build the fingerprint from normalized `OWNER/REPO` plus the stable conceptual surface, for example `acme/app:legacy-export`. Exclude repository SHA, timestamps, evidence text, score, and current file paths so refreshed evidence updates the same candidate.

Material evidence changes update the packet and may move its lifecycle state. Cosmetic rewording does not mint a new fingerprint.

## Candidate or Assessment Packet

For an eligible `retire` or `prune/simplify` candidate, present and persist:

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

For `keep` or `insufficient evidence`, omit the score and executable retirement manifest. Present and persist the fingerprint, verdict, decisive evidence for and against retirement, known owners and consumers, source coverage, unresolved gaps, revisions, and evidence freshness. These verdicts never offer a go/no-go execution choice.

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
