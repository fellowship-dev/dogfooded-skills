---
name: label-and-act
description: Use when building or extending recurring stored-evidence classification and action selection. Keep query-specific search and reranking in a separate pattern.
user-invocable: false
allowed-tools: Read, Bash, Glob, Grep
---

# Label and act

Build a reusable collection → stored judgment → local action workflow from an existing working consumer.

This extracted procedure is experimental; inherited production code is evidence
for that code, not proof that this new skill has been independently dogfooded.

## Prerequisites

Inspect the owning repository's instructions, source adapter, action permissions,
and existing storage/provider helpers. Locate them with `rg --files` and targeted
`rg` queries. Use the installed provider skill (such as `typesafe-ai`) or its
current official documentation for API mechanics; do not copy a provider client.

```bash
git status --short
rg --files -g AGENTS.md -g SKILL.md -g '*label*' -g '*grounding*' -g '*budget*'
rg -n 'rubric_version|evidence_probability|choice_confidence|retry_call|run_records' scripts tests
```

These discovery commands assume a repository with `scripts/` and `tests/`; use
its actual runtime and test directories if different. Read the matching helpers
and their call sites before choosing the extraction boundary.

## Workflow

1. **Inspect the working consumer first.** Read its stored records, cache keys,
   provider call, run loop and tests. Extract the smallest existing common core;
   preserve its public signatures, append-only records, replay behavior and error
   semantics. Add a second adapter before inventing a new architecture. Existing
   gaps need explicit migrations/tests, not a competing label store or client.
2. **Define the useful action.** Identify the current LLM turn to avoid, required
   evidence, source/account boundary, priority dimensions, action limit, and the
   consequence of a missed item. Keep domain priorities in the adapter.
3. **Collect and retain.** Preserve every fetched candidate, including rejected
   ones, before inference. Save stable source ID, navigable source URL, exact
   evidence/hash, content revision, source time, capture time, and run coverage.
   Store metrics and mutable state as observations. Record failures, pagination
   limits, and partial runs explicitly; an incomplete fetch is not an empty inbox.
4. **Label semantic revisions.** Keep machine judgments separate from facts and
   human corrections. Version rubric, adapter, provider/model and model epoch;
   cache the exact semantic input. Replays reuse judgments; metrics-only changes
   and priority-weight changes do not require relabeling. Pending/error/oversize
   states cannot silently become rejects. Bound requests and retain usage receipts.
   Separate three decisions: whether evidence is sufficient, which labels apply,
   and whether an action is warranted. Use independent Boolean judgments for
   labels that can coexist; use Choice only for mutually exclusive alternatives.
   Validate types, finite probabilities, option membership, normalized Choice
   distributions and declared winner against the argmax. Preserve the winner and
   full distribution when the split is uncertain; confidence is review metadata,
   not an automatic abstention rule. Adapters own evidence, confidence and action
   thresholds. A meaningful `none` label is not missing evidence.
5. **Benchmark before routing.** Freeze development and held-out examples with
   human-relevant decisions; use development cases to tune, held-out cases once
   for acceptance. Compare the same inputs and action budget with the old path.
   Measure useful top selections, missed actionable items, uncertainty, cache hits,
   LLM calls/tokens avoided, latency, and cost when known. Report unknowns honestly.
   Preserve failures as regression cases without tuning on the held-out set.
   Measure coverage (judged / eligible) separately from correctness; lower
   abstention alone does not demonstrate better labels. Keep comparisons on the
   same input corpus and disclose simultaneous rubric/gate changes. Start with
   a few targeted cases when that is the authorized rollout bar; choose stricter
   recall checks for workflows where a missed obligation is costly.
   Append corrections with item/revision, judgment/rubric, label, corrected value,
   reviewer identity/type and time. Human and model-judge feedback stay distinct;
   human corrections take precedence. A judge provides a review signal, not
   ground truth. Tune only from reviewed failures, then re-evaluate.
6. **Select locally.** Code combines stored labels with freshness, counts,
   explicit priority weights and thresholds. Return source links with evidence
   excerpts and named reason labels. Use an LLM only for selected work needing
   writing/investigation. Missing judgments take the workflow's explicit hold or
   escalation path; free inference does not justify unbounded evaluation.
7. **Act once.** Record intent before external I/O, then its confirmed result.
   Deduplication keys describe the action, not its rubric/model version. Unknown
   external outcomes require reconciliation. Dry runs never reserve live keys;
   simultaneous consumers cannot duplicate an action. Apply existing send gates.
8. **Prove replay and recovery.** Restart, changed content, relabeling, partial
   collection, provider failure and stale-backup restore must preserve evidence
   and action history. Cutover needs the workflow quality gate and an end-to-end
   receipt; recovery must hold sends until post-snapshot outcomes are reconciled.

## Shared implementation

Reuse the extracted run/provider/cache signatures; adapters own source evidence,
payloads, rubrics, priority composition and output. Add storage only for new domain
needs; do not duplicate the existing judgment ledger in another database. A skill classifier
and an email triager can use this same procedure with different taxonomies.
Keep runtime code in its owning repository initially; extract a shared package
when two real consumers establish its interface. Avoid an ORM, plugin registry,
generated scaffolding or duplicate provider mechanics merely to support the pattern.

## Decision checks

| Observed state | Required behavior |
|---|---|
| Evidence sufficient; Choice probabilities split | Retain validated winner and distribution; mark confidence separately; apply adapter action policy |
| Required evidence missing, or truncation prevents a supported judgment | Record explicit abstention/hold; do not fabricate a negative label |
| Metrics changed, semantic input unchanged | Reuse stored judgment; recompute local priority |
| Provider timeout or exhausted budget | Leave pending/retryable; do not mark rejected or switch providers |
| Relabel after a confirmed action | Preserve action suppression across rubric/model versions |
| Human correction conflicts with model judge | Keep both records; use the human correction for effective feedback |

## Error handling

Provider failure leaves items pending; incomplete collection retains its coverage.
Ambiguous external outcomes hold retries until reconciled. An unavailable paid
budget cannot silently select another provider. Reserve against the authorized
cap before each paid attempt, including retries; retain unknown cost as reserved
until reconciled. Free promotions do not remove budget accounting. Distinguish
account access/rate limits from request errors before changing prompts or retry
volume; credit top-ups can resolve account-level throttling but are not a general
429 fix. This procedure grants no new send,
collection, schedule or data-sharing permission.
