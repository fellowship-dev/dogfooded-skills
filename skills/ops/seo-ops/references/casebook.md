# SEO operations casebook

This is reusable diagnostic memory for agents. It is not a client inventory. Add a case only after reproduction and verification.

## Case format

```markdown
## Short pattern name

**Question or suggestion:** What prompted the investigation?
**Observed evidence:** Exact statuses, headers, DOM facts, or Search Console evidence.
**Conclusion:** What was proved, and what remained unknown?
**Reusable rule:** The cross-site lesson.
**Regression check:** The smallest deterministic assertion.
**False-positive boundary:** When this pattern should not be reported as a defect.
**Sources:** Primary documentation and incident/PR links.
```

## Duplicate apex and `www` content

**Question or suggestion:** Should both apex and `www` serve the same site successfully?

**Observed evidence:** Both hosts returned final HTTP 200 for equivalent paths. No explicit canonical existed. HTTP `Link` hreflang values used the requested host, so the same locale cluster changed identity by hostname.

**Conclusion:** Multiple independent canonical signals disagreed; this was not merely a missing tag.

**Reusable rule:** Select one canonical origin. Permanently redirect every alternate host to the equivalent canonical path/query in one hop. Generate canonicals, hreflang, sitemaps, structured-data URLs, social URLs, and internal links from the same origin decision.

**Regression check:** Request a nested path with a query on every alternate origin; assert one 301/308 hop to the identical canonical path/query, then assert 200.

**False-positive boundary:** A host that exists only to redirect and never serves content is not duplicate content.

**Sources:** Google Search Central canonicalization guidance; fellowship-dev/quantic-v2#46.

## Correct locale URL but untranslated visible copy

**Question or suggestion:** Is a locale switch correct when the URL and `<html lang>` change?

**Observed evidence:** `/en` and `lang="en"` were correct while navigation, project fixtures, form validation, and footer copy remained Spanish.

**Conclusion:** Routing and language metadata passed, but the user-visible localization boundary failed.

**Reusable rule:** Multilingual audits must assert representative visible copy in header, primary content, forms/errors, and footer. Metadata-only assertions are insufficient.

**Regression check:** In each direction, assert the destination URL, `<html lang>`, expected translated strings, and absence of representative source-language strings.

**False-positive boundary:** Brand names, legal entity names, and intentionally untranslated product terms require documented exceptions.

**Sources:** Google Search Central localized-version guidance; fellowship-dev/quantic-v2#45.

## Static HTML says “no schema”

**Question or suggestion:** Can `curl` prove that structured data is missing?

**Observed evidence:** Some frameworks/plugins inject JSON-LD after hydration; static fetches see no script while the rendered DOM does.

**Conclusion:** Static absence is a diagnostic clue, not certification.

**Reusable rule:** Label schema evidence as raw HTML or rendered DOM. Use a real browser and an appropriate validator before reporting missing or invalid rendered schema.

**Regression check:** Parse both response HTML and `document.querySelectorAll('script[type="application/ld+json"]')`; report disagreement explicitly.

**False-positive boundary:** Server-rendered sites with no client mutation can be certified from raw HTML when that rendering model is verified.

**Sources:** Google Search Central JavaScript structured-data guidance; coreyhaines31/marketingskills `seo-audit`.

## Canonical and hreflang conflict

**Question or suggestion:** Can locale A canonicalize to locale B while hreflang connects both?

**Observed evidence:** Canonical consolidation and alternate-language annotations expressed opposite decisions.

**Conclusion:** Hreflang does not override canonicalization; a cluster can be ignored or consolidated unexpectedly.

**Reusable rule:** Genuine translated locale pages normally self-canonicalize. The canonical URL must participate in the hreflang cluster, and every alternate must be reciprocal and indexable.

**Regression check:** For every sampled locale URL, assert self-canonical, self hreflang, reciprocal alternates, valid codes, and 200/indexable targets.

**False-positive boundary:** Near-duplicate regional pages may need a deliberate consolidation strategy; document it and do not apply a blanket rule without content evidence.

**Sources:** Google Search Central localized-version and canonicalization guidance.

## How to add expertise from a conversation

**Question or suggestion:** Can a future agent simply reference an old SEO conversation?

**Conclusion:** Conversation context is transient and may contain unverified claims. Durable expertise must be distilled into a reviewed artifact.

**Reusable rule:** Convert useful conversation material into the case format above. Reproduce the claim, attach primary sources, separate site facts into the repo playbook, add an executable regression when possible, and submit the public change through review.

**Regression check:** A fresh agent reading only this skill can explain the rule, reproduce the check, and identify its false-positive boundary.

**False-positive boundary:** Opinions and unresolved suggestions belong in an issue or investigation note, not the authoritative casebook.
