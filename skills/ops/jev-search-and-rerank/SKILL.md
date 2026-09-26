---
name: jev-search-and-rerank
description: Use when operating or building saved-item recall or public conversation discovery with bounded semantic screening, reranking and conversational feedback.
---

# jev-search-and-rerank

Retrieve evidence for a particular query or campaign, preserve its provenance, and improve screening and ranking from attributable conversational feedback.

Experimental: fixture-tested integration pattern; production quality must be measured by the installing application. This is separate from durable classification of stored items.

## Prerequisites

Read the application's search adapter instructions and its actual CLI help. Establish the source/account, retained-corpus coverage, private receipt store, semantic-inference budget, and supported feedback command. The host provides commands and persistence; this reusable procedure does not ship a search engine or assume a particular source system.

If the host lacks durable invocation logging, do not claim a learning loop. Return the limitation and implement that capability before enabling feedback-based adaptation.

## Workflow

1. Translate the request into an explicit query, source/account scope and any time filter. A document's creation date is not its saved/liked/bookmarked date. Keep unknown interaction dates outside date-qualified results.
2. Invoke the host search command, carrying the current conversation/session, turn/tool call and transcript reference when available. Log every invocation, including empty results, errors and cache replays, with a fresh search ID and full returned response before presenting results. Retain query, candidate revisions, order/scores, source links, coverage, policy/rubric/model versions, cost and failure status. Redact recognizable credentials and keep private evidence out of source control.
3. Discover candidates locally, then rerank only the bounded set if the configured budget permits. Semantic judgments are query-specific, cached by query, filters, candidate revision and rubric/provider identity; numerical policy changes can reuse judgments. Preserve uncertainty/probabilities. No approved inference or provider failure means an explicitly identified local ranking fallback.
4. Answer with source links and the material coverage limitation. Preserve the search ID in conversation context for later feedback. Do not claim a missing result is absent from the source when collection was partial.
5. When the user naturally corrects or evaluates the results, submit structured feedback using the host command. Reference the original search, exact human words and source turn, and affected revisions/URLs. Capture relevance, missing items, pairwise preferences, list failure or an explicit undo as supported. Keep interpretation separate from the quotation. A user's unambiguous verdict can be recorded without another confirmation; an agent's opinion, silence, later topic change or tool click is not human approval.
6. Let the configured weekly worker recover missed feedback from the referenced followup conversation and review all structured feedback. Do not create another schedule per invocation. Recovery preserves model provenance and uncertainty, verifies human source spans, distinguishes inaccessible/partial transcripts from no feedback, and never turns its own predictions into human evaluation gold.
7. In that same review, test a bounded set of ranking-policy changes against frozen feedback and features. Separate development from untouched acceptance by session and intent lineage; related queries/paraphrases must stay together. Use independent explicit human judgments for acceptance, not the reranker's own labels. Consume held-out evidence only once. Promote a version only after improvement and regression gates pass; retain an immutable receipt and rollback target. Insufficient evidence is a successful no-change outcome.

## Public conversation discovery

When the request is to find places where a particular reply or announcement fits,
read [discovery and real-data evaluation](references/discovery-evaluation.md).
Use an explicit public-discovery mode; public posts are not saved interactions.
The host must provide durable discovery receipts and bounded collection. Let the
configured semantic screener judge every acquired unique candidate, recording
unprocessed candidates when limits intervene. Fetch deeper context only for the
promising set, then judge the specific reply opportunity. Preserve the same budget,
privacy, feedback provenance and one-weekly-review boundaries.

## Feedback decisions

| Evidence | Treatment |
|---|---|
| Explicit, attributable human correction | Apply in its query/account/filter scope; latest correction can supersede an earlier verdict |
| Missing URL absent at search time | Collection gap; do not teach the ranker to retrieve unavailable evidence |
| Model-recovered likely feedback | Preserve inference provenance; only verified unambiguous source-backed feedback may affect its narrow scope |
| Ambiguous target, conflicting judgments, or unclear attribution | Keep unresolved; do not fabricate certainty or a negative label |
| Positive judgment on one result | Does not imply other results are irrelevant |
| Silence, continued conversation, or agent-generated opinion | No human label |

## Error handling

- **Receipt persistence failed:** fail closed; avoid returning an unlogged successful search.
- **Coverage or transcript incomplete:** report the actual gap and retain retryable work. A scan cap is backlog, not absence of feedback.
- **Budget, provider or privacy hold:** preserve local search and existing judgments; do not switch providers or spend outside the configured allowance.
- **No independent evaluation data or no improvement:** retain the current policy. More use supplies opportunities to learn, not a guarantee every query improves.

See [evaluation cases](evals/cases.md) for behavioral checks and the correction that motivated each boundary.
