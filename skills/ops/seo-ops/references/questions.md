# SEO operations questions and answers

Use these as decision aids, not canned client copy. Every answer states an operational default; the audit must still record site-specific evidence and exceptions.

## Canonicals and redirects

**Do we need a canonical tag if redirects are correct?**
Yes for indexable pages. Redirects choose the origin/URL form; self-referencing canonicals reinforce the selected URL and help consolidate accidental variants.

**Can canonical tags replace redirects between apex and `www`?**
No. A canonical is a hint; both hosts remain crawlable and users still receive duplicate content. Permanently redirect the alternate host.

**Should canonical URLs include query strings?**
Only when the parameter creates a genuinely distinct indexable page. Tracking/session parameters normally canonicalize to the clean URL; filters/search pages require an explicit policy.

**Is 301 always better than 308?**
Both are permanent redirects for search purposes. Use the status supported consistently by the platform and verify clients preserve the intended method semantics.

**Should a redirect preserve path and query?**
Yes for a canonical-host change unless the migration intentionally maps URLs differently. Test nested paths and encoded/multiple query parameters.

**Is a two-hop redirect harmless?**
It may work, but it adds latency, failure surface, and crawl waste. Collapse stable policies to one hop where possible; document unavoidable application-level locale redirects separately.

**Can Cloudflare Redirect Rules run on DNS-only records?**
No. The source hostname must be proxied so HTTP traffic reaches Cloudflare. Proxying changes the serving boundary, so verify TLS, APIs, caching, and security rules afterward.

## Multilingual sites

**Can every language canonicalize to English?**
Not when each translation is intended to rank. Genuine locale pages normally self-canonicalize and connect through hreflang.

**Do URL and `<html lang>` prove translation?**
No. Assert representative visible header, main content, form/error, and footer copy.

**Is `x-default` mandatory?**
Google supports it as the fallback for unmatched users. Use it when a clear default/selector exists; point it deliberately and include it consistently.

**Must hreflang links be reciprocal?**
Yes. Every declared alternate should return the relationship, including self-reference, or the annotation can be ignored.

**Can hreflang point at redirected URLs?**
Avoid it. Point directly at 200, indexable, canonical URLs.

**Should region codes use `en-UK`?**
No. Use ISO 3166-1 Alpha 2 regions, such as `en-GB`.

**Should the default language omit its locale prefix?**
Either prefixed or unprefixed can work. Choose one stable policy and make URL generation, canonicals, hreflang, sitemap, and internal links agree.

## Robots, sitemaps, and indexability

**Does `robots.txt` remove a page from Google?**
Not reliably. Robots controls crawling, not guaranteed de-indexing. Use authentication for private content or an indexable response with `noindex` when removal is intended.

**Should staging use `Disallow: /`?**
Prefer authentication and noindex as defense in depth. A public staging site blocked only by robots can still leak URLs and content.

**Should production ever ship `Disallow: /`?**
Only when the entire public site is intentionally excluded. Treat an accidental production block as Critical.

**Does a sitemap make pages indexable?**
No. It is a discovery/canonical signal. Entries still need successful, indexable, useful pages and consistent canonical signals.

**Should sitemap entries include redirected or noindexed URLs?**
No. Include canonical URLs intended for indexing.

**Do `priority` and `changefreq` improve rankings?**
Do not rely on them. Focus on accurate URLs and meaningful `lastmod` values.

**Is a fake fresh `lastmod` useful?**
No. Use actual significant modification dates; untrustworthy timestamps reduce the signal's usefulness.

## Metadata and content

**Is a 60-character title a hard requirement?**
No. Pixel width, query, device, and Google's rewriting vary. Optimize clarity and uniqueness; treat truncation as an editorial risk.

**Does every page need a meta description?**
Prioritize pages where a useful custom snippet matters. Missing descriptions are not automatically an indexing failure.

**Must every page have exactly one H1?**
One clear primary H1 is a reliable operational default. Multiple H1s are valid HTML but often reveal weak hierarchy; inspect context before escalating.

**Does missing image alt text hurt rankings?**
It primarily harms accessibility and image understanding. Distinguish informative images from decorative images, which should use `alt=""`.

**Is duplicate content a penalty?**
Usually it is a consolidation/selection problem, not a punishment. Investigate wasted crawl, wrong selected canonical, split signals, and poor user routing.

**Should thin pages be noindexed automatically?**
No. First decide whether to improve, consolidate, remove, or intentionally exclude them based on user value and site architecture.

## Structured data and JavaScript

**Can `curl` prove schema is missing?**
Only for response HTML. Rendered JSON-LD requires browser evidence.

**Should we add every plausible schema type?**
No. Add truthful markup that matches visible content and an actual consumer/use case.

**Does valid Schema.org markup guarantee a Google rich result?**
No. Google supports a subset of types/features and never guarantees display.

**Can metadata be injected only after hydration?**
Search engines may render JavaScript, but critical SEO signals are safer and easier to verify in the initial response. Compare raw and rendered DOM.

**What if raw and rendered canonicals differ?**
Treat it as High risk. Remove the conflict at the generating source; do not assume the later value wins.

## Measurement and tools

**Does `site:example.com` show the indexed-page count?**
No. It is a rough search operator, not an index-coverage report. Use Search Console.

**Does Lighthouse SEO 100 mean the audit passes?**
No. Lighthouse samples a limited control set and does not certify canonical topology, full hreflang clusters, Search Console state, content quality, or production regressions.

**Are lab Core Web Vitals enough?**
No. Use CrUX/Search Console field data when available; label Lighthouse as lab evidence.

**Can an agent claim a pass when Search Console access is missing?**
Only for observable checks. Mark selected canonical, index coverage, sitemap processing, query performance, manual actions, and security issues as blocked.

**Should an audit produce one SEO score?**
Not as the primary outcome. A score can hide a catastrophic blocker. Lead with severities, evidence, and decisions.

## Learning loop

**Can we make the skill learn from every investigation?**
Yes, through reviewed files rather than implicit memory. Add verified reusable cases here or in the casebook; put client state in playbooks and executable invariants in tests/Flowchad.

**What belongs in a new case?**
The initiating question/suggestion, observed evidence, proved conclusion, reusable rule, regression check, false-positive boundary, and primary sources.

**What should not enter the casebook?**
Unverified chat claims, client credentials/IDs, one-off preferences presented as universal rules, or volatile provider behavior without a dated source.
