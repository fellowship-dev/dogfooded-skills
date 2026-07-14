# Research, provenance, and source policy

## Reuse decision

| Source | License | Useful patterns | Gaps for this skill | Decision |
|---|---|---|---|---|
| [coreyhaines31/marketingskills](https://github.com/coreyhaines31/marketingskills) at `130847d0945555c43b0b1774e2a4f99d35a32ebe` | MIT | Clear holistic audit order; international SEO reference; strong warning about static schema detection; cross-agent packaging | Primarily qualitative; few deterministic checks; broad marketing context coupling | Adapt audit organization and evidence boundaries with attribution; do not copy text wholesale |
| [AgriciDaniel/claude-seo](https://github.com/AgriciDaniel/claude-seo) at `6cf1ea9fe4c2088b2ad3089797f846850fd66164` | MIT | Modular technical, sitemap, hreflang, schema, rendering, reporting, and optional API patterns | Large Claude-specific suite; high context/tool surface; some time-sensitive claims in core instructions | Reuse concepts and test categories; build a smaller stdlib audit instead of importing the suite |

No upstream source was vendored. `audit.py`, the control model, report contract, and casebook are original implementation. Keep the repository license notices when adapting any future code.

Research snapshot retrieved 2026-07-14.

## Normative sources

Prefer these primary sources over third-party summaries:

- [Google: canonical URLs](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls)
- [Google: redirects](https://developers.google.com/search/docs/crawling-indexing/301-redirects)
- [Google: localized versions and hreflang](https://developers.google.com/search/docs/specialty/international/localized-versions)
- [Google: multilingual and multi-regional sites](https://developers.google.com/search/docs/specialty/international/managing-multi-regional-sites)
- [Google: robots.txt](https://developers.google.com/search/docs/crawling-indexing/robots/intro)
- [Google: build and submit sitemaps](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)
- [Google: structured data introduction](https://developers.google.com/search/docs/appearance/structured-data/intro-structured-data)
- [Google: JavaScript structured data](https://developers.google.com/search/docs/appearance/structured-data/generate-structured-data-with-javascript)
- [Google: Core Web Vitals](https://developers.google.com/search/docs/appearance/core-web-vitals)
- [Google Search Console documentation](https://support.google.com/webmasters/)
- [Schema.org vocabulary](https://schema.org/docs/schemas.html)
- [Sitemaps protocol](https://www.sitemaps.org/protocol.html)

## Source policy

- Verify time-sensitive thresholds, supported rich-result types, and tool behavior against primary documentation during each substantive update.
- Record retrieval dates in PR evidence, not in the timeless core workflow.
- Treat search-engine guidance as provider behavior, not an immutable web standard.
- Separate source-backed requirements from heuristics and editorial preferences.
