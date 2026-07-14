# SEO audit checklist

Use this control catalog after the deterministic audit. For each applicable row record `pass`, `fail`, `blocked`, `not-applicable`, or `needs-judgment`, plus evidence.

## 1. Host, protocol, and redirects

- [ ] One canonical HTTPS origin is named in the repo playbook.
- [ ] HTTP permanently redirects to HTTPS in one hop.
- [ ] Alternate hosts permanently redirect to the equivalent canonical path and query in one hop.
- [ ] Redirects preserve intended locale paths and do not loop.
- [ ] Redirect destinations are not blocked by authentication or deployment protection.
- [ ] Trailing slash, casing, and default-document policies are consistent.
- [ ] CDN/proxy configuration does not create host-dependent content or headers.

## 2. Canonical signals

- [ ] Every indexable unique page emits one absolute self-referencing canonical.
- [ ] Canonical URLs return 200 and are indexable.
- [ ] Canonical origin/path agree across raw HTML and rendered DOM.
- [ ] Canonical, redirects, sitemap, hreflang, `og:url`, structured data, and internal links agree.
- [ ] Query/filter pages have an explicit consolidation or indexation policy.
- [ ] Paginated pages do not incorrectly canonicalize all pages to page 1.

## 3. Crawlability and indexability

- [ ] `robots.txt` returns 200 text, does not block required assets/pages, and references the sitemap.
- [ ] Important pages do not emit `noindex` or conflicting `X-Robots-Tag` headers.
- [ ] Error pages return appropriate non-200 status codes and useful content.
- [ ] Soft 404s, redirect chains, redirect loops, and orphan pages are absent from the sampled crawl.
- [ ] Important pages are reachable through crawlable `<a href>` links.
- [ ] Authentication, consent, or bot protection does not hide indexable content from supported crawlers.

## 4. Sitemaps

- [ ] Sitemap or sitemap index returns valid XML.
- [ ] Sitemap contains only canonical HTTPS URLs intended for indexing.
- [ ] Entries do not redirect, 404, or emit `noindex`.
- [ ] `lastmod` is present only when accurate and changes meaningfully.
- [ ] Sitemap stays within 50,000 URLs and 50 MB uncompressed per file.
- [ ] Multilingual alternates, if represented in XML, are complete and consistent with HTML/headers.
- [ ] Search Console submission state and last read date are recorded in the repo playbook.

## 5. Multilingual and regional pages

- [ ] Locale URLs are stable and crawlable without cookies, IP detection, or `Accept-Language` dependence.
- [ ] `<html lang>` uses a valid language tag.
- [ ] Every locale self-canonicalizes unless a documented exception applies.
- [ ] Every hreflang cluster self-references and is reciprocal.
- [ ] Language codes use ISO 639-1; optional regions use ISO 3166-1 Alpha 2.
- [ ] `x-default` points to the intended fallback.
- [ ] Hreflang targets return 200, are indexable, and match their canonical URLs.
- [ ] HTML, HTTP-header, and sitemap hreflang methods do not conflict.
- [ ] Representative header, main content, form, validation, and footer copy is visibly translated.
- [ ] Internal links remain in the intended locale and canonical origin.

## 6. Page metadata

- [ ] Each representative page has a descriptive, page-specific title.
- [ ] Meta descriptions are useful and distinct where snippets matter.
- [ ] One clear primary H1 exists; heading hierarchy describes the content.
- [ ] Viewport and charset are present.
- [ ] `og:title`, `og:description`, `og:url`, and a fetchable `og:image` match the canonical page.
- [ ] Twitter card metadata is intentional rather than stale template content.
- [ ] Favicons, manifest, and social images return successful responses.
- [ ] Metadata is accurate in both raw HTML and rendered DOM.

Do not enforce title or description character counts as ranking requirements. Treat truncation risk and snippet quality as editorial judgment.

## 7. Structured data

- [ ] Inspect raw and rendered JSON-LD; label the evidence source.
- [ ] JSON parses successfully and uses `https://schema.org` context.
- [ ] Types match visible, truthful page content.
- [ ] Required/recommended properties for targeted Google features are present.
- [ ] URLs and entity identifiers use the canonical origin.
- [ ] Organization/person/product/review claims are not invented or stale.
- [ ] Google Rich Results Test or Schema Markup Validator evidence is attached when eligibility matters.
- [ ] Absence of rich-result eligibility is not mislabeled as an indexing failure.

## 8. Content and internal links

- [ ] Primary content is present in initial or reliably rendered HTML.
- [ ] Sampled pages satisfy the apparent search/user intent and are not near-empty templates.
- [ ] Internal links use canonical URLs and descriptive anchors.
- [ ] No important page is orphaned in the sampled graph.
- [ ] Images have purposeful alt text; decorative images use empty alt attributes.
- [ ] Large-scale generated pages contain substantive unique value.
- [ ] Duplicate or near-duplicate templates have a documented consolidation policy.

## 9. Performance and mobile

- [ ] Mobile viewport, navigation, text, and interactive controls work in a real browser.
- [ ] Real-user Core Web Vitals are read from Search Console/CrUX when available.
- [ ] Lab Lighthouse results are labeled as lab evidence, not field performance.
- [ ] LCP, INP, and CLS regressions are associated with concrete templates/assets.
- [ ] Critical content and metadata are not delayed behind brittle client rendering.

## 10. Search Console and monitoring

- [ ] Correct Domain or URL-prefix property ownership is documented without credentials.
- [ ] Index coverage, submitted sitemap status, and selected canonical are sampled.
- [ ] Manual actions and security issues are checked by an authorized operator.
- [ ] Query/page/device/country changes are compared against deploys and migrations.
- [ ] Critical production assertions are automated in Flowchad/e2e.
- [ ] Recurring audits dedupe existing issues and attach fresh evidence.
- [ ] Last verification date and known exceptions are updated in the repo playbook.
