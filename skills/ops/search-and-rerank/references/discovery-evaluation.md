# Public discovery and real-data evaluation

## Discovery

Establish the campaign: topic/entity, audience, intended reply or announcement,
source asset, freshness window and explicit exclusions. Check the host CLI help
for supported collection, screening, enrichment and dataset commands. A skill is
not evidence that those capabilities are installed or authorized.

Keep collection broad enough to measure misses. Deterministic deduplication,
source validation and operational limits precede screening; do not silently
replace semantic screening with a caller-selected shortlist. Run multiple typed
questions per item in the same request. Bound concurrency with the host's atomic
request/spend limits; parallel calls are not permission to exceed a budget.

Use a cheap first pass for entity relevance, genuine need and potential asset fit.
Read parents and available replies for promising candidates, then judge context:
already answered, hostile to repetitive promotion, serious need requiring a real
answer, duplicates and whether this specific asset would help. Return source-linked
excerpts and reasons without presenting model probabilities as measured precision.
Use stage-specific cache keys containing the complete campaign hash (including
asset, audience and intended reply), source/account/mode, rubric/provider identity,
and every evidence revision actually judged. Enrichment keys include parent/reply
revisions and context coverage. A changed asset or newly acquired context must
invalidate the affected judgment even if the query and target post are unchanged.

Missing replies are incomplete coverage, not proof nobody answered. Never pad a
requested result count with weak matches. Discovery does not authorize posting.

## Reusable datasets

Keep real captures in the host's private evidence store. A portable skill may
include schemas, collection recipes, small synthetic fixtures and evaluation
commands; do not bundle account-linked captures, private saved-item history,
credentials or conversation feedback into a public skill. Reference a private
corpus through a manifest rather than copying its content into instructions.

A dataset manifest needs:
- version, corpus hash, actual unique item count and source revision identities;
- source query/window, capture timestamp, collection bounds, remaining coverage;
- pipeline/rubric/model versions and label origin (human, model or unjudged);
- conversation/campaign lineage and development versus untouched acceptance split;
- source-linked human label references where available, without implicit negatives.

Hash raw evidence and normalized inputs separately. Preserve full source links
and any generated descriptions as derivatives, not source facts. Freeze splits
before tuning; once examined for development, an example is no longer untouched
acceptance. A corpus of model judgments is useful for throughput tests but does
not establish relevance accuracy. Unjudged is never a negative label.

## Benchmark honestly

Run increasing real corpus sizes (for example 100, 500, 4,000), reporting actual
unique counts. Never repeat a small corpus and call it thousands of real posts.
Separate acquisition, screening, thread enrichment, final ranking, persistence
and end-to-end wall time. Report cold versus cache-hit runs, worker count,
requests, failures, rate limits, cost/reservations and the quality-label denominator.
A cached scoring replay is not fresh source discovery. A throughput target that
fails is a valid measured result, not grounds to change the dataset or omit errors.

Capture normal conversational verdicts against the actual displayed response.
Use the host's existing weekly review for recovery/evaluation; no additional
schedule per campaign. If the discovery adapter is not yet consumed by that
review, state the gap rather than claiming an automatic learning loop.
