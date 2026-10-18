# Evidence contract

Extend the consumer's existing receipt/manifest with an `seo` section at version `1`; do not create a second database, scheduler or reporting system. This is the portable field contract for adapters, not a claim that every collector emits these fields natively. Preserve native raw results unchanged and link normalized fields to them.

| Record | Required fields |
|---|---|
| Run | `version`, site ID, canonical URL/allowed origins, mode, visibility intent and policy source, lifecycle/pending disposition, selected stage, allowed operations, project binding or none, report owner, source repository/revision and installed skill path, observed time/timezone |
| Collection | Native source/tool revision, raw response path/hash, exact audit ID when applicable, start/end/deadline, requested page cap, actual inspected URLs/count, exclusions, failed/unread URLs, truncation and static/rendered boundaries |
| Finding | Site, source URL, stable rule/code, destination when relevant, observed/expected behavior, raw evidence reference, confidence, purpose/policy impact, effort/dependencies, status |
| Authored edge | Source URL, literal href, resolved URL, exact anchor/context/location, ordered redirect hops/statuses, final URL/status, observation time and raw evidence reference |
| Intervention | Stable ID, selected audience/query, URL/change, expected outcome, rationale, baseline reference/time, complete copy/diff artifact, owner/review state, publication reference and actual time or explicit unpublished state, live verification reference |
| Follow-up | Intervention ID, measurement source, query/page/market/device/search type, exact baseline/comparison windows and provider timezone, capture time, completeness/lag, observed values or unavailable reason, next comparable observation window |
| Provider use | Authorization/allowance reference, request identity and market, retained raw response, actual cost or unknown, cumulative spent/reserved amount; one-off pilots never reset on the next run |

Finding identity is the tuple `(site, source URL, rule, destination when relevant)`. Preserve authored distinctions; do not strip query strings or substitute redirect targets when that loses the original edge. Adapter-specific hashing may encode this tuple without changing its meaning.

Compare only equivalent controls and inspected scope:

| Comparison | Status |
|---|---|
| Observed now, not present in equivalent earlier coverage | `new` |
| Same finding observed again | `persistent` |
| Same control/URL rechecked and confirmed corrected | `resolved` |
| Previous finding not rechecked, blocked, truncated or outside current scope | `unverified` |

An exclusion/noindex warning on a never-index site may be expected policy compliance; preserve the raw observation and policy interpretation separately. Unknown visibility cannot authorize removing a block. Unknown cost cannot become zero; missing measurement cannot become no traffic. Preserve losses, limitations and failed/partial runs. Retain purchased raw responses in the existing archive rather than relying on a short-lived upstream cache.
